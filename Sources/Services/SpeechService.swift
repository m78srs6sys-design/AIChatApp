import Foundation
import AVFoundation
import CryptoKit

/// 语音朗读服务：
/// - 联网模式（preferOnline = true）：优先使用微软 Edge 在线合成（公开免密钥、中文音色自然），失败自动回退本地；
/// - 离线模式：使用系统 AVSpeechSynthesizer 本地合成（无需网络、无需密钥）。
final class SpeechService: NSObject, ObservableObject {
    static let shared = SpeechService()

    @Published var isSpeaking = false
    /// 当前正在朗读的文本（用于界面高亮）
    @Published var speakingText: String?

    private let synthesizer = AVSpeechSynthesizer()
    /// 在线合成音频播放器（mp3）
    private var onlinePlayer: AVAudioPlayer?

    private override init() {
        super.init()
        synthesizer.delegate = self
    }

    // MARK: - Public

    /// 朗读一段文本（会打断当前朗读）
    /// - Parameter preferOnline: 联网模式下为 true，优先走微软在线合成；false 走本地合成
    func speak(_ text: String, preferOnline: Bool = false) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        // 音频相关必须在主线程操作
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.configureAudioSession()
            if preferOnline {
                self.speakOnline(trimmed)
            } else {
                self.speakLocal(trimmed)
            }
        }
    }

    /// 停止朗读
    func stop() {
        synthesizer.stopSpeaking(at: .immediate)
        onlinePlayer?.stop()
        onlinePlayer = nil
        isSpeaking = false
        speakingText = nil
        // 朗读结束后让出音频会话，避免长期占用
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
    }

    /// 是否正在朗读
    var isSpeakingNow: Bool {
        synthesizer.isSpeaking || (onlinePlayer?.isPlaying ?? false)
    }

    // MARK: - 本地合成（系统 AVSpeechSynthesizer）

    private func speakLocal(_ trimmed: String) {
        // 关键修复：确保音频会话处于「播放」类别，否则在静音键开启、
        // 或刚用过语音输入（录音会话）后，朗读会完全没声音。
        self.synthesizer.stopSpeaking(at: .immediate)
        let utterance = AVSpeechUtterance(string: trimmed)
        // 中文普通话；若设备未下载对应语音则回退系统默认嗓音，避免静默失败
        if let voice = AVSpeechSynthesisVoice(language: "zh-CN") {
            utterance.voice = voice
        }
        utterance.rate = 0.48       // 语速（0~1，0.5 左右为正常）
        utterance.pitchMultiplier = 1.0
        utterance.preUtteranceDelay = 0.05
        self.speakingText = trimmed
        self.isSpeaking = true
        self.synthesizer.speak(utterance)
    }

    // MARK: - 在线合成（微软 Edge TTS，公开免密钥）

    private func speakOnline(_ trimmed: String) {
        // 长度保护：Edge TTS 单次合成上限约 1000 字符，超长截断（本地合成无此限制）
        let text = trimmed.count > 900 ? String(trimmed.prefix(900)) : trimmed
        self.speakingText = text
        self.isSpeaking = true
        Task {
            do {
                let audio = try await EdgeTTSSynthesizer.synthesize(text)
                guard !Task.isCancelled else { return }
                try await MainActor.run {
                    if self.synthesizer.isSpeaking { self.synthesizer.stopSpeaking(at: .immediate) }
                    let url = FileManager.default.temporaryDirectory
                        .appendingPathComponent("edge_tts_\(UUID().uuidString).mp3")
                    try audio.write(to: url)
                    let player = try AVAudioPlayer(contentsOf: url)
                    player.prepareToPlay()
                    player.delegate = self
                    self.onlinePlayer?.stop()
                    self.onlinePlayer = player
                    if player.play() {
                        // 播放成功：状态已在上面置为 true
                    }
                }
            } catch {
                // 在线失败 → 自动回退本地合成，保证朗读不中断
                await MainActor.run {
                    self.speakLocal(text)
                }
            }
        }
    }

    private func configureAudioSession() {
        do {
            let session = AVAudioSession.sharedInstance()
            if session.category != .playback && session.category != .playAndRecord {
                try session.setCategory(.playback, mode: .spokenAudio,
                                        options: [.duckOthers, .allowBluetooth])
            }
            try session.setActive(true, options: .notifyOthersOnDeactivation)
        } catch {
            // 音频会话配置失败不阻断朗读，仅记录
        }
    }
}

// MARK: - AVSpeechSynthesizerDelegate
extension SpeechService: AVSpeechSynthesizerDelegate {
    func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didFinish utterance: AVSpeechUtterance) {
        DispatchQueue.main.async {
            self.isSpeaking = false
            self.speakingText = nil
        }
    }

    func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didCancel utterance: AVSpeechUtterance) {
        DispatchQueue.main.async {
            self.isSpeaking = false
            self.speakingText = nil
        }
    }
}

// MARK: - AVAudioPlayerDelegate（在线合成音频播放结束）
extension SpeechService: AVAudioPlayerDelegate {
    func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        DispatchQueue.main.async {
            if self.onlinePlayer === player {
                self.onlinePlayer = nil
            }
            self.isSpeaking = false
            self.speakingText = nil
        }
    }

    func audioPlayerDecodeErrorDidOccur(_ player: AVAudioPlayer, error: Error?) {
        DispatchQueue.main.async {
            if self.onlinePlayer === player {
                self.onlinePlayer = nil
            }
            self.isSpeaking = false
            self.speakingText = nil
        }
    }
}

