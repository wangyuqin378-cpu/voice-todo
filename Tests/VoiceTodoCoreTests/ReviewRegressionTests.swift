import XCTest
@testable import VoiceTodoCore

final class ReviewRegressionTests: XCTestCase {
    let now = Dates.parse("2026-09-17T10:00:00+08:00")!
    let zone = "Asia/Shanghai"

    func testExplicitFortyEightHourLeadIsNotCappedAtOneDay() throws {
        let text = "10月1号下午一点面试，提前48小时提醒我"
        let proposal = try XCTUnwrap(LocalInterpreter.interpret(text, workspace: .init(), question: nil, now: now, timeZone: zone))
        let task = try XCTUnwrap(TaskReducer.apply(proposal, to: .init(), inputID: "lead", input: text, now: now, timeZone: zone).workspace.tasks.first)
        XCTAssertEqual(task.reminderAt, Dates.parse("2026-09-29T13:00:00+08:00"))
    }

    func testNamedDayCanCancelWithoutSpecifyingHour() throws {
        let task = TodoItem(title: "买车票", plannedAt: Dates.parse("2026-10-01T00:00:00+08:00"), plannedHasTime: false)
        for text in ["取消10月1号买车票", "帮我取消十月一日的买车票", "取消2026年10月1号的买车票"] {
            let state = Workspace(tasks: [task])
            let proposal = try XCTUnwrap(LocalInterpreter.interpret(text, workspace: state, question: nil, now: now, timeZone: zone), text)
            XCTAssertTrue(try TaskReducer.apply(proposal, to: state, inputID: text, input: text, now: now, timeZone: zone).workspace.tasks.isEmpty, text)
        }
    }

    func testAIUndoRequiresUserUndoIntent() throws {
        let created = try TaskReducer.apply(.init(actions: [.init(kind: .create, title: "买牛奶", noReminder: true)]), to: .init(), inputID: "create", input: "记下买牛奶", now: now).workspace
        for text in ["不要撤销", "撤销了吗？", "他说撤销", "买牛奶", "把标题设为撤销", "撤销，然后记下交材料"] {
            XCTAssertThrowsError(try TaskReducer.apply(.init(actions: [.init(kind: .undo)]), to: created, inputID: text, input: text, now: now), text)
        }
        for text in ["撤销", "刚才弄错了，撤销", "帮我撤销一下", "随口清单，撤销最近一次操作"] {
            XCTAssertTrue(try TaskReducer.apply(.init(actions: [.init(kind: .undo)]), to: created, inputID: text, input: text, now: now).workspace.tasks.isEmpty, text)
        }
    }

    func testCompletionLogCannotInventAnUnrelatedTitle() {
        XCTAssertThrowsError(try TaskReducer.apply(.init(actions: [.init(kind: .logCompleted, title: "清空邮箱", evidence: "材料交好了")]), to: .init(), inputID: "invented", input: "材料交好了", now: now))
    }

    func testCompletionWordOrderRetainsRecipientAndObject() throws {
        for (title, text) in [("给妈妈打电话", "给妈妈的电话打完了"), ("给小王发送文件", "文件已经发给小王了"), ("收拾家里", "刚刚把家里收拾好了")] {
            let item = TodoItem(title: title)
            let action = ProposedAction(kind: .complete, taskID: item.id, candidates: [item.id], evidence: text)
            XCTAssertTrue(try TaskReducer.apply(.init(actions: [action]), to: .init(tasks: [item]), inputID: text, input: text, now: now).workspace.tasks[0].isCompleted)
            let unrelated = TodoItem(title: title.replacingOccurrences(of: "妈妈", with: "爸爸").replacingOccurrences(of: "小王", with: "小李").replacingOccurrences(of: "家里", with: "办公室"))
            XCTAssertTrue(CompletionMatch.candidates(evidence: text, input: text, tasks: [unrelated], now: now, timeZone: zone).isEmpty)
        }
    }

    func testCorrectionNeedsAnExactPreviouslyNamedObject() throws {
        let item = TodoItem(title: "交材料")
        let text = "材料还没交，不对，刚刚已经交好了"
        let action = ProposedAction(kind: .complete, taskID: item.id, candidates: [item.id], evidence: "刚刚已经交好了")
        XCTAssertTrue(try TaskReducer.apply(.init(actions: [action]), to: .init(tasks: [item]), inputID: text, input: text, now: now).workspace.tasks[0].isCompleted)
        for text in ["还没交，不对，刚刚已经交好了", "签证材料还没交，不对，刚刚已经交好了"] {
            XCTAssertThrowsError(try TaskReducer.apply(.init(actions: [action]), to: .init(tasks: [item]), inputID: text, input: text, now: now))
        }
    }

