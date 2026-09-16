import XCTest
@testable import VoiceTodoCore

final class NaturalReminderTests: XCTestCase {
    let now = Dates.parse("2026-09-15T10:00:00+08:00")!
    let original = "帮我明确一下，明天下午 3 点的面试。"
    func parse(_ text: String, state: Workspace = .init(), question: FollowUp? = nil, at: Date? = nil) throws -> Proposal {
        try XCTUnwrap(LocalInterpreter.interpret(text, workspace: state, question: question,
            now: at ?? now, timeZone: "Asia/Shanghai"), text)
    }
    func candidate() throws -> Workspace {
        try TaskReducer.apply(parse(original), to: .init(), inputID: "first", input: original, now: now).workspace
    }
    func testScreenshotPhraseAsksBeforeCreating() throws {
        XCTAssertTrue(CommandText.accepts(original))
        XCTAssertNil(CommandText.body(original))
        let state = try candidate()
        XCTAssertTrue(state.tasks.isEmpty)
        let q = try XCTUnwrap(state.questions.first)
        XCTAssertNil(q.reminderISO)
        XCTAssertEqual(q.suggestedTitle, "面试")
        XCTAssertEqual(Dates.parse(try XCTUnwrap(q.plannedISO)), Dates.parse("2026-09-16T15:00:00+08:00"))
        XCTAssertEqual(q.originalInput, original)
        XCTAssertTrue(q.question.contains("面试"))
        XCTAssertTrue(q.question.contains("是"))
    }
    func testYesCreatesOnceAtOriginalTimeAndUndoRestoresQuestion() throws {
        let state = try candidate(), q = try XCTUnwrap(state.questions.first)
        let later = now.addingTimeInterval(86400)
        let proposal = try parse("是的。", state: state, question: q, at: later)
        let result = try TaskReducer.apply(proposal, to: state, inputID: "answer", input: "是的。", answering: q.id, now: later).workspace
        XCTAssertEqual(result.tasks.count, 1)
        XCTAssertTrue(result.questions.isEmpty)
        XCTAssertEqual(result.tasks[0].title, "面试")
        XCTAssertEqual(result.tasks[0].plannedAt, Dates.parse("2026-09-16T15:00:00+08:00"))
        XCTAssertEqual(try TaskReducer.apply(proposal, to: result, inputID: "answer", input: "是的。", answering: q.id, now: later).workspace, result)
        let undone = try TaskReducer.undo(result).workspace
        XCTAssertTrue(undone.tasks.isEmpty)
        XCTAssertEqual(undone.questions, state.questions)
        XCTAssertThrowsError(try TaskReducer.apply(proposal, to: state, inputID: "wrong", input: "是", answering: "other", now: now))
    }
    func testDeclineClosesOnlyThisQuestion() throws {
        for answer in ["不用", "不用了。", "不要", "不是", "取消", "不需要", "不用提醒", "清单，不用", "清单不用"] {
            var state = try candidate()
            let q = try XCTUnwrap(state.questions.first)
            let other = FollowUp(kind: .clarification, question: "完成哪件？", taskIDs: [], originalInput: "材料交好了")
            state.questions.append(other)
            let result = try TaskReducer.apply(parse(answer, state: state, question: q), to: state,
                inputID: answer, input: answer, answering: q.id, now: now).workspace
            XCTAssertTrue(result.tasks.isEmpty, answer)
            XCTAssertEqual(result.questions, [other], answer)
        }
    }
    func testNaturalExplicitRequestsStayLocal() throws {
        for text in ["提醒我明天下午3点面试", "帮我提醒一下，明天下午3点的面试。", "请提醒我明天下午三点面试", "明天下午三点提醒我面试"] {
            XCTAssertTrue(CommandText.accepts(text), text)
            let result = try TaskReducer.apply(parse(text), to: .init(), inputID: text, input: text, now: now).workspace
            XCTAssertEqual(result.tasks.first?.title, "面试", text)
            XCTAssertEqual(result.tasks.first?.reminderAt, Dates.parse("2026-09-16T14:50:00+08:00"), text)
            XCTAssertTrue(result.questions.isEmpty, text)
        }
        for text in ["十分钟后提醒我取快递", "半小时后提醒我取快递"] {
            XCTAssertTrue(CommandText.accepts(text), text)
            XCTAssertEqual(try parse(text).actions.first?.kind, .create)
        }
        XCTAssertEqual(try parse("提醒我明天下午三点半面试").actions.first?.reminderISO,
            Dates.iso(Dates.parse("2026-09-16T15:20:00+08:00")!))
    }
    func testOrdinaryOrQuotedConversationDoesNotEnableCapture() {
        for text in ["清单是的", "清单不用"] { XCTAssertTrue(CommandText.accepts(text), text) }
        for text in ["他说提醒我明天下午三点面试", "比如帮我明确一下明天下午三点面试", "“提醒我明天下午三点面试”", "帮我明确一下明天下午三点不用面试", "帮我明确一下明天下午三点面试？"] {
            XCTAssertFalse(CommandText.accepts(text), text)
        }
    }
    func testInvalidCandidateTimeCannotCreateAndCorrectionsAreNotYes() throws {
        XCTAssertEqual(try parse("帮我明确一下，明天下午二十五点的面试").actions.map(\.kind), [.clarify])
        let state = try candidate(), q = try XCTUnwrap(state.questions.first)
        for answer in ["还没完成", "是，不对，取消", "差一点完成", "不是明天，是后天"] {
            XCTAssertNil(LocalInterpreter.interpret(answer, workspace: state, question: q, now: now, timeZone: "Asia/Shanghai"), answer)
        }
    }
    @MainActor func testQuestionSurvivesDiskReopenAndOldPayloadRemainsReadable() throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appending(path: "tasks.store")
        var repository: Repository? = try Repository(url: url)
        let state = try candidate()
        let capture = try repository!.capture(original, questionID: nil, now: now)
        try repository!.save(state, capture: capture)
        repository = nil
        let reopened = try Repository(url: url)
        XCTAssertEqual(try reopened.load().questions, state.questions)
        let old = #"{"id":"old","kind":"clarification","question":"哪件事？","taskIDs":[],"originalInput":"原话"}"#.data(using: .utf8)!
        XCTAssertNil(try JSONDecoder().decode(FollowUp.self, from: old).suggestedTitle)
    }
}
