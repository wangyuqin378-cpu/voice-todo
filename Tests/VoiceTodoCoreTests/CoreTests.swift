import XCTest
import SwiftData
@testable import VoiceTodoCore

final class CoreTests: XCTestCase {
    let now = Date(timeIntervalSince1970: 1_900_000_000)
    func run(_ actions: [ProposedAction], _ state: Workspace = Workspace(), text: String = "提醒我", id: String = UUID().uuidString, answering: String? = nil) throws -> AppliedResult {
        try TaskReducer.apply(Proposal(actions: actions), to: state, inputID: id, input: text, answering: answering, now: now)
    }
    func task(_ name: String = "交材料", done: Bool = false) -> TodoItem {
        TodoItem(id: "material", title: name, createdAt: now, completedAt: done ? now : nil, reminderAt: now.addingTimeInterval(3600))
    }
    func complete(_ id: String = "material", evidence: String = "材料交好了") -> ProposedAction { ProposedAction(kind: .complete, taskID: id, candidates: [id], evidence: evidence) }
    func testCreateWithExactReminder() throws {
        let date = now.addingTimeInterval(3600)
        let result = try run([.init(kind: .create, title: "交材料", reminderISO: Dates.iso(date))])
        XCTAssertEqual(result.workspace.tasks.first?.reminderAt, date)
        XCTAssertTrue(result.workspace.questions.isEmpty)
    }
    func testMissingTimePersistsQuestion() throws {
        let state = try run([.init(kind: .create, title: "报销")]).workspace
        XCTAssertTrue(state.tasks[0].needsReminder)
        XCTAssertEqual(state.questions[0].taskIDs, [state.tasks[0].id])
    }
    func testNoReminderExplicit() throws {
        let state = try run([.init(kind: .create, title: "报销", noReminder: true)]).workspace
        XCTAssertFalse(state.tasks[0].needsReminder); XCTAssertTrue(state.questions.isEmpty)
    }
    func testCompleteOriginal() throws {
        let result = try run([complete()], Workspace(tasks: [task()]), text: "材料交好了")
        XCTAssertTrue(result.workspace.tasks[0].isCompleted)
        XCTAssertEqual(result.workspace.tasks.count, 1)
    }
    func testLogCompleted() throws {
        let result = try run([.init(kind: .logCompleted, title: "交材料", candidates: [], evidence: "材料交好了")], text: "材料交好了")
        XCTAssertTrue(result.workspace.tasks[0].isCompleted); XCTAssertTrue(result.workspace.questions.isEmpty)
    }
    func testRepeatedCompletionNoNewRecord() throws {
        let state = Workspace(tasks: [task(done: true)])
        let result = try run([complete()], state, text: "材料交好了")
        XCTAssertEqual(result.workspace.tasks, state.tasks); XCTAssertTrue(result.workspace.undo.isEmpty)
    }
    func testRepeatedLogNoNewRecord() throws {
        let result = try run([.init(kind: .logCompleted, title: "交材料", evidence: "材料交好了")], Workspace(tasks: [task(done: true)]), text: "材料交好了")
        XCTAssertEqual(result.workspace.tasks.count, 1)
    }
    func testUnknownIDDoesNotBecomeCompletedLog() {
        XCTAssertThrowsError(try run([complete("missing")], Workspace(tasks: [task()]), text: "材料交好了"))
    }
    func testLogCannotReplaceExistingPending() {
        XCTAssertThrowsError(try run([.init(kind: .logCompleted, title: "交材料", evidence: "材料交好了")], Workspace(tasks: [task()]), text: "材料交好了"))
    }
    func testMultipleCandidatesCannotComplete() {
        XCTAssertThrowsError(try run([.init(kind: .complete, taskID: "material", candidates: ["material", "other"], evidence: "材料交好了")], Workspace(tasks: [task()]), text: "材料交好了"))
    }
    func testAmbiguityThenSelection() throws {
        let other = TodoItem(id: "other", title: "交签证材料")
        let state = try run([.init(kind: .clarify, candidates: ["material", "other"], question: "哪份材料？", evidence: "材料交了", clarificationIntent: .complete)], Workspace(tasks: [task(), other]), text: "材料交了").workspace
        let result = try run([.init(kind: .complete, taskID: "other", resolvesQuestionID: state.questions[0].id)], state, text: "第二条", answering: state.questions[0].id)
        XCTAssertFalse(result.workspace.tasks[0].isCompleted); XCTAssertTrue(result.workspace.tasks[1].isCompleted)
        XCTAssertTrue(result.workspace.questions.isEmpty)
    }
    func testSelectionNegationBlocked() throws {
        var state = Workspace(tasks: [task()])
        state.questions = [.init(kind: .chooseTask, question: "哪份？", taskIDs: ["material"], originalInput: "材料交了", intent: .complete)]
        XCTAssertThrowsError(try run([.init(kind: .complete, taskID: "material", resolvesQuestionID: state.questions[0].id)], state, text: "第一份还没交", answering: state.questions[0].id))
    }
    func testReminderAnswer() throws {
        let state = try run([.init(kind: .create, title: "报销")]).workspace
        let result = try run([.init(kind: .setReminder, taskID: state.tasks[0].id, reminderISO: Dates.iso(now.addingTimeInterval(600)))], state, text: "十分钟后", answering: state.questions[0].id)
        XCTAssertFalse(result.workspace.tasks[0].needsReminder); XCTAssertTrue(result.workspace.questions.isEmpty)
    }
    func testNoReminderAnswer() throws {
        let state = try run([.init(kind: .create, title: "报销")]).workspace
        let result = try run([.init(kind: .setReminder, taskID: state.tasks[0].id, noReminder: true)], state, text: "不用提醒", answering: state.questions[0].id)
        XCTAssertNil(result.workspace.tasks[0].reminderAt); XCTAssertTrue(result.workspace.questions.isEmpty)
    }
    func testMixedOperations() throws {
        let result = try run([complete(), .init(kind: .create, title: "买牛奶", reminderISO: Dates.iso(now.addingTimeInterval(3600)))], Workspace(tasks: [task()]), text: "材料交好了，一个小时后提醒我买牛奶")
        XCTAssertTrue(result.workspace.tasks[0].isCompleted); XCTAssertEqual(result.workspace.tasks[1].title, "买牛奶")
        XCTAssertEqual(result.workspace.undo.count, 1)
    }
    func testAtomicFailure() {
        let state = Workspace(tasks: [task()])
        XCTAssertThrowsError(try run([.init(kind: .create, title: "买牛奶"), complete("missing")], state, text: "材料交好了"))
        XCTAssertEqual(state.tasks.count, 1); XCTAssertFalse(state.tasks[0].isCompleted)
    }
    func testRetryIdempotency() throws {
        let action = ProposedAction(kind: .create, title: "买牛奶", noReminder: true)
        let once = try run([action], id: "one").workspace
        let twice = try run([action], once, id: "one")
        XCTAssertTrue(twice.duplicate); XCTAssertEqual(twice.workspace.tasks.count, 1)
    }
    func testUndoCompletionRestoresReminderWithNewIdentity() throws {
        let original = Workspace(tasks: [task()])
        let done = try run([complete()], original, text: "材料交好了").workspace
        let restored = try TaskReducer.undo(done).workspace
        XCTAssertFalse(restored.tasks[0].isCompleted)
        XCTAssertEqual(restored.tasks[0].reminderAt, original.tasks[0].reminderAt)
        XCTAssertNotEqual(restored.tasks[0].reminderRevision, original.tasks[0].reminderRevision)
    }
    func testUndoCreateAndReplay() throws {
        let action = ProposedAction(kind: .create, title: "报销")
        let state = try run([action], id: "fixed").workspace
        let undone = try TaskReducer.undo(state).workspace
        XCTAssertTrue(undone.tasks.isEmpty); XCTAssertTrue(undone.questions.isEmpty)
        XCTAssertTrue(try run([action], undone, id: "fixed").workspace.tasks.isEmpty)
    }
    func testUndoRestoresQuestion() throws {
        let state = try run([.init(kind: .create, title: "报销")]).workspace
        let changed = try run([.init(kind: .setReminder, taskID: state.tasks[0].id, noReminder: true)], state, text: "不用提醒", answering: state.questions[0].id).workspace
        XCTAssertEqual(try TaskReducer.undo(changed).workspace.questions, state.questions)
    }
    func testPastTimeRejected() { XCTAssertThrowsError(try run([.init(kind: .create, title: "报销", reminderISO: Dates.iso(now.addingTimeInterval(-1)))])) }
    func testInvalidTimeRejected() { XCTAssertThrowsError(try run([.init(kind: .create, title: "报销", reminderISO: "明天")])) }
    func testEmptyTitleRejected() { XCTAssertThrowsError(try run([.init(kind: .create, title: "  ")])) }
    func testInventedEvidenceRejected() { XCTAssertThrowsError(try run([complete()], Workspace(tasks: [task()]), text: "提醒我交材料")) }
    func testBareTaskNameIsNotCompletion() { XCTAssertThrowsError(try run([complete(evidence: "交材料")], Workspace(tasks: [task()]), text: "交材料")) }
    func testNegativeExpressionsNeverComplete() {
        for text in ["材料还没交", "材料没有交", "材料没完成", "材料差一点做完", "材料快做完了", "准备把材料交了", "材料打算交了", "材料交了吗", "如果材料交好了", "材料应该交好了", "材料没有寄出", "不要勾选材料", "材料还未完成", "材料尚未交", "材料稍后交"] {
            XCTAssertThrowsError(try run([complete(evidence: text)], Workspace(tasks: [task()]), text: text), text)
        }
    }
    func testNegativeCannotCreateDoneRecord() { XCTAssertThrowsError(try run([.init(kind: .logCompleted, title: "材料", evidence: "还没交")], text: "材料还没交")) }
    func testSelfCorrectionToDone() throws {
        let result = try run([complete(evidence: "刚刚交好了")], Workspace(tasks: [task()]), text: "材料还没交，不对，材料刚刚交好了")
        XCTAssertTrue(result.workspace.tasks[0].isCompleted)
    }
    func testSelfCorrectionAwayFromDone() { XCTAssertThrowsError(try run([complete(evidence: "材料交好了")], Workspace(tasks: [task()]), text: "材料交好了，不对其实还没交")) }
    func testUnrelatedNegativeDoesNotBlockPositive() throws {
        let result = try run([complete(evidence: "材料交好了")], Workspace(tasks: [task()]), text: "材料交好了，牛奶还没买")
        XCTAssertTrue(result.workspace.tasks[0].isCompleted)
    }
    func testReminderPlannerSkipsDoneDeliveredScheduled() {
        let item = task()
        let id = ReminderPlanner.identifier(for: item)
        XCTAssertTrue(ReminderPlanner.plans(tasks: [task(done: true)], delivered: [], scheduled: [], now: now).isEmpty)
        XCTAssertTrue(ReminderPlanner.plans(tasks: [item], delivered: [id], scheduled: [], now: now).isEmpty)
        XCTAssertTrue(ReminderPlanner.plans(tasks: [item], delivered: [], scheduled: [id], now: now).isEmpty)
    }
    func testOverdueCatchesUpOnce() {
        var item = task(); item.reminderAt = now.addingTimeInterval(-20)
        let plans = ReminderPlanner.plans(tasks: [item], delivered: [], scheduled: [], now: now)
        XCTAssertEqual(plans.count, 1); XCTAssertTrue(plans[0].overdue); XCTAssertGreaterThan(plans[0].fireAt, now)
    }
    func testMalformedProposalRejected() { XCTAssertThrowsError(try JSONDecoder().decode(Proposal.self, from: Data("{\"actions\":[{\"kind\":\"delete\"}]}".utf8))) }
    func testSeparatedCorrectionAwayFromDone() { XCTAssertThrowsError(try run([complete(evidence: "材料交好了")], Workspace(tasks: [task()]), text: "材料交好了，不对，说错了，还没交")) }
    func testConfigurationHTTPS() {
        XCTAssertThrowsError(try AIConfiguration(baseURL: "http://localhost:8000", model: "x").endpoint())
        XCTAssertThrowsError(try AIConfiguration(baseURL: "https://user:secret@example.com/v1", model: "x").endpoint())
    }
    @MainActor func testPersistenceReopenAndAtomicCapture() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("test.store")
        var repository: Repository? = try Repository(url: url)
        let state = try run([.init(kind: .create, title: "报销")], id: "saved").workspace
        let capture = try repository!.capture("报销好了", questionID: state.questions[0].id)
        try repository!.fail(capture, message: "断网")
        try repository!.save(state)
        repository = nil
        let reopened = try Repository(url: url)
        XCTAssertEqual(try reopened.load(), state)
        let pending = try reopened.pending()
        XCTAssertEqual(pending.count, 1); XCTAssertEqual(pending[0].questionID, state.questions[0].id)
        try reopened.save(state, capture: pending[0])
        XCTAssertTrue(try reopened.pending().isEmpty)
    }
}
