import Foundation

/// A short conversation lease. A pending task question alone never authorizes
/// importing unrelated dictation from another field or a later session.
public struct DictationReplyWindow: Sendable {
    public let questionID: String
    public let sourceID: String
    public let expiresAt: TimeInterval

    public init(questionID: String, sourceID: String, now: TimeInterval) {
        self.questionID = questionID; self.sourceID = sourceID; expiresAt = now + 120
    }

    public func answerID(sourceID: String?, pendingQuestionID: String?, now: TimeInterval) -> String? {
        guard now < expiresAt, sourceID == self.sourceID, pendingQuestionID == questionID else { return nil }
        return questionID
    }
}
