import Foundation

/// Permission to import background dictation is separate from understanding it.
/// Generic planning verbs, dates and completion phrases are not an opt-in.
public enum AutomaticCapturePolicy {
    public static func accepts(_ input: String) -> Bool {
        let text = input.trimmingCharacters(in: .whitespacesAndNewlines)
        let separators = CharacterSet.whitespacesAndNewlines.union(.punctuationCharacters)
        for prefix in ["提醒我", "帮我记录一下"] where text.hasPrefix(prefix) {
            return !String(text.dropFirst(prefix.count)).trimmingCharacters(in: separators).isEmpty
        }
        // Keep an explicit app address for completion, cancellation, undo and
        // follow-up answers. Do not guess a wake phrase from a similar ASR word.
        guard text.hasPrefix("清单") || text.hasPrefix("随口清单"),
              let body = CommandText.body(text) else { return false }
        return !body.trimmingCharacters(in: separators).isEmpty
    }
}
