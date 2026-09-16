import Foundation

/// One session across both delivery channels. A readable field does not imply
/// that the input method will insert there; it may still copy the final text.
public struct ExternalDictationCapture {
    public enum Source: Equatable { case field, clipboard }
    public enum Outcome: Equatable { case waiting, ignored, timedOut, command(String, Source) }
    public let id = UUID().uuidString
    public let questionID: String?
    private var field: TranscriptionCapture?
    private var clipboard: ClipboardTranscriptionCapture
    private var endedAt: TimeInterval?
    private var delivered = false
    public var fieldObservation: TranscriptionCapture.Observation? { field?.observation }
    public private(set) var ordinarySource: Source?

    public init(baseline: String?, selection: NSRange?, clipboardCount: Int, questionID: String? = nil) {
        self.questionID = questionID
        if let baseline, let selection { field = TranscriptionCapture(baseline: baseline, selection: selection, questionID: questionID) }
        clipboard = ClipboardTranscriptionCapture(changeCount: clipboardCount, questionID: questionID)
    }
    public mutating func observeField(_ text: String, at now: TimeInterval) { field?.observe(text, at: now) }
    public mutating func observeClipboard(changeCount: Int, at now: TimeInterval, read: () -> String?) {
        guard !delivered else { return }
        clipboard.observe(changeCount: changeCount, at: now, read: read)
    }
    public mutating func end(at now: TimeInterval) {
        if endedAt == nil { endedAt = now }
        field?.end(at: now); clipboard.end(at: now)
    }
    public mutating func result(at now: TimeInterval) -> Outcome {
        guard !delivered else { return .waiting }
        ordinarySource = nil
        let fieldResult = field?.result(at: now)
        let outcome: Outcome
        if case .command(let text) = fieldResult { outcome = .command(text, .field) }
        else {
            // A valid edit owns the field channel even while its latest revision
            // is settling. An older copied completion must not beat a later
            // negation in the destination field.
            if fieldObservation == .insertion {
                if fieldResult == .ignored { ordinarySource = .field }
            } else {
                switch clipboard.result(at: now) {
                case .command(let text):
                    delivered = true
                    return .command(text, .clipboard)
                case .ignored: ordinarySource = .clipboard
                case .waiting: break
                }
            }
            // Ordinary text stays silent and leaves the existing receive window
            // open for the final transcript. It never extends the 20-second cap.
            guard let endedAt, now - endedAt >= 20 else { return .waiting }
            outcome = ordinarySource == nil ? .timedOut : .ignored
        }
        delivered = true
        return outcome
    }
}
