import Foundation
import VoiceTodoCore

// Expectations are independent of the model's proposal. A passing automatic check
// still requires review of phrasing and a separate microphone/desktop acceptance run.
struct EvaluationCase: Codable {
    struct NewTask: Codable {
        var titles: [String]
        var completed: Bool
        var reminderISO: String?
        var needsReminder: Bool
        var plannedISO: String? = nil
        var plannedHasTime: Bool? = nil

        func matches(_ task: TodoItem) -> Bool {
            titles.map(TaskReducer.normalized).contains(TaskReducer.normalized(task.title))
                && task.isCompleted == completed
                && task.reminderAt == reminderISO.flatMap(Dates.parse)
                && task.needsReminder == needsReminder
                && task.plannedAt == plannedISO.flatMap(Dates.parse)
                && (plannedISO == nil || task.plannedHasTime == plannedHasTime)
        }
    }
    var id: String
    var text: String
    var pending: [String]
    var done: [String]
    var completedIDs: [String]
    var question: Bool
    var nowISO: String
    var timeZoneID: String
    var newTasks: [NewTask]

    func validate() throws -> (Date, TimeZone) {
        guard let now = Dates.parse(nowISO), let zone = TimeZone(identifier: timeZoneID),
              !id.isEmpty, !text.isEmpty,
              Set(completedIDs).count == completedIDs.count,
              completedIDs.allSatisfy({ id in pending.indices.contains { id == "p\($0)" } }),
              newTasks.allSatisfy({ item in
                  !item.titles.isEmpty && item.titles.allSatisfy { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
                      && (item.reminderISO == nil || Dates.parse(item.reminderISO!) != nil)
                      && (item.plannedISO == nil || (Dates.parse(item.plannedISO!) != nil && item.plannedHasTime != nil))
                      && !(item.completed && (item.needsReminder || item.reminderISO != nil))
                      && !(item.needsReminder && item.reminderISO != nil)
              }) else { throw UserFacingError("验收用例 \(id) 缺少有效的日期、标题或预期任务状态。") }
        return (now, zone)
    }
}

enum EvaluationChecks {
    struct Result {
        var issues: [String]
        var falseCompletion: Bool
        var passed: Bool { issues.isEmpty }
    }

    static func compare(_ actual: Workspace, seed: Workspace, expected: EvaluationCase) -> Result {
        var issues: [String] = []
        var falseCompletion = false
        let expectedCompleted = Set(expected.completedIDs)
        let seedIDs = Set(seed.tasks.map(\.id))
        if Set(actual.tasks.map(\.id)).count != actual.tasks.count { issues.append("结果存在重复任务标识") }
        for original in seed.tasks {
            guard let task = actual.tasks.first(where: { $0.id == original.id }) else {
                issues.append("原任务丢失：\(original.id)"); continue
            }
            let shouldComplete = original.isCompleted || expectedCompleted.contains(original.id)
            if task.isCompleted != shouldComplete { issues.append("完成对象不符合预期：\(original.id)") }
            if task.isCompleted && !shouldComplete { falseCompletion = true }
            if task.title != original.title || task.reminderAt != original.reminderAt || task.plannedAt != original.plannedAt || task.plannedHasTime != original.plannedHasTime {
                issues.append("原任务标题、日期或提醒被意外修改：\(original.id)")
            }
            let expectedNeedsReminder = shouldComplete ? false : original.needsReminder
            if task.needsReminder != expectedNeedsReminder { issues.append("原任务待补提醒状态被意外修改：\(original.id)") }
        }
        let created = actual.tasks.filter { !seedIDs.contains($0.id) }
        if created.count != expected.newTasks.count { issues.append("新增任务数量不符") }
        // Match complete task records, never title and time independently. Backtracking
        // handles overlapping accepted title variants without depending on model order.
        func unmatched(_ tasks: [TodoItem], against expectations: [EvaluationCase.NewTask]) -> Int {
            guard let task = tasks.first else { return 0 }
            let rest = Array(tasks.dropFirst())
            var best = 1 + unmatched(rest, against: expectations)
            for index in expectations.indices where expectations[index].matches(task) {
                var remaining = expectations; remaining.remove(at: index)
                best = min(best, unmatched(rest, against: remaining))
            }
            return best
        }
        if unmatched(created, against: expected.newTasks) > 0 {
            issues.append("新增事项标题、完成状态、事项日期、具体提醒时间或待补提醒状态不符")
        }
        // A wrong completed record cannot hide behind the correct total count.
        if unmatched(created.filter(\.isCompleted), against: expected.newTasks.filter(\.completed)) > 0 {
            falseCompletion = true
        }
        if !actual.questions.isEmpty != expected.question { issues.append("追问状态不符") }
        return Result(issues: issues, falseCompletion: falseCompletion)
    }
}
