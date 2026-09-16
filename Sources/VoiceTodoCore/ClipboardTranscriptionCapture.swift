import Foundation

/// Watches only ownership changes after the user starts dictation. The reader is
/// never called for the pre-existing clipboard, and unrelated text is not emitted.
public struct ClipboardTranscriptionCapture: Sendable {
    public enum Outcome: Equatable { case waiting, ignored, command(String) }
    public let id: String
    public let questionID: String?
    private var changeCount: Int
    private var hasNewOwnership = false
    private var text: String?
    private var changedAt: TimeInterval?
    private var endedAt: TimeInterval?
    private var delivered = false

    public init(changeCount: Int, id: String = UUID().uuidString, questionID: String? = nil) {
        self.changeCount = changeCount; self.id = id; self.questionID = questionID
    }
    public mutating func observe(changeCount: Int, at now: TimeInterval, read: () -> String?) {
        guard !delivered else { return }
        let ownershipChanged = changeCount != self.changeCount
        guard ownershipChanged || hasNewOwnership else { return }
        hasNewOwnership = true
        self.changeCount = changeCount
        // clearContents changes ownership; a subsequent setString by that owner
        // may keep the same count. Keep observing this new generation until quiet.
        let value = read()?.trimmingCharacters(in: .whitespacesAndNewlines)
        let next = value.flatMap { !$0.isEmpty && $0.utf16.count <= 25_000 ? $0 : nil }
        if ownershipChanged || next != text { changedAt = now }
        text = next
    }
    public mutating func end(at now: TimeInterval) { if endedAt == nil { endedAt = now } }
    public mutating func result(at now: TimeInterval) -> Outcome {
        guard !delivered, let endedAt, now - endedAt >= 1.2,
              let changedAt, now - changedAt >= 1.2, let text else { return .waiting }
        // An ordinary snapshot can precede the input method's final write.
        // Only emitting a command consumes this channel; the owning session
        // bounds how long an ignored snapshot may wait for a revision.
        guard AutomaticCapturePolicy.accepts(text) else { return .ignored }
        delivered = true
        return .command(text)
    }
}