// MARK: - 微软 Edge 在线 TTS 合成（公开接口，无需任何密钥）
/// 协议参考 edge-tts（https://github.com/rany2/edge-tts）
/// 返回 mp3 音频数据；中文音色默认 XiaoxiaoNeural（晓晓，自然女声）。
enum EdgeTTSSynthesizer {
    private static let trustedClientToken = "6A5AA1D4EAFF4E9FB37E23D68491D6F4"
    private static let wssBase = "wss://speech.platform.bing.com/consumer/speech/synthesize/readaloud/edge/v1"
    private static let defaultVoice = "zh-CN-XiaoxiaoNeural"
    private static let userAgent = "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 " +
        "(KHTML, like Gecko) Chrome/130.0.0.0 Safari/537.36 Edg/130.0.0.0"

    enum TTSError: LocalizedError {
        case badURL
        case emptyAudio
        case server(String)
        var errorDescription: String? {
            switch self {
            case .badURL: return "在线语音服务地址无效"
            case .emptyAudio: return "在线语音服务未返回音频"
            case .server(let msg): return "在线语音服务错误：\(msg)"
            }
        }
    }

    /// 合成一段文本，返回 mp3 音频数据
    static func synthesize(_ text: String, voice: String = defaultVoice) async throws -> Data {
        let gec = generateSecMSGEC()
        guard var comps = URLComponents(string: wssBase) else { throw TTSError.badURL }
        comps.queryItems = [
            URLQueryItem(name: "TrustedClientToken", value: trustedClientToken),
            URLQueryItem(name: "Sec-MS-GEC", value: gec),
            URLQueryItem(name: "Sec-MS-GEC-Version", value: "1-130.0.2849.68"),
            URLQueryItem(name: "ConnectionId", value: UUID().uuidString.uppercased())
        ]
        guard let url = comps.url else { throw TTSError.badURL }

        var request = URLRequest(url: url)
        request.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        request.setValue("no-cache", forHTTPHeaderField: "Cache-Control")
        request.setValue("12", forHTTPHeaderField: "Pragma")
        request.timeoutInterval = 25

        let session = URLSession(configuration: .default)
        let ws = session.webSocketTask(with: request)
        ws.resume()

        defer { ws.cancel(with: .goingAway, reason: nil) }

        // 1) 发送「语音配置」消息（选择 mp3 输出格式）
        let ts = rfc1123Timestamp()
        let configBody = """
        {"context":{"synthesis":{"audio":{"metadataoptions":{"sentenceBoundaryEnabled":"false",\
        "wordBoundaryEnabled":"false"},"outputFormat":"audio-24khz-48kbitrate-mono-mp3"}}}}
        """
        let configMessage = "X-Timestamp:\(ts)\r\nContent-Type:application/json; charset=utf-8\r\nPath:speech.config\r\n\r\n" + configBody
        try await ws.send(.string(configMessage))

        // 2) 发送 SSML 合成请求
        let escaped = escapeXML(text)
        let ssml = """
        <speak version='1.0' xmlns='http://www.w3.org/2001/10/synthesis' xml:lang='zh-CN'>\
        <voice name='\(voice)'><prosody pitch='+0Hz' rate='+10%' volume='+0%'>\(escaped)</prosody></voice></speak>
        """
        let ssmlMessage = "X-Timestamp:\(rfc1123Timestamp())\r\nContent-Type:application/ssml+xml\r\nPath:ssml\r\n\r\n" + ssml
        try await ws.send(.string(ssmlMessage))

        // 3) 循环接收，拼接音频，直到 turn.end
        var audio = Data()
        while true {
            let message: URLSessionWebSocketTask.Message
            do {
                message = try await ws.receive()
            } catch {
                throw TTSError.server("连接中断")
            }
            switch message {
            case .data(let d):
                audio.append(d)
            case .string(let s):
                if s.contains("Path:turn.end") {
                    if audio.isEmpty { throw TTSError.emptyAudio }
                    return audio
                }
                if s.contains("\"error\"") || s.contains("Path:response") && s.contains("error") {
                    throw TTSError.server(s)
                }
            @unknown default:
                break
            }
        }
    }

    /// 生成 Sec-MS-GEC 防盗链哈希（5 分钟窗口的 Windows FileTime + SHA256）
    private static func generateSecMSGEC() -> String {
        let unix = Date().timeIntervalSince1970
        var ticks = unix + 11644473600.0      // Unix → Windows FileTime 纪元偏移（1601-01-01）
        ticks -= ticks.truncatingRemainder(dividingBy: 300) // 5 分钟窗口
        ticks *= 1e7                           // 秒 → 100ns 间隔
        let strToHash = String(format: "%.0f", ticks) + trustedClientToken
        let digest = SHA256.hash(data: Data(strToHash.utf8))
        return digest.map { String(format: "%02X", $0) }.joined()
    }

    private static func rfc1123Timestamp() -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "EEE, dd MMM yyyy HH:mm:ss 'GMT'"
        f.timeZone = TimeZone(identifier: "UTC")
        return f.string(from: Date())
    }

    private static func escapeXML(_ s: String) -> String {
        s.replacingOccurrences(of: "&", with: "&amp;")
         .replacingOccurrences(of: "<", with: "&lt;")
         .replacingOccurrences(of: ">", with: "&gt;")
         .replacingOccurrences(of: "\"", with: "&quot;")
         .replacingOccurrences(of: "'", with: "&apos;")
    }
}