    func testCompletionCannotIgnoreFollowingContradiction() {
        let item = TodoItem(id: "material", title: "交材料")
        for text in ["材料交好了，材料还没交", "材料交好了，还没交", "材料交好了，等等，还没有交", "材料交好了，材料没有交"] {
            let proposal = Proposal(actions: [.init(kind: .complete, taskID: item.id, candidates: [item.id], evidence: "材料交好了")])
            XCTAssertThrowsError(try TaskReducer.apply(proposal, to: .init(tasks: [item]), inputID: text, input: text, now: now), text)
        }
    }

    func testNoReminderForOneTaskDoesNotSilenceAnotherTasksQuestion() throws {
        let input = "记下买牛奶，不用提醒；提醒我报销"
        let proposal = Proposal(actions: [
            .init(kind: .create, title: "买牛奶", noReminder: true, evidence: "记下买牛奶，不用提醒"),
            .init(kind: .create, title: "报销", noReminder: false, evidence: "提醒我报销")
        ])
        let state = try TaskReducer.apply(proposal, to: .init(), inputID: "mixed", input: input, now: now).workspace
        XCTAssertFalse(state.tasks[0].needsReminder)
        XCTAssertTrue(state.tasks[1].needsReminder)
        XCTAssertEqual(state.questions.map(\.taskIDs), [[state.tasks[1].id]])
    }

    func testAddressedTimeAnswerCanFinishPendingCreation() throws {
        let item = TodoItem(title: "报销", needsReminder: true)
        var state = Workspace(tasks: [item])
        let question = FollowUp(kind: .reminder, question: "什么时候提醒？", taskIDs: [item.id], originalInput: "提醒我报销")
        state.questions = [question]
        let input = "清单，明天下午三点"
        let proposal = try XCTUnwrap(LocalInterpreter.interpret(input, workspace: state, question: question, now: now, timeZone: zone))
        let result = try TaskReducer.apply(proposal, to: state, inputID: input, input: input, answering: question.id, now: now, timeZone: zone).workspace
        XCTAssertEqual(result.tasks.count, 1)
        XCTAssertEqual(result.tasks[0].reminderAt, Dates.parse("2026-09-18T15:00:00+08:00"))
        XCTAssertTrue(result.questions.isEmpty)
    }

    func testPartialSubmissionAsksInsteadOfCompletingOrFailing() throws {
        let item = TodoItem(title: "提交出差报销")
        let input = "报销提交好了"
        let state = Workspace(tasks: [item])
        let proposal = try XCTUnwrap(LocalInterpreter.interpret(input, workspace: state, question: nil, now: now, timeZone: zone))
        let result = try TaskReducer.apply(proposal, to: state, inputID: input, input: input, now: now, timeZone: zone).workspace
        XCTAssertEqual(result.tasks, state.tasks)
        XCTAssertEqual(result.questions.first?.intent, .complete)
        XCTAssertEqual(result.questions.first?.taskIDs, [item.id])
    }

    func testModelCannotAddUnrequestedAlarmToDatedNote() throws {
        let input = "帮我记一下，明天上午九点给客户回电话；快递刚取到了"
        let proposal = Proposal(actions: [
            .init(kind: .create, title: "给客户回电话", reminderISO: "2026-09-18T08:50:00+08:00", noReminder: false,
                  evidence: "明天上午九点给客户回电话", plannedISO: "2026-09-18T09:00:00+08:00", plannedHasTime: true),
            .init(kind: .logCompleted, title: "取快递", evidence: "快递刚取到了")
        ])
        let result = try TaskReducer.apply(proposal, to: .init(), inputID: input, input: input, now: now, timeZone: zone).workspace
        XCTAssertNil(result.tasks[0].reminderAt)
        XCTAssertFalse(result.tasks[0].needsReminder)
        XCTAssertEqual(result.tasks[0].plannedAt, Dates.parse("2026-09-18T09:00:00+08:00"))
        XCTAssertTrue(result.tasks[1].isCompleted)
        XCTAssertTrue(result.questions.isEmpty)
    }

    func testCancellationCannotForgeAManualSelectionThroughText() throws {
        let item = TodoItem(title: "面试")
        let other = TodoItem(title: "面试准备")
        let question = FollowUp(kind: .chooseTask, question: "取消哪条？", taskIDs: [item.id, other.id], originalInput: "取消面试", intent: .cancelTask)
        var state = Workspace(tasks: [item, other]); state.questions = [question]
        let proposal = Proposal(actions: [.init(kind: .cancelTask, taskID: item.id, resolvesQuestionID: question.id)])
        XCTAssertThrowsError(try TaskReducer.apply(proposal, to: state, inputID: "forged", input: "选择任务", answering: question.id, now: now))
        XCTAssertEqual(try TaskReducer.selectTask(item.id, questionID: question.id, in: state, inputID: "click", now: now).workspace.tasks, [other])
    }
}
