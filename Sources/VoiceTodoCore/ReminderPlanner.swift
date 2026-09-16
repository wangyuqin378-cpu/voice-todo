import Foundation

public struct ReminderPlan: Equatable, Sendable {
    public var identifier: String
    public var taskID: String
    public var title: String
    public var fireAt: Date
    public var overdue: Bool
}

public enum ReminderPlanner {
    public static func identifier(for item: TodoItem) -> String { "todo.\(item.id).\(item.reminderRevision)" }
    public static func plans(tasks: [TodoItem], delivered: Set<String>, scheduled: Set<String>, now: Date) -> [ReminderPlan] {
        tasks.compactMap { item in
            guard !item.isCompleted, let date = item.reminderAt else { return nil }
            let id = identifier(for: item)
            guard !delivered.contains(id), !scheduled.contains(id) else { return nil }
            return ReminderPlan(identifier: id, taskID: item.id, title: item.title,
                                fireAt: max(date, now.addingTimeInterval(2)), overdue: date <= now)
        }.sorted { $0.fireAt == $1.fireAt ? $0.identifier < $1.identifier : $0.fireAt < $1.fireAt }
    }
}
