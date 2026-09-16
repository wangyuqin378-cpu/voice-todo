import Foundation

/// The only accepted edit replaces the original selection and leaves both surrounding
/// strings byte-for-byte equivalent. Supports UTF-16 selections and emoji correctly.
public struct TranscriptionCapture: Sendable {
    public enum Outcome: Equatable { case waiting, ignored, command(String) }
    public enum Observation: Equatable, Sendable { case unchanged, outsideSelection, emptyInsertion, insertion }
    public let id: String
    public let baseline: String
    public let selection: NSRange
    public let questionID: String?
    private var latest: String?
    private var changedAt: TimeInterval?
    private var endedAt: TimeInterval?
    public private(set) var delivered = false
    public private(set) var observation: Observation = .unchanged
    public init?(baseline: String, selection: NSRange, id: String = UUID().uuidString, questionID: String? = nil) {
        guard baseline.utf16.count <= 25_000, selection.location != NSNotFound,
              selection.location >= 0, selection.length >= 0,
              selection.location <= baseline.utf16.count,
              selection.length <= baseline.utf16.count - selection.location,
              let range = Range(selection, in: baseline),
              range.lowerBound.samePosition(in: baseline.unicodeScalars) != nil,
              range.upperBound.samePosition(in: baseline.unicodeScalars) != nil else { return nil }
        self.baseline = baseline; self.selection = selection; self.id = id; self.questionID = questionID
    }
    public func insertion(in current: String) -> String? {
        // Accessibility ranges use UTF-16, not grapheme counts. A combining mark
        // can join the last inserted character, changing String.count boundaries.
        // Compare code units literally as well: canonically equivalent text is
        // still an edit to surrounding content and must not pass this check.
        let original = Array(baseline.utf16)
        let updated = Array(current.utf16)
        guard updated != original, updated.count <= 50_000 else { return nil }
        let prefix = original.prefix(selection.location)
        let suffix = original.suffix(original.count - selection.location - selection.length)
        guard updated.count >= prefix.count + suffix.count,
              updated.starts(with: prefix), updated.suffix(suffix.count).elementsEqual(suffix) else { return nil }
        return String(decoding: updated.dropFirst(prefix.count).dropLast(suffix.count), as: UTF16.self)
    }
    public mutating func end(at now: TimeInterval) { if endedAt == nil { endedAt = now } }
    public mutating func observe(_ current: String, at now: TimeInterval) {
        if current != latest {
            latest = current; changedAt = now
            if Array(current.utf16) == Array(baseline.utf16) { observation = .unchanged }
            else if let inserted = insertion(in: current) {
                observation = inserted.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? .emptyInsertion : .insertion
            } else { observation = .outsideSelection }
        }
    }
    public mutating func ready(at now: TimeInterval) -> String? {
        if case .command(let text) = result(at: now) { return text }
        return nil
    }
    public mutating func result(at now: TimeInterval) -> Outcome {
        guard !delivered, let end = endedAt, now - end >= 1.2,
              let changedAt, now - changedAt >= 1.2, let latest,
              let inserted = insertion(in: latest), !inserted.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return .waiting }
        // Classification of an intermediate ordinary snapshot is not delivery.
        guard CommandText.accepts(inserted) || questionID != nil else { return .ignored }
        delivered = true
        return .command(inserted.trimmingCharacters(in: .whitespacesAndNewlines))
    }
}
