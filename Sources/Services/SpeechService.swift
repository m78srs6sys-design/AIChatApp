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
        synthesizer.stopSpeaking(at: .immediate)
        let utterance = AVSpeechUtterance(string: trimmed)
        utterance.voice = AVSpeechSynthesisVoice(language: "zh-CN") // 中文普通话
        utterance.rate = 0.48       // 语速（0~1，0.5 左右为正常）
        utterance.pitchMultiplier = 1.0
        utterance.preUtteranceDelay = 0.05
        speakingText = trimmed
        isSpeaking = true
        synthesizer.speak(utterance)
    }

    /// 停止朗读
    func stop() {
        synthesizer.stopSpeaking(at: .immediate)
        isSpeaking = false
        speakingText = nil
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
