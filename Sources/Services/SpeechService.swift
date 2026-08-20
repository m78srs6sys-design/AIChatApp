import Foundation
import AVFoundation

/// 语音朗读服务：基于系统 AVSpeechSynthesizer 本地合成朗读。
/// 无需网络、无需密钥，中文效果好，可离线使用。
final class SpeechService: NSObject, ObservableObject {
    static let shared = SpeechService()

    @Published var isSpeaking = false
    /// 当前正在朗读的文本（用于界面高亮）
    @Published var speakingText: String?

    private let synthesizer = AVSpeechSynthesizer()

    private override init() {
        super.init()
        synthesizer.delegate = self
    }

    /// 朗读一段文本（会打断当前朗读）
    func speak(_ text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        // AVSpeechSynthesizer 必须在主线程调用
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            // 关键修复：确保音频会话处于「播放」类别，否则在静音键开启、
            // 或刚用过语音输入（录音会话）后，朗读会完全没声音。
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
    }

    /// 停止朗读
    func stop() {
        synthesizer.stopSpeaking(at: .immediate)
        isSpeaking = false
        speakingText = nil
        // 朗读结束后让出音频会话，避免长期占用
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
    }

    /// 是否正在朗读
    var isSpeakingNow: Bool { synthesizer.isSpeaking }
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
