import Foundation

public struct TodoItem: Codable, Equatable, Identifiable, Sendable {
    public var id: String
    public var title: String
    public var createdAt: Date
    public var completedAt: Date?
    public var reminderAt: Date?
    public var plannedAt: Date?
    public var plannedHasTime: Bool?
    public var reminderRevision: String
    public var needsReminder: Bool
    public var originalInput: String
    public var isCompleted: Bool { completedAt != nil }

    public init(id: String = UUID().uuidString, title: String, createdAt: Date = .now,
                completedAt: Date? = nil, reminderAt: Date? = nil, needsReminder: Bool = false,
                originalInput: String = "", plannedAt: Date? = nil, plannedHasTime: Bool? = nil) {
        self.id = id; self.title = title; self.createdAt = createdAt
        self.completedAt = completedAt; self.reminderAt = reminderAt
        self.reminderRevision = UUID().uuidString; self.needsReminder = needsReminder
        self.originalInput = originalInput
        self.plannedAt = plannedAt; self.plannedHasTime = plannedHasTime
    }
}

public struct FollowUp: Codable, Equatable, Identifiable, Sendable {
    public enum Kind: String, Codable, Sendable { case reminder, chooseTask, clarification }
    public enum Intent: String, Codable, Sendable { case complete, cancelTask, setReminder, other }
    public var id: String
    public var kind: Kind
    public var question: String
    public var taskIDs: [String]
    public var originalInput: String
    public var intent: Intent?
    public var reminderISO: String?
    public var noReminder: Bool?
    public var suggestedTitle: String?
    public var plannedISO: String?
    public var plannedHasTime: Bool?
    public init(kind: Kind, question: String, taskIDs: [String], originalInput: String,
                id: String = UUID().uuidString, intent: Intent? = nil,
                reminderISO: String? = nil, noReminder: Bool? = nil, suggestedTitle: String? = nil,
                plannedISO: String? = nil, plannedHasTime: Bool? = nil) {
        self.id = id; self.kind = kind; self.question = question
        self.taskIDs = taskIDs; self.originalInput = originalInput
        self.intent = intent; self.reminderISO = reminderISO; self.noReminder = noReminder
        self.suggestedTitle = suggestedTitle
        self.plannedISO = plannedISO; self.plannedHasTime = plannedHasTime
    }
}

public struct UndoEntry: Codable, Equatable, Identifiable, Sendable {
    public var id = UUID().uuidString
    public var tasks: [TodoItem]
    public var questions: [FollowUp]
    public var summary: String
}

public struct Activity: Codable, Equatable, Sendable {
    public var summary: String
    public var date: Date
    public init(_ summary: String, date: Date = .now) { self.summary = summary; self.date = date }
}

public struct Workspace: Codable, Equatable, Sendable {
    public var tasks: [TodoItem] = []
    public var questions: [FollowUp] = []
    public var appliedInputs: Set<String> = []
    public var undo: [UndoEntry] = []
    public var lastActivity: Activity?
    public init(tasks: [TodoItem] = []) { self.tasks = tasks }
}

public struct ProposedAction: Codable, Equatable, Sendable {
    public enum Kind: String, Codable, Sendable {
        case create, complete, cancelTask, logCompleted, setReminder, clarify, alreadyCompleted, undo, noop
    }
    public var kind: Kind
    public var taskID: String?
    public var title: String?
    public var reminderISO: String?
    public var noReminder: Bool?
    public var candidates: [String]?
    public var question: String?
    public var evidence: String?
    public var clarificationIntent: FollowUp.Intent?
    public var resolvesQuestionID: String?
    public var plannedISO: String?
    public var plannedHasTime: Bool?
    public init(kind: Kind, taskID: String? = nil, title: String? = nil,
                reminderISO: String? = nil, noReminder: Bool? = nil, candidates: [String]? = nil,
                question: String? = nil, evidence: String? = nil,
                clarificationIntent: FollowUp.Intent? = nil, resolvesQuestionID: String? = nil,
                plannedISO: String? = nil, plannedHasTime: Bool? = nil) {
        self.kind = kind; self.taskID = taskID; self.title = title
        self.reminderISO = reminderISO; self.noReminder = noReminder
        self.candidates = candidates; self.question = question; self.evidence = evidence
        self.clarificationIntent = clarificationIntent; self.resolvesQuestionID = resolvesQuestionID
        self.plannedISO = plannedISO; self.plannedHasTime = plannedHasTime
    }
}

public struct Proposal: Codable, Sendable {
    public var actions: [ProposedAction]
    public init(actions: [ProposedAction]) { self.actions = actions }
}

public struct AppliedResult: Sendable {
    public var workspace: Workspace
    public var messages: [String]
    public var duplicate: Bool
}

public struct UserFacingError: LocalizedError, Equatable, Sendable {
    public var message: String
    public var errorDescription: String? { message }
    public init(_ message: String) { self.message = message }
}

public enum Dates {
    public static func planned(_ date: Date, hasTime: Bool) -> String {
        let f = DateFormatter(); f.locale = Locale(identifier: "zh_CN")
        f.dateFormat = hasTime ? "M月d日 E HH:mm" : "M月d日 E"
        return f.string(from: date)
    }
    public static func parse(_ string: String) -> Date? {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = formatter.date(from: string) { return date }
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.date(from: string)
    }
    public static func iso(_ date: Date) -> String { ISO8601DateFormatter().string(from: date) }
    public static func iso(_ date: Date, timeZone: String) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.timeZone = TimeZone(identifier: timeZone)
        return formatter.string(from: date)
    }
    public static func display(_ date: Date) -> String {
        let f = DateFormatter(); f.locale = Locale(identifier: "zh_CN")
        f.dateFormat = "M月d日 E HH:mm"; return f.string(from: date)
    }
}
