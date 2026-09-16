import Foundation
import VoiceTodoCore

@MainActor protocol SpeechRecognizing: AnyObject {
    var text: String { get }
    var onFailure: ((String) -> Void)? { get set }
    func start() async throws
    func stopInput()
    func finish() async throws -> String
    func cancel()
}

/// Shares the existing Fn gesture, never consumes keys or reads another app's text.
/// Only a finalized utterance can become an action. Ordinary speech is discarded.
@MainActor final class FnSpeechCapture {
    enum Phase { case idle, starting, listening, finishing }
    private(set) var phase: Phase = .idle
    var active: Bool { phase != .idle }
    var onBegin: (() -> Void)?
    var onState: ((Phase) -> Void)?
    var onStatus: ((String) -> Void)?
    var onCommand: ((String, String, String?) -> Void)?
    var onFailure: ((String, String, String, String?) -> Void)?
    var currentQuestionID: (() -> String?)?
    var diagnostics: CaptureDiagnostics?
    private let speech: any SpeechRecognizing
    private let now: () -> TimeInterval
    private var operation: Task<Void, Never>?
    private var limit: Task<Void, Never>?
    private var id: String?
    private var answerID: String?
    private var pressedAt: TimeInterval?
    private var secondPress = false
    private var ready = false
    private var reply: DictationReplyWindow?
    private var lastDeliveredID: String?
    private let conversationSource = "fn-local-speech"

    init(speech: (any SpeechRecognizing)? = nil, now: @escaping () -> TimeInterval = { ProcessInfo.processInfo.systemUptime }) {
        self.speech = speech ?? SpeechService(); self.now = now
        self.speech.onFailure = { [weak self] message in self?.fail(message) }
    }

    var awaitingReply: Bool {
        reply?.answerID(sourceID: conversationSource, pendingQuestionID: currentQuestionID?(), now: now()) != nil
    }
    func awaitReply(to questionID: String?, after inputID: String) {
        guard inputID == lastDeliveredID.map({ "external-" + $0 }) else { return }
        reply = questionID.map { DictationReplyWindow(questionID: $0, sourceID: conversationSource, now: now()) }
    }

    func press() {
        if phase == .starting || phase == .listening {
            guard pressedAt == nil else { return }
            pressedAt = now(); secondPress = true
            if let id { diagnostics?.record(.pressed, id: id) }
            return
        }
        if active { cancel() }
        let token = UUID().uuidString
        id = token; pressedAt = now(); secondPress = false; ready = false
        answerID = reply?.answerID(sourceID: conversationSource, pendingQuestionID: currentQuestionID?(), now: now())
        reply = nil
        diagnostics?.start(id: token, source: nil, fieldReadable: false)
        diagnostics?.record(.localSpeechStarted, id: token)
        onBegin?(); setPhase(.starting); onStatus?("Fn 本机识别 · 正在准备")
        limit = Task { [weak self] in
            try? await Task.sleep(for: .seconds(10))
            guard !Task.isCancelled, let self, self.id == token, !self.ready else { return }
            self.fail("本机语音启动超时，请检查麦克风和中文模型。")
        }
        operation = Task { [weak self] in
            guard let self else { return }
            guard self.id == token, !Task.isCancelled else { return }
            guard self.phase != .finishing else {
                self.diagnostics?.record(.localSpeechEmpty, id: token)
                self.clear(); return
            }
            do {
                try await self.speech.start()
                guard self.id == token, !Task.isCancelled else { return }
                self.ready = true
                self.diagnostics?.record(.localSpeechReady, id: token)
                self.limit?.cancel()
                if self.phase == .finishing { self.finalize(token) }
                else {
                    self.setPhase(.listening); self.onStatus?("Fn 本机识别 · 正在听")
                    self.limit = Task { [weak self] in
                        try? await Task.sleep(for: .seconds(90))
                        guard !Task.isCancelled, let self, self.id == token else { return }
                        self.end()
                    }
                }
            } catch {
                guard self.id == token, !Task.isCancelled else { return }
                self.fail(error.localizedDescription)
            }
        }
    }

    func release() {
        guard let id, let pressedAt else { return }
        diagnostics?.record(.released, id: id)
        self.pressedAt = nil
        if secondPress || now() - pressedAt >= 0.35 { end() }
    }
    func end() {
        guard let id, phase == .starting || phase == .listening else { return }
        diagnostics?.record(.ended, id: id)
        // Stop hardware now, even if model preparation is still in flight.
        speech.stopInput(); setPhase(.finishing)
        onStatus?("Fn 本机识别 · 录音已结束")
        if ready { finalize(id) }
    }
    func cancel() {
        if let id { diagnostics?.record(.cancelled, id: id) }
        clear(); reply = nil
    }
    private func clear() {
        id = nil; answerID = nil; pressedAt = nil; ready = false
        operation?.cancel(); operation = nil; limit?.cancel(); limit = nil
        speech.cancel(); setPhase(.idle)
    }
    private func setPhase(_ value: Phase) { phase = value; onState?(value) }
    private func finalize(_ token: String) {
        limit?.cancel()
        operation = Task { [weak self] in
            guard let self else { return }
            do {
                let words = try await self.speech.finish().trimmingCharacters(in: .whitespacesAndNewlines)
                guard self.id == token, !Task.isCancelled else { return }
                let answer = self.answerID
                self.diagnostics?.record(.localSpeechFinal, id: token)
                self.clear()
                guard !words.isEmpty, CommandText.accepts(words) || answer != nil else {
                    self.diagnostics?.record(words.isEmpty ? .localSpeechEmpty : .ordinaryText, id: token)
                    self.onStatus?(words.isEmpty ? "Fn 本机识别 · 未听到文字" : "普通转写，未改变清单")
                    return
                }
                self.lastDeliveredID = token
                self.diagnostics?.record(.commandReceived, id: token)
                self.onCommand?(words, token, answer)
            } catch {
                guard self.id == token, !Task.isCancelled else { return }
                self.fail("本机识别未完整结束，待办候选文字已保留，请检查后重试。")
            }
        }
    }
    private func fail(_ message: String) {
        guard let token = id else { return }
        let words = speech.text; let answer = answerID
        diagnostics?.record(.localSpeechFailed, id: token)
        clear(); onStatus?(message)
        // An incomplete completion must never be applied. Ordinary speech stays transient.
        onFailure?(CommandText.accepts(words) || answer != nil ? words : "", token, message, answer)
    }
}
