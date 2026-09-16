import XCTest
@testable import VoiceTodoCore

final class AddOnlyAndDateTests: XCTestCase {
    let now = Dates.parse("2026-09-17T01:26:08+08:00")!
    let zone = "Asia/Shanghai"
    func apply(_ actions: [ProposedAction], tasks: [TodoItem], input: String, question: FollowUp? = nil) throws -> Workspace {
        var state = Workspace(tasks: tasks); state.questions = question.map { [$0] } ?? []
        return try TaskReducer.apply(.init(actions: actions), to: state, inputID: UUID().uuidString,
            input: input, answering: question?.id, now: now, inputDate: now, timeZone: zone).workspace
    }
    func testActualMidnightUtterancesAlwaysCreateAndPreserveExistingInterview() throws {
        let old = TodoItem(id: "old", title: "面试", plannedAt: Dates.parse("2026-09-18T00:00:00+08:00"), plannedHasTime: false)
        for (input, expected) in [("提醒我一下明天面试。", "2026-09-18T09:00:00+08:00"),
                                   ("提醒我一下后天面试", "2026-09-19T09:00:00+08:00"),
                                   ("帮我提醒一下明天面试", "2026-09-18T09:00:00+08:00"),
                                   ("提醒我明天下午六点面试", "2026-09-18T17:50:00+08:00")] {
            let p = try XCTUnwrap(LocalInterpreter.interpret(input, workspace: .init(tasks: [old]), question: nil, now: now, timeZone: zone), input)
            XCTAssertEqual(p.actions.map(\.kind), [.create], input)
            let state = try apply(p.actions, tasks: [old], input: input)
            XCTAssertEqual(state.tasks.count, 2)
            XCTAssertEqual(state.tasks[0], old)
            XCTAssertEqual(state.tasks[1].title, "面试")
            XCTAssertEqual(state.tasks[1].reminderAt, Dates.parse(expected), input)
        }
    }
    func testUTCDateCannotOverrideLocalTomorrowEvenWithPartialEvidence() {
        for evidence in [nil, "面试", "提醒我一下明天面试"] as [String?] {
            let bad = ProposedAction(kind: .create, title: "面试", reminderISO: "2026-09-17T09:00:00+08:00", evidence: evidence)
            XCTAssertThrowsError(try apply([bad], tasks: [], input: "提醒我一下明天面试"))
        }
    }
    func testTimezoneAtMidnightMonthAndYearBoundaries() throws {
        for (instant, zone, expected) in [
            ("2026-09-17T00:01:00+08:00", "Asia/Shanghai", "2026-09-18T09:00:00+08:00"),
            ("2026-09-16T23:59:00+08:00", "Asia/Shanghai", "2026-09-17T09:00:00+08:00"),
            ("2026-12-31T23:59:00+08:00", "Asia/Shanghai", "2027-01-01T09:00:00+08:00"),
            ("2026-09-17T01:26:00Z", "America/Los_Angeles", "2026-09-17T09:00:00-07:00")
        ] {
            let instant = Dates.parse(instant)!
            let p = try XCTUnwrap(LocalInterpreter.interpret("提醒我一下明天面试", workspace: .init(), question: nil, now: instant, timeZone: zone))
            XCTAssertEqual(p.actions.first?.reminderISO.flatMap(Dates.parse), Dates.parse(expected))
            XCTAssertNoThrow(try TaskReducer.apply(p, to: .init(), inputID: UUID().uuidString, input: "提醒我一下明天面试", now: instant, timeZone: zone))
        }
        XCTAssertEqual(Dates.iso(now, timeZone: zone), "2026-09-17T01:26:08+08:00")
    }
    func testEventAndReminderMayUseDifferentExplicitDays() throws {
        let p = ProposedAction(kind: .create, title: "面试", reminderISO: "2026-09-18T15:00:00+08:00",
            evidence: "后天上午十点面试", plannedISO: "2026-09-19T10:00:00+08:00", plannedHasTime: true)
        let result = try apply([p], tasks: [], input: "记一下，后天上午十点面试，明天下午三点提醒我")
        XCTAssertEqual(result.tasks[0].plannedAt, Dates.parse("2026-09-19T10:00:00+08:00"))
        XCTAssertEqual(result.tasks[0].reminderAt, Dates.parse("2026-09-18T15:00:00+08:00"))
    }
    func testCorrectedDateAndSeparateNewTasksUseTheirOwnDays() throws {
        XCTAssertNoThrow(try apply([.init(kind: .create, title: "面试", noReminder: true,
            plannedISO: "2026-09-18T00:00:00+08:00", plannedHasTime: false)], tasks: [], input: "安排后天面试，不对，是明天，不用提醒"))
        let result = try apply([
            .init(kind: .create, title: "面试", reminderISO: "2026-09-18T09:00:00+08:00", evidence: "面试"),
            .init(kind: .create, title: "买牛奶", reminderISO: "2026-09-19T09:00:00+08:00", evidence: "后天提醒我买牛奶")
        ], tasks: [], input: "明天提醒我面试，后天提醒我买牛奶")
        XCTAssertEqual(result.tasks.count, 2)
    }
    func testAIStandaloneReminderUpdateCannotTouchExistingTask() {
        let old = TodoItem(id: "old", title: "面试", plannedAt: Dates.parse("2026-09-18T00:00:00+08:00"))
        for date in ["2026-09-17T09:00:00+08:00", "2026-09-18T09:00:00+08:00"] {
            XCTAssertThrowsError(try apply([.init(kind: .setReminder, taskID: old.id, reminderISO: date)], tasks: [old], input: "提醒我一下明天面试"))
        }
    }
    func testUnrelatedReminderQuestionCannotConvertNewRequestIntoUpdate() throws {
        let old = TodoItem(id: "old", title: "面试", needsReminder: true)
        let q = FollowUp(kind: .reminder, question: "什么时候？", taskIDs: [old.id], originalInput: "提醒我面试")
        XCTAssertThrowsError(try apply([.init(kind: .setReminder, taskID: old.id, reminderISO: "2026-09-18T09:00:00+08:00", resolvesQuestionID: q.id)], tasks: [old], input: "提醒我一下明天面试", question: q))
        let p = try XCTUnwrap(LocalInterpreter.interpret("提醒我一下明天面试", workspace: .init(tasks: [old]), question: q, now: now, timeZone: zone))
        let result = try apply(p.actions, tasks: [old], input: "提醒我一下明天面试", question: q)
        XCTAssertEqual(result.tasks.count, 2); XCTAssertEqual(result.tasks[0], old)
        XCTAssertEqual(result.questions, [q])
    }
    func testExplicitEditsGiveManualGuidanceWithoutCallingAI() throws {
        for input in ["把面试改到后天", "帮我修改面试时间", "取消面试的提醒"] {
            let p = try XCTUnwrap(LocalInterpreter.interpret(input, workspace: .init(), question: nil, now: now, timeZone: zone))
            XCTAssertEqual(p.actions.first?.kind, .noop)
            XCTAssertTrue(p.actions.first?.question?.contains("清单") == true)
        }
    }
    func testPartialAndDifferentObjectsCannotBeCompletedByAI() {
        for (name, input, evidence) in [("面试准备", "面试完成了", "面试完成了"),
                                        ("交签证材料", "材料交好了", "材料交好了"),
                                        ("交材料", "签证材料交好了", "材料交好了"),
                                        ("买牛奶", "买到了", "买到了")] {
            XCTAssertThrowsError(try apply([.init(kind: .complete, taskID: "t", candidates: ["t"], evidence: evidence)], tasks: [.init(id: "t", title: name)], input: input), name)
        }
    }
    func testSameTitlesNeedAnExplicitDateOrSelection() throws {
        let a = TodoItem(id: "a", title: "面试", plannedAt: Dates.parse("2026-09-17T00:00:00+08:00"))
        let b = TodoItem(id: "b", title: "面试", plannedAt: Dates.parse("2026-09-18T00:00:00+08:00"))
        XCTAssertThrowsError(try apply([.init(kind: .complete, taskID: "a", candidates: ["a"], evidence: "面试完成了")], tasks: [a,b], input: "面试完成了"))
        let result = try apply([.init(kind: .complete, taskID: "a", candidates: ["a"], evidence: "9月17号的面试完成了")], tasks: [a,b], input: "9月17号的面试完成了")
        XCTAssertTrue(result.tasks[0].isCompleted); XCTAssertEqual(result.tasks[1], b)
    }
    func testEquivalentWordOrderKeepsFullObject() throws {
        for (name,input) in [("交签证材料", "签证材料已经交了"), ("面试", "我把面试做完了"), ("买牛奶", "牛奶买好了")] {
            let result = try apply([.init(kind: .complete, taskID: "t", candidates: ["t"], evidence: input)], tasks: [.init(id: "t", title: name)], input: input)
            XCTAssertTrue(result.tasks[0].isCompleted, input)
        }
    }
    func testModelCannotUseQuestionToBypassSelectionAgreement() {
        let tasks = [TodoItem(id: "a", title: "交项目材料"), TodoItem(id: "b", title: "交签证材料")]
        let q = FollowUp(kind: .chooseTask, question: "哪条？", taskIDs: ["a","b"], originalInput: "材料交了", intent: .complete)
        XCTAssertThrowsError(try apply([.init(kind: .complete, taskID: "b", resolvesQuestionID: q.id)], tasks: tasks, input: "第一条", question: q))
        XCTAssertThrowsError(try apply([.init(kind: .complete, taskID: "b", resolvesQuestionID: q.id)], tasks: tasks, input: "签证那份", question: q))
        XCTAssertNoThrow(try apply([.init(kind: .complete, taskID: "b", resolvesQuestionID: q.id)], tasks: tasks, input: "第二条", question: q))
    }
    func testPartialMatchAsksLocallyAndOnlyExplicitSelectionCompletes() throws {
        let task = TodoItem(id: "visa", title: "交签证材料")
        let state = Workspace(tasks: [task])
        let p = try XCTUnwrap(LocalInterpreter.interpret("材料交好了", workspace: state, question: nil, now: now, timeZone: zone))
        let asking = try apply(p.actions, tasks: [task], input: "材料交好了")
        XCTAssertEqual(asking.tasks, [task])
        let q = try XCTUnwrap(asking.questions.first)
        let selected = try XCTUnwrap(LocalInterpreter.interpret("第一条", workspace: asking, question: q, now: now, timeZone: zone))
        let done = try apply(selected.actions, tasks: [task], input: "第一条", question: q)
        XCTAssertTrue(done.tasks[0].isCompleted)
    }
    func testPartialMatchCannotBeReportedAsANewCompletedRecord() {
        XCTAssertThrowsError(try apply([.init(kind: .logCompleted, title: "交材料", candidates: [], evidence: "材料交好了")], tasks: [.init(title: "交签证材料")], input: "材料交好了"))
    }
}
