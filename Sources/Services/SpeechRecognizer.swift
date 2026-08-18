import Foundation
import Speech
import AVFoundation

/// 端侧语音识别（Apple Speech 公开框架，无需任何密钥/后端）。
/// 长按录音，松开后返回识别文本。
@MainActor
final class SpeechRecognizer: ObservableObject {
    static let shared = SpeechRecognizer()

    private let audioEngine = AVAudioEngine()
    private var request: SFSpeechAudioBufferRecognitionRequest?
    private var task: SFSpeechRecognitionTask?
    private let recognizer: SFSpeechRecognizer?
    private var tapInstalled = false

    @Published var isAuthorized = false
    @Published var isRecording = false
    @Published var transcript: String = ""

    override init() {
        recognizer = SFSpeechRecognizer(locale: Locale(identifier: "zh-CN"))
                   ?? SFSpeechRecognizer()
        Task { await requestAuth() }
    }

    func requestAuth() async {
        let status = await withCheckedContinuation { (cont: CheckedContinuation<SFSpeechRecognizerAuthorizationStatus, Never>) in
            SFSpeechRecognizer.requestAuthorization { st in cont.resume(returning: st) }
        }
        await MainActor.run { self.isAuthorized = (status == .authorized) }
    }

    func start() {
        guard let recognizer, recognizer.isAvailable, !isRecording else { return }
        stopInternal()

        let session = AVAudioSession.sharedInstance()
        try? session.setCategory(.record, mode: .measurement, options: .duckOthers)
        try? session.setActive(true, options: .notifyOthersOnDeactivation)

        let request = SFSpeechAudioBufferRecognitionRequest()
        request.shouldReportPartialResults = true
        self.request = request

        let node = audioEngine.inputNode
        let fmt = node.outputFormat(forBus: 0)
        node.installTap(onBus: 0, bufferSize: 1024, format: fmt) { [weak self] buffer, _ in
            self?.request?.append(buffer)
        }
        tapInstalled = true

        audioEngine.prepare()
        do { try audioEngine.start() } catch { return }

        isRecording = true
        transcript = ""

        task = recognizer.recognitionTask(with: request) { [weak self] result, error in
            guard let self else { return }
            if let result {
                let text = result.bestTranscription.formattedString
                DispatchQueue.main.async { self.transcript = text }
            }
            if error != nil || (result?.isFinal ?? false) {
                self.stopInternal()
            }
        }
    }

    /// 停止录音并返回当前识别文本
    @discardableResult
    func stop() -> String {
        stopInternal()
        return transcript
    }

    private func stopInternal() {
        if tapInstalled {
            audioEngine.inputNode.removeTap(onBus: 0)
            tapInstalled = false
        }
        if audioEngine.isRunning { audioEngine.stop() }
        request?.endAudio()
        task?.cancel()
        task = nil
        request = nil
        isRecording = false
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
    }
}
