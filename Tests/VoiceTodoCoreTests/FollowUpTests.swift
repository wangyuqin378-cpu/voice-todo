import XCTest
@testable import VoiceTodoCore

final class FollowUpTests: XCTestCase {
    let now = Date(timeIntervalSince1970: 1_900_000_000)
    var tasks: [TodoItem] { [.init(id: "a", title: "交项目材料"), .init(id: "b", title: "交签证材料")] }
    func apply(_ actions: [ProposedAction], _ state: Workspace, text: String = "第一条", answering: String? = nil) throws -> Workspace {
        try TaskReducer.apply(.init(actions: actions), to: state, inputID: UUID().uuidString, input: text, answering: answering, now: now).workspace
    }
    func choice(_ intent: FollowUp.Intent?, time: Date? = nil) -> Workspace {
        var state = Workspace(tasks: tasks)
        state.questions = [.init(kind: .chooseTask, question: "哪一份材料？", taskIDs: ["a", "b"], originalInput: "材料的提醒改一下", id: "q", intent: intent, reminderISO: time.map(Dates.iso))]
        return state
    }
    func testClickReminderCandidateOnlyChangesReminder() throws {
        let time = now.addingTimeInterval(600)
        let result = try TaskReducer.selectTask("b", questionID: "q", in: choice(.setReminder, time: time), inputID: "click", now: now).workspace
        XCTAssertEqual(result.tasks[1].reminderAt, time)
        XCTAssertTrue(result.tasks.allSatisfy { !$0.isCompleted })
        XCTAssertTrue(result.questions.isEmpty)
        XCTAssertNil(result.tasks[0].reminderAt)
    }
    func testReminderCandidateWithMissingTimeAsksAndCanUndo() throws {
        var original = choice(.setReminder)
        original.tasks[0].reminderAt = now.addingTimeInterval(900)
        let result = try TaskReducer.selectTask("a", questionID: "q", in: original, inputID: "click", now: now).workspace
        XCTAssertEqual(result.tasks, original.tasks)
        XCTAssertEqual(result.questions.first?.kind, .reminder)
        XCTAssertEqual(result.questions.first?.taskIDs, ["a"])
        XCTAssertEqual(try TaskReducer.undo(result).workspace.questions, original.questions)
    }
    func testUntypedOldCandidateNeverDirectlyCompletes() throws {
        XCTAssertThrowsError(try TaskReducer.selectTask("a", questionID: "q", in: choice(nil), inputID: "click", now: now))
        XCTAssertThrowsError(try apply([.init(kind: .complete, taskID: "a", resolvesQuestionID: "q")], choice(nil), answering: "q"))
    }
    func testModelCannotCompleteReminderSelection() {
        XCTAssertThrowsError(try apply([.init(kind: .complete, taskID: "a", resolvesQuestionID: "q")], choice(.setReminder), answering: "q"))
    }
    func testChangedIntentAfterCompletionQuestionNeverCompletes() {
        for input in ["第一条，改成明天提醒", "第一条还没交", "取消，第一条", "先恢复第一条"] {
            XCTAssertThrowsError(try apply([.init(kind: .complete, taskID: "a", resolvesQuestionID: "q")], choice(.complete), text: input, answering: "q"))
        }
    }
    func testSelectionRequiresExplicitQuestionReference() {
        XCTAssertThrowsError(try apply([.init(kind: .complete, taskID: "a")], choice(.complete), answering: "q"))
    }
    func testCompletionQuestionNeedsPositiveOriginalEvidence() {
        XCTAssertThrowsError(try apply([.init(kind: .clarify, candidates: ["a", "b"], question: "完成哪条？", evidence: "材料还没交", clarificationIntent: .complete)], Workspace(tasks: tasks), text: "材料还没交"))
    }
    func testRefiningCompletionQuestionCannotCarryNegationForward() {
        XCTAssertThrowsError(try apply([.init(kind: .clarify, candidates: ["a"], question: "这条吗？", clarificationIntent: .complete, resolvesQuestionID: "q")], choice(.complete), text: "第一条还没交", answering: "q"))
    }
    func testNewClarificationPreservesOldQuestionAndItsOwnOriginalInput() throws {
        let original = choice(.setReminder)
        let result = try apply([.init(kind: .clarify, question: "每天提醒暂不支持，本次什么时候提醒？", clarificationIntent: .other)], original, text: "每天提醒我喝水", answering: "q")
        XCTAssertEqual(result.questions.count, 2)
        XCTAssertEqual(result.questions.first, original.questions.first)
        XCTAssertEqual(result.questions.last?.originalInput, "每天提醒我喝水")
    }
    func testNewTaskDoesNotConsumeGenericQuestion() throws {
        var state = Workspace()
        state.questions = [.init(kind: .clarification, question: "本次什么时候？", taskIDs: [], originalInput: "每天提醒喝水", id: "q")]
        let result = try apply([.init(kind: .create, title: "买牛奶", noReminder: true)], state, text: "另外记一下买牛奶，不用提醒", answering: "q")
        XCTAssertEqual(result.questions, state.questions)
        XCTAssertEqual(result.tasks.count, 1)
    }
    func testExplicitGenericAnswerConsumesOnlyItsOwnQuestion() throws {
        var state = Workspace()
        state.questions = [.init(kind: .clarification, question: "本次什么时候？", taskIDs: [], originalInput: "每天提醒喝水", id: "q"), .init(kind: .clarification, question: "什么文件？", taskIDs: [], originalInput: "文件好了", id: "other")]
        let result = try apply([.init(kind: .create, title: "喝水", reminderISO: Dates.iso(now.addingTimeInterval(600)), resolvesQuestionID: "q")], state, text: "那就十分钟后一次", answering: "q")
        XCTAssertEqual(result.questions.map(\.id), ["other"])
    }
    func testLegacyReminderEditQuestionCannotBeRefinedThroughVoice() throws {
        let state = choice(.setReminder)
        XCTAssertThrowsError(try apply([.init(kind: .clarify, candidates: ["a"], question: "项目材料，什么时候？", resolvesQuestionID: "q")], state, answering: "q"))
    }
    func testCompletedSelectionRetryIsIdempotentAfterQuestionDisappears() throws {
        let first = try TaskReducer.selectTask("a", questionID: "q", in: choice(.complete), inputID: "click", now: now).workspace
        let retry = try TaskReducer.selectTask("a", questionID: "q", in: first, inputID: "click", now: now)
        XCTAssertTrue(retry.duplicate)
        XCTAssertEqual(retry.workspace, first)
    }
    func testWrongQuestionReferenceRejected() {
        XCTAssertThrowsError(try apply([.init(kind: .setReminder, taskID: "a", noReminder: true, resolvesQuestionID: "missing")], choice(.setReminder), answering: "q"))
    }
    func testUnrelatedTaskCannotConsumeReminderQuestion() {
        var state = choice(.setReminder); state.questions[0].taskIDs = ["a"]
        XCTAssertThrowsError(try apply([.init(kind: .setReminder, taskID: "b", noReminder: true, resolvesQuestionID: "q")], state, answering: "q"))
    }
    func testCompletingTaskPreservesOtherCandidatesOfUnrelatedQuestion() throws {
        let state = choice(.setReminder)
        let result = try apply([.init(kind: .complete, taskID: "a", candidates: ["a"], evidence: "项目材料交好了")], state, text: "项目材料交好了")
        XCTAssertEqual(result.questions[0].taskIDs, ["b"])
        XCTAssertFalse(result.tasks[1].isCompleted)
    }
    func testTitleEditPreservesAmbiguousQuestion() throws {
        let state = choice(.setReminder)
        var item = state.tasks[0]; item.title = "交新版项目材料"
        let result = try TaskReducer.manualEdit(item, in: state, summary: "修改标题")
        XCTAssertEqual(result.questions, state.questions)
    }
    func testPastTimeInCandidateSelectionDoesNotCompleteOrReschedule() {
        let state = choice(.setReminder, time: now.addingTimeInterval(-1))
        XCTAssertThrowsError(try TaskReducer.selectTask("a", questionID: "q", in: state, inputID: "click", now: now))
        XCTAssertTrue(state.tasks.allSatisfy { !$0.isCompleted && $0.reminderAt == nil })
    }
    func testContradictoryReminderRejected() {
        XCTAssertThrowsError(try apply([.init(kind: .create, title: "喝水", reminderISO: Dates.iso(now.addingTimeInterval(600)), noReminder: true)], Workspace()))
    }
    func testLegacyQuestionDecodesWithoutAssumingCompletion() throws {
        let json = #"{"id":"old","kind":"chooseTask","question":"哪条？","taskIDs":["a"],"originalInput":"改提醒"}"#
        let question = try JSONDecoder().decode(FollowUp.self, from: Data(json.utf8))
        XCTAssertNil(question.intent)
    }
}
