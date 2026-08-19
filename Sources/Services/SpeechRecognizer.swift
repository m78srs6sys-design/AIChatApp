import Foundation
import Speech
import AVFoundation

/// 端侧语音识别（Apple Speech 公开框架，无需任何密钥/后端）。
/// 长按录音，松开后返回识别文本；上滑可取消。
/// 注意：不标记为 @MainActor，避免 SwiftUI 视图跨隔离域访问其 @Published 属性报错；
/// 涉及 UI 的属性更新统一通过 DispatchQueue.main 回到主线程。
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
    /// 最近一次错误（权限/麦克风等），供 UI 提示
    @Published var lastError: String?

    init() {
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

    /// 开始录音。返回是否成功启动。
    @discardableResult
    func start() -> Bool {
        lastError = nil

        // 权限检查（首次会弹系统授权框）
        let authStatus = SFSpeechRecognizer.authorizationStatus()
        switch authStatus {
        case .notDetermined:
            // 先触发系统授权弹窗，本次直接返回；用户允许后再次长按即可使用
            SFSpeechRecognizer.requestAuthorization { _ in }
            lastError = "请允许「语音识别」权限后重试"
            return false
        case .denied, .restricted:
            lastError = "语音识别未授权，请在系统设置中开启「语音识别」权限"
            return false
        case .authorized:
            break
        @unknown default:
            break
        }

        guard let recognizer, recognizer.isAvailable, !isRecording else { return false }
        stopInternal()

        let session = AVAudioSession.sharedInstance()
        do {
            try session.setCategory(.record, mode: .measurement, options: .duckOthers)
            try session.setActive(true, options: .notifyOthersOnDeactivation)
        } catch {
            lastError = "无法初始化麦克风（\(error.localizedDescription)）"
            return false
        }

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
        do { try audioEngine.start() } catch {
            tapInstalled = false
            try? session.setActive(false, options: .notifyOthersOnDeactivation)
            lastError = "麦克风启动失败（\(error.localizedDescription)）"
            return false
        }

        isRecording = true
        transcript = ""

        task = recognizer.recognitionTask(with: request) { [weak self] result, error in
            guard let self else { return }
            if let result {
                let text = result.bestTranscription.formattedString
                DispatchQueue.main.async { self.transcript = text }
            }
            if let error {
                let ns = error as NSError
                // 203/111 等为未授权 / 任务被拒
                if ns.domain == "kAFAssistantErrorDomain", [203, 111, 203].contains(ns.code) {
                    DispatchQueue.main.async { self.lastError = "语音识别未授权或被拒绝" }
                }
            }
            if error != nil || (result?.isFinal ?? false) {
                self.stopInternal()
            }
        }
        return true
    }

    /// 停止录音并返回当前识别文本（用于「松开发送」）
    @discardableResult
    func stop() -> String {
        let text = transcript
        stopInternal()
        return text
    }

    /// 取消录音并丢弃已识别文本（用于「上滑取消」）
    func cancel() {
        transcript = ""
        stopInternal()
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
        DispatchQueue.main.async { self.isRecording = false }
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
    }
}
