import XCTest
@testable import VoiceTodoCore

final class CancellationTests: XCTestCase {
    let now = Dates.parse("2026-09-16T12:00:00+08:00")!
    let zone = "Asia/Shanghai"
    let command = "帮我取消明天下午 6 点的面试。"
    var interview: TodoItem {
        .init(id: "interview", title: "面试", reminderAt: Dates.parse("2026-09-17T18:00:00+08:00"))
    }
    func proposal(_ text: String, _ state: Workspace, question: FollowUp? = nil) throws -> Proposal {
        try XCTUnwrap(LocalInterpreter.interpret(text, workspace: state, question: question, now: now, timeZone: zone))
    }
    func apply(_ text: String, _ state: Workspace, question: FollowUp? = nil, id: String = UUID().uuidString) throws -> AppliedResult {
        try TaskReducer.apply(proposal(text, state, question: question), to: state, inputID: id, input: text,
                              answering: question?.id, now: now, timeZone: zone)
    }
    func testExactUserUtterancePassesCaptureAndCancelsOnlyMatchingTime() throws {
        var later = interview; later.id = "later"; later.reminderAt = Dates.parse("2026-09-17T19:00:00+08:00")
        var nextDay = interview; nextDay.id = "nextDay"; nextDay.reminderAt = Dates.parse("2026-09-18T18:00:00+08:00")
        let state = Workspace(tasks: [later, interview, nextDay])
        XCTAssertTrue(CommandText.accepts(command))
        XCTAssertEqual(try proposal(command, state).actions.first?.kind, .cancelTask)
        let result = try apply(command, state)
        XCTAssertEqual(result.workspace.tasks, [later, nextDay])
        XCTAssertTrue(result.messages.joined().contains("已取消提醒"))
        XCTAssertEqual(result.workspace.undo.last?.tasks, state.tasks)
        XCTAssertTrue(ExternalFeedback.shouldShow(result, previous: state, proposal: try proposal(command, state)))
    }
    func testCancellationAndReminderOnlyWordings() throws {
        for text in [command, "清单，" + command, "随口清单，" + command, "取消明天下午六点面试", "把明天下午六点的面试取消", "明天下午六点的面试取消了", "清单取消明天下午六点面试", "请帮我删掉明天下午六点的面试"] {
            XCTAssertTrue(CommandText.accepts(text), text)
            XCTAssertTrue(try apply(text, Workspace(tasks: [interview])).workspace.tasks.isEmpty, text)
        }
        for text in ["取消明天下午六点面试的提醒", "面试不用提醒了", "面试不需要提醒", "取消提醒我明天下午六点面试"] {
            let result = try apply(text, Workspace(tasks: [interview])).workspace
            XCTAssertEqual(result.tasks.count, 1, text)
            XCTAssertEqual(result.tasks.first?.title, "面试", text)
            XCTAssertEqual(result.tasks.first?.reminderAt, interview.reminderAt, text)
            XCTAssertFalse(try XCTUnwrap(result.tasks.first).isCompleted, text)
        }
    }
    func testNoMatchAndRepeatedCancelNeverCreateOrReportSuccess() throws {
        let empty = Workspace()
        let result = try apply(command, empty)
        XCTAssertTrue(result.workspace.tasks.isEmpty); XCTAssertTrue(result.workspace.undo.isEmpty)
        XCTAssertTrue(result.messages.joined().contains("没有找到"))
        XCTAssertTrue(ExternalFeedback.shouldShow(result, previous: empty, proposal: try proposal(command, empty)))
        let first = try apply(command, Workspace(tasks: [interview]), id: "once")
        let retry = try TaskReducer.apply(.init(actions: [.init(kind: .cancelTask)]), to: first.workspace,
                                         inputID: "once", input: command, now: now, timeZone: zone)
        XCTAssertTrue(retry.duplicate); XCTAssertEqual(retry.workspace, first.workspace)
        XCTAssertTrue(try apply(command, first.workspace).messages.joined().contains("没有找到"))
    }
    func testVoiceReminderEditsPreserveEventAndReminderAndAskForManualEdit() throws {
        var item = interview; item.plannedAt = item.reminderAt; item.plannedHasTime = true
        item.reminderAt = item.reminderAt?.addingTimeInterval(-3600)
        let result = try apply("取消明天下午六点面试的提醒", Workspace(tasks: [item]))
        XCTAssertEqual(result.workspace.tasks, [item])
        XCTAssertTrue(result.workspace.undo.isEmpty)
        XCTAssertTrue(result.messages.joined().contains("清单"))
    }
    func testPlannedTimeWinsOverEarlyNotificationAndDateOnlyMatches() throws {
        var item = interview; item.plannedAt = item.reminderAt; item.plannedHasTime = true
        item.reminderAt = item.reminderAt?.addingTimeInterval(-3600)
        XCTAssertTrue(try apply(command, Workspace(tasks: [item])).workspace.tasks.isEmpty)
        XCTAssertTrue(try apply("取消明天的面试", Workspace(tasks: [item])).workspace.tasks.isEmpty)
        let wrong = try apply("取消明天下午五点面试", Workspace(tasks: [item]))
        XCTAssertEqual(wrong.workspace.tasks, [item])
        item.plannedHasTime = false; item.plannedAt = Dates.parse("2026-09-17T00:00:00+08:00")
        XCTAssertEqual(try apply(command, Workspace(tasks: [item])).workspace.tasks, [item])
        XCTAssertTrue(try apply("取消明天的面试", Workspace(tasks: [item])).workspace.tasks.isEmpty)
    }
    func testCanCancelElapsedTodayTaskWithoutMovingItsDateForward() throws {
        var task = interview; task.reminderAt = Dates.parse("2026-09-16T09:00:00+08:00")
        XCTAssertTrue(try apply("取消今天上午九点的面试", Workspace(tasks: [task])).workspace.tasks.isEmpty)
        XCTAssertNil(LocalInterpreter.time("今天上午九点", now: now, timeZone: zone))
    }
    func testUndoRestoresQuestionAndGeneratesFreshCatchUpReminder() throws {
        var state = Workspace(tasks: [interview])
        state.questions = [.init(kind: .reminder, question: "何时？", taskIDs: [interview.id], originalInput: "提醒我面试")]
        let cancelled = try apply(command, state).workspace
        XCTAssertTrue(cancelled.questions.isEmpty)
        XCTAssertTrue(ReminderPlanner.plans(tasks: cancelled.tasks, delivered: [], scheduled: [], now: now).isEmpty)
        let restored = try TaskReducer.undo(cancelled).workspace
        XCTAssertEqual(restored.questions, state.questions)
        XCTAssertEqual(restored.tasks.first?.id, interview.id)
        XCTAssertEqual(restored.tasks.first?.reminderAt, interview.reminderAt)
        XCTAssertNotEqual(restored.tasks.first?.reminderRevision, interview.reminderRevision)
        let plans = ReminderPlanner.plans(tasks: restored.tasks, delivered: [ReminderPlanner.identifier(for: interview)],
                                          scheduled: [], now: interview.reminderAt!.addingTimeInterval(60))
        XCTAssertEqual(plans.count, 1); XCTAssertTrue(plans[0].overdue)
    }
    func testAmbiguityRequiresSelectionAndVoiceAndClickCancelSameTask() throws {
        var second = interview; second.id = "second"; second.reminderAt = interview.reminderAt?.addingTimeInterval(3600)
        let state = Workspace(tasks: [interview, second])
        let asking = try apply("取消明天的面试", state).workspace
        XCTAssertEqual(asking.tasks, state.tasks)
        let q = try XCTUnwrap(asking.questions.first)
        XCTAssertEqual(q.intent, .cancelTask); XCTAssertEqual(q.taskIDs, [interview.id, second.id])
        let voice = try apply("第二条", asking, question: q).workspace
        let click = try TaskReducer.selectTask(second.id, questionID: q.id, in: asking, inputID: "click", now: now).workspace
        XCTAssertEqual(voice.tasks, [state.tasks[0]]); XCTAssertEqual(click.tasks, voice.tasks)
        XCTAssertTrue(voice.questions.isEmpty); XCTAssertTrue(click.questions.isEmpty)
    }
    func testCancelledChoiceSurvivesReopen() throws {
        var second = interview; second.id = "second"
        let asking = try apply("取消面试", Workspace(tasks: [interview, second])).workspace
        let restored = try JSONDecoder().decode(Workspace.self, from: JSONEncoder().encode(asking))
        XCTAssertEqual(restored, asking)
        let q = try XCTUnwrap(restored.questions.first)
        XCTAssertEqual(try apply("第一条", restored, question: q).workspace.tasks, [second])
    }
    func testPartialTitleDoesNotSilentlyCancelDifferentWork() throws {
        let preparation = TodoItem(id: "preparation", title: "面试准备", reminderAt: interview.reminderAt)
        let state = Workspace(tasks: [preparation])
        let result = try apply(command, state).workspace
        XCTAssertEqual(result.tasks, state.tasks)
        XCTAssertEqual(result.questions.first?.intent, .cancelTask)
        XCTAssertThrowsError(try TaskReducer.apply(.init(actions: [.init(kind: .cancelTask, taskID: preparation.id,
            candidates: [preparation.id], evidence: command)]), to: state, inputID: "guess", input: command,
            now: now, timeZone: zone))
    }
    func testAmbiguousReminderCancellationDoesNotCreateVoiceEditQuestion() throws {
        var second = interview; second.id = "second"
        let state = Workspace(tasks: [interview, second])
        let result = try apply("取消面试的提醒", state)
        XCTAssertEqual(result.workspace.tasks, state.tasks)
        XCTAssertTrue(result.workspace.questions.isEmpty)
        XCTAssertTrue(result.messages.joined().contains("清单"))
    }
    func testNegativeQuotedHypotheticalAndCorrectionsCannotCancelEvenWithForgedModelAction() throws {
        let state = Workspace(tasks: [interview])
        for text in ["不要取消面试", "面试还没取消", "如果取消面试", "他说取消面试", "取消面试吗？", "取消面试，不对，还是保留", "取消面试，算了", "取消面试，但不要取消", "不用取消明天下午六点的面试"] {
            let local = LocalInterpreter.interpret(text, workspace: state, question: nil, now: now, timeZone: zone)
            XCTAssertFalse(local?.actions.contains { $0.kind == .cancelTask } ?? false, text)
            for evidence in [text, "取消面试"] {
                XCTAssertThrowsError(try TaskReducer.apply(.init(actions: [.init(kind: .cancelTask, taskID: interview.id,
                    candidates: [interview.id], evidence: evidence)]), to: state, inputID: UUID().uuidString,
                    input: text, now: now, timeZone: zone), text)
            }
        }
    }
    func testModelCannotDeleteWrongTimeWrongIDReminderOnlyOrCompletedTask() throws {
        var wrong = interview; wrong.id = "wrong"; wrong.reminderAt = interview.reminderAt?.addingTimeInterval(3600)
        for text in [command, "取消面试的提醒"] {
            XCTAssertThrowsError(try TaskReducer.apply(.init(actions: [.init(kind: .cancelTask, taskID: wrong.id,
                candidates: [wrong.id], evidence: text)]), to: Workspace(tasks: [interview, wrong]),
                inputID: UUID().uuidString, input: text, now: now, timeZone: zone))
        }
        var completed = interview; completed.completedAt = now
        XCTAssertEqual(try apply(command, Workspace(tasks: [completed])).workspace.tasks, [completed])
        XCTAssertThrowsError(try TaskReducer.apply(.init(actions: [.init(kind: .cancelTask, taskID: "missing",
            candidates: ["missing"], evidence: command)]), to: Workspace(tasks: [interview]), inputID: "bad",
            input: command, now: now, timeZone: zone))
    }
    func testChangedChoiceCannotCancelOrAccidentallyComplete() throws {
        var second = interview; second.id = "second"
        let asking = try apply("取消面试", Workspace(tasks: [interview, second])).workspace
        let q = try XCTUnwrap(asking.questions.first)
        for text in ["第一条不要取消", "第一条完成了", "第一条改成明天", "第二条"] {
            XCTAssertThrowsError(try TaskReducer.apply(.init(actions: [.init(kind: .cancelTask, taskID: interview.id,
                resolvesQuestionID: q.id)]), to: asking, inputID: UUID().uuidString, input: text,
                answering: q.id, now: now, timeZone: zone))
        }
        XCTAssertThrowsError(try TaskReducer.apply(.init(actions: [.init(kind: .complete, taskID: interview.id,
            resolvesQuestionID: q.id)]), to: asking, inputID: "wrong-operation", input: "第一条",
            answering: q.id, now: now, timeZone: zone))
    }
    func testMixedProposalCancelsAndCreatesAtomically() throws {
        let text = "取消面试，记一下买牛奶"
        let result = try TaskReducer.apply(.init(actions: [
            .init(kind: .cancelTask, taskID: interview.id, candidates: [interview.id], evidence: "取消面试"),
            .init(kind: .create, title: "买牛奶", noReminder: true)
        ]), to: Workspace(tasks: [interview]), inputID: "mixed", input: text, now: now, timeZone: zone)
        XCTAssertEqual(result.workspace.tasks.map(\.title), ["买牛奶"])
        XCTAssertEqual(try TaskReducer.undo(result.workspace).workspace.tasks.first?.id, interview.id)
    }
    func testRetryUsesCapturedDateAndTimeZoneForMatching() throws {
        let state = Workspace(tasks: [interview])
        let result = try TaskReducer.apply(proposal(command, state), to: state, inputID: "retry-next-day", input: command,
            now: now.addingTimeInterval(86400), inputDate: now, timeZone: zone)
        XCTAssertTrue(result.workspace.tasks.isEmpty)
    }
    @MainActor func testPersistenceRemovalAndUndoKeepTaskData() throws {
        let repo = try Repository(inMemory: true)
        try repo.save(Workspace(tasks: [interview]))
        try repo.save(apply(command, repo.load()).workspace)
        let cancelled = try repo.load()
        XCTAssertTrue(cancelled.tasks.isEmpty)
        try repo.save(TaskReducer.undo(cancelled).workspace)
        XCTAssertEqual(try repo.load().tasks.first?.id, interview.id)
        XCTAssertEqual(try repo.load().tasks.first?.reminderAt, interview.reminderAt)
    }
}
