import XCTest
import VoiceTodoCore
@testable import VoiceTodoApp

final class EvaluationChecksTests: XCTestCase {
    private let now = Dates.parse("2026-09-15T10:00:00+08:00")!
    private let tomorrow = "2026-09-16T15:00:00+08:00"

    private func sample(_ tasks: [EvaluationCase.NewTask], pending: [String] = [], completed: [String] = []) -> EvaluationCase {
        EvaluationCase(id: "qa", text: "测试", pending: pending, done: [], completedIDs: completed,
                       question: false, nowISO: "2026-09-15T10:00:00+08:00", timeZoneID: "Asia/Shanghai", newTasks: tasks)
    }

    func testSameCountWithWrongReminderDateFails() {
        let expected = sample([.init(titles: ["交材料"], completed: false, reminderISO: tomorrow, needsReminder: false)])
        let wrong = TodoItem(title: "交材料", reminderAt: Dates.parse("2026-09-17T15:00:00+08:00"))
        XCTAssertFalse(EvaluationChecks.compare(Workspace(tasks: [wrong]), seed: Workspace(), expected: expected).passed)
        var right = wrong; right.reminderAt = Dates.parse(tomorrow)
        XCTAssertTrue(EvaluationChecks.compare(Workspace(tasks: [right]), seed: Workspace(), expected: expected).passed)
    }

    func testWrongCompletedRecordCannotPassByMatchingCounts() {
        let expected = sample([.init(titles: ["取快递"], completed: true, reminderISO: nil, needsReminder: false)])
        let wrong = TodoItem(title: "交材料", completedAt: now)
        let result = EvaluationChecks.compare(Workspace(tasks: [wrong]), seed: Workspace(), expected: expected)
        XCTAssertFalse(result.passed)
        XCTAssertTrue(result.falseCompletion)
    }

    func testUnexpectedEditsOrDeletedOriginalTasksFail() {
        let original = TodoItem(id: "p0", title: "交材料")
        let seed = Workspace(tasks: [original])
        let expected = sample([], pending: ["交材料"])
        var changed = original; changed.reminderAt = Dates.parse(tomorrow)
        XCTAssertFalse(EvaluationChecks.compare(Workspace(tasks: [changed]), seed: seed, expected: expected).passed)
        XCTAssertFalse(EvaluationChecks.compare(Workspace(), seed: seed, expected: expected).passed)
        changed = original; changed.completedAt = now
        XCTAssertTrue(EvaluationChecks.compare(Workspace(tasks: [changed]), seed: seed, expected: expected).falseCompletion)
    }

    func testOrderIndependentMatchingDoesNotReuseOneExpectedTask() {
        let expected = sample([
            .init(titles: ["买牛奶", "购买牛奶"], completed: false, reminderISO: nil, needsReminder: false),
            .init(titles: ["买牛奶"], completed: false, reminderISO: nil, needsReminder: false)
        ])
        let actual = Workspace(tasks: [TodoItem(title: "买牛奶"), TodoItem(title: "购买牛奶")])
        XCTAssertTrue(EvaluationChecks.compare(actual, seed: Workspace(), expected: expected).passed)
        let duplicate = Workspace(tasks: [TodoItem(title: "购买牛奶"), TodoItem(title: "购买牛奶")])
        XCTAssertFalse(EvaluationChecks.compare(duplicate, seed: Workspace(), expected: expected).passed)
    }

    func testTimeMustBelongToTheCorrectTask() {
        let expected = sample([
            .init(titles: ["关烤箱"], completed: false, reminderISO: "2026-09-15T10:10:00+08:00", needsReminder: false),
            .init(titles: ["出门"], completed: false, reminderISO: "2026-09-15T10:30:00+08:00", needsReminder: false)
        ])
        let swapped = Workspace(tasks: [
            TodoItem(title: "关烤箱", reminderAt: Dates.parse("2026-09-15T10:30:00+08:00")),
            TodoItem(title: "出门", reminderAt: Dates.parse("2026-09-15T10:10:00+08:00"))
        ])
        XCTAssertFalse(EvaluationChecks.compare(swapped, seed: Workspace(), expected: expected).passed)
    }

    func testMissingReminderFollowupCannotPassAsNoReminder() {
        var expected = sample([.init(titles: ["报销"], completed: false, reminderISO: nil, needsReminder: true)])
        expected.question = true
        var actual = Workspace(tasks: [TodoItem(title: "报销")])
        actual.questions = [FollowUp(kind: .reminder, question: "什么时候", taskIDs: [], originalInput: "报销")]
        XCTAssertFalse(EvaluationChecks.compare(actual, seed: Workspace(), expected: expected).passed)
    }

    func testFixtureRejectsBadDateAndAllCheckedInCasesHaveExplicitExpectations() throws {
        var invalid = sample([.init(titles: ["材料"], completed: false, reminderISO: "bad-date", needsReminder: false)])
        XCTAssertThrowsError(try invalid.validate())
        invalid.newTasks = []; invalid.timeZoneID = "bad-zone"
        XCTAssertThrowsError(try invalid.validate())
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let cases = try JSONDecoder().decode([EvaluationCase].self, from: Data(contentsOf: root.appending(path: "qa/cases.json")))
        XCTAssertEqual(cases.count, 36)
        XCTAssertEqual(Set(cases.map(\.id)).count, cases.count)
        for item in cases { XCTAssertNoThrow(try item.validate(), item.id) }
    }
}
