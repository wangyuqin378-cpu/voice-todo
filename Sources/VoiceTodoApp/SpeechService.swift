import AppKit
import AVFoundation
import Speech
import VoiceTodoCore

// Conversion consumes the ordered input stream. No recording is written to disk.
private final class AudioBridge: @unchecked Sendable {
    let converter: AVAudioConverter
    let format: AVAudioFormat
    init?(source: AVAudioFormat, target: AVAudioFormat) {
        guard let converter = AVAudioConverter(from: source, to: target) else { return nil }
        self.converter = converter; format = target
    }
    func convert(_ input: AVAudioPCMBuffer) throws -> AnalyzerInput? {
        let frames = AVAudioFrameCount(ceil(Double(input.frameLength) * format.sampleRate / input.format.sampleRate)) + 32
        guard let output = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames) else { throw UserFacingError("语音转换缓冲不可用。") }
        var supplied = false
        var error: NSError?
        converter.convert(to: output, error: &error) { _, status in
            if supplied { status.pointee = .noDataNow; return nil }
            supplied = true; status.pointee = .haveData; return input
        }
        if let error { throw error }
        return output.frameLength > 0 ? AnalyzerInput(buffer: output) : nil
    }
}

@MainActor final class SpeechService: SpeechRecognizing {
    private var engine: AVAudioEngine?
    private var analyzer: SpeechAnalyzer?
    private var input: SpeechAudioInput?
    private var resultTask: Task<Void, Never>?
    private var watchdog: Task<Void, Never>?
    private var generation = UUID()
    private var finalText = ""
    private var partialText = ""
    private var recognitionError: Error?
    var onText: ((String) -> Void)?
    var onFailure: ((String) -> Void)?
    var text: String { (finalText + partialText).trimmingCharacters(in: .whitespacesAndNewlines) }

    static var microphoneAllowed: Bool { AVCaptureDevice.authorizationStatus(for: .audio) == .authorized }
    static func requestMicrophone() async -> Bool { await AVCaptureDevice.requestAccess(for: .audio) }
    static func installModel() async throws {
        guard SpeechTranscriber.isAvailable else { throw UserFacingError("这台 Mac 暂不支持本机语音识别。") }
        let module = SpeechTranscriber(locale: Locale(identifier: "zh_CN"), preset: .progressiveTranscription)
        if let request = try await AssetInventory.assetInstallationRequest(supporting: [module]) {
            try await request.downloadAndInstall()
        }
    }

    func start() async throws {
        guard Self.microphoneAllowed else { throw UserFacingError("请先在设置中允许麦克风访问。") }
        let token = UUID(); generation = token
        finalText = ""; partialText = ""; recognitionError = nil
        let engine = AVAudioEngine()
        let source = engine.inputNode.outputFormat(forBus: 0)
        guard source.sampleRate > 0, source.channelCount > 0 else {
            throw UserFacingError("麦克风当前不可用，请检查输入设备。")
        }
        // Start capture before the first suspension. Buffer the opening words
        // while the on-device model prepares; stopping Fn closes this input now.
        let input = SpeechAudioInput()
        self.input = input; self.engine = engine
        engine.inputNode.installTap(onBus: 0, bufferSize: 2048, format: source) { buffer, _ in input.append(buffer) }
        engine.prepare()
        do { try engine.start() } catch { cancel(); throw error }
        do { try await prepare(source: source, input: input, token: token) }
        catch {
            if token == generation { cancel() }
            throw error
        }
    }

    private func prepare(source: AVAudioFormat, input: SpeechAudioInput, token: UUID) async throws {
        let module = SpeechTranscriber(locale: Locale(identifier: "zh_CN"), preset: .progressiveTranscription)
        let installed = await SpeechTranscriber.installedLocales
        guard token == generation, !Task.isCancelled else { throw CancellationError() }
        guard installed.contains(where: { $0.identifier.replacingOccurrences(of: "-", with: "_") == "zh_CN" }) else {
            throw UserFacingError("请在设置中下载简体中文语音模型。")
        }
        guard let target = await SpeechAnalyzer.bestAvailableAudioFormat(compatibleWith: [module], considering: source) else {
            throw UserFacingError("麦克风音频格式不可用。")
        }
        guard token == generation, !Task.isCancelled else { throw CancellationError() }
        let analyzer = SpeechAnalyzer(modules: [module])
        self.analyzer = analyzer
        try await analyzer.prepareToAnalyze(in: target)
        guard token == generation, !Task.isCancelled else { await analyzer.cancelAndFinishNow(); throw CancellationError() }
        guard let bridge = AudioBridge(source: source, target: target) else {
            await analyzer.cancelAndFinishNow(); throw UserFacingError("无法转换麦克风音频格式。")
        }
        let stream = input.stream.compactMap { try bridge.convert($0.pcm) }
        resultTask = Task { [weak self] in
            do {
                for try await result in module.results {
                    guard let self, token == self.generation else { return }
                    let words = String(result.text.characters)
                    if result.isFinal { self.finalText += words; self.partialText = "" }
                    else { self.partialText = words }
                    self.onText?(self.text)
                }
            } catch {
                guard let self, token == self.generation, !Task.isCancelled else { return }
                self.recognitionError = error
                self.onFailure?("语音识别中断，已识别文字会保留。")
            }
        }
        do {
            try await analyzer.start(inputSequence: stream)
            guard token == generation, !Task.isCancelled else { throw CancellationError() }
        } catch {
            if token == generation { cancel() }
            else { await analyzer.cancelAndFinishNow() }
            throw error
        }
    }

    func finish() async throws -> String {
        guard let analyzer else { let words = text; cancel(); return words }
        let token = generation
        let ownResults = resultTask
        stopInput()
        let ownWatchdog = Task {
            try? await Task.sleep(for: .seconds(8))
            guard !Task.isCancelled, token == generation else { return }
            recognitionError = UserFacingError("语音收尾超时，已识别文字已保留，请检查后重试。")
            await analyzer.cancelAndFinishNow()
        }
        watchdog = ownWatchdog
        do { try await analyzer.finalizeAndFinishThroughEndOfInput() }
        catch { if token == generation { recognitionError = error } }
        await ownResults?.value
        ownWatchdog.cancel()
        guard token == generation else { throw CancellationError() }
        watchdog = nil
        self.analyzer = nil; resultTask = nil
        if let recognitionError { throw recognitionError }
        return text
    }

    func cancel() {
        generation = UUID(); stopInput()
        watchdog?.cancel(); watchdog = nil; resultTask?.cancel(); resultTask = nil
        let old = analyzer; analyzer = nil
        if let old { Task { await old.cancelAndFinishNow() } }
        finalText = ""; partialText = ""; recognitionError = nil
    }
    func stopInput() { stopEngine(); input?.finish(); input = nil }
    private func stopEngine() {
        if let engine { engine.stop(); engine.inputNode.removeTap(onBus: 0) }
        engine = nil
    }
}

@MainActor final class QuestionSpeaker {
    private let synthesizer = AVSpeechSynthesizer()
    func stop() { synthesizer.stopSpeaking(at: .immediate) }
    func speak(_ text: String) {
        stop()
        let utterance = AVSpeechUtterance(string: text)
        utterance.voice = AVSpeechSynthesisVoice(language: "zh-CN")
        utterance.rate = 0.52
        synthesizer.speak(utterance)
    }
}
