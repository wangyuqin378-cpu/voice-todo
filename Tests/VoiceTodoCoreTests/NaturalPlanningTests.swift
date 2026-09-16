import XCTest
@testable import VoiceTodoCore

final class NaturalPlanningTests: XCTestCase {
    let now = Dates.parse("2026-09-15T10:00:00+08:00")!
    func run(_ text: String, hour: Int = 9, state: Workspace = .init()) throws -> Workspace {
        XCTAssertTrue(CommandText.accepts(text), text)
        let proposal = try XCTUnwrap(LocalInterpreter.interpret(text, workspace: state, question: nil,
            now: now, timeZone: "Asia/Shanghai", defaultReminderHour: hour), text)
        return try TaskReducer.apply(proposal, to: state, inputID: text, input: text, now: now).workspace
    }
    func testNaturalTaskRequestsKeepDateWithoutRequiringReminder() throws {
        for text in ["帮我安排，我明天有个面试就好了", "帮我安排一下明天面试", "帮我记一下，我明天有个面试", "记一下明天的面试", "记录一下明天面试", "我明天有个面试", "明天面试", "安排明天面试不用提醒", "记住明天面试", "请帮我安排，明天面试"] {
            let result = try run(text)
            XCTAssertEqual(result.tasks.count, 1, text)
            XCTAssertEqual(result.tasks[0].title, "面试", text)
            XCTAssertEqual(result.tasks[0].plannedAt, Dates.parse("2026-09-16T00:00:00+08:00"), text)
            XCTAssertFalse(result.tasks[0].plannedHasTime ?? true, text)
            XCTAssertNil(result.tasks[0].reminderAt, text)
            XCTAssertFalse(result.tasks[0].needsReminder, text)
            XCTAssertTrue(result.questions.isEmpty, text)
        }
    }
    func testAppointmentTimeIsNotAnAlarm() throws {
        for text in ["帮我安排明天下午三点面试", "明天下午三点面试", "记录明天下午三点半面试"] {
            let result = try run(text)
            XCTAssertEqual(result.tasks[0].title, "面试")
            XCTAssertNotNil(result.tasks[0].plannedAt)
            XCTAssertEqual(result.tasks[0].plannedHasTime, true)
            XCTAssertNil(result.tasks[0].reminderAt)
            XCTAssertTrue(result.questions.isEmpty)
        }
    }
    func testUnscheduledTasksDoNotAskForReminders() throws {
        for text in ["记得报销", "记一下买牛奶", "帮我记下取快递", "创建待办整理桌面", "安排写方案"] {
            let result = try run(text)
            XCTAssertEqual(result.tasks.count, 1)
            XCTAssertNil(result.tasks[0].reminderAt)
            XCTAssertFalse(result.tasks[0].needsReminder)
            XCTAssertTrue(result.questions.isEmpty)
        }
    }
    func testExplicitDateOnlyReminderUsesVisiblePreference() throws {
        for text in ["明天提醒我面试", "提醒我明天面试", "帮我提醒一下，明天面试"] {
            XCTAssertEqual(try run(text).tasks[0].reminderAt, Dates.parse("2026-09-16T09:00:00+08:00"))
            XCTAssertEqual(try run(text, hour: 10).tasks[0].reminderAt, Dates.parse("2026-09-16T10:00:00+08:00"))
            XCTAssertEqual(try run(text, hour: -1).questions.first?.kind, .reminder)
        }
        XCTAssertEqual(try run("今天提醒我面试").questions.first?.kind, .reminder)
        XCTAssertEqual(try run("提醒我报销").questions.first?.kind, .reminder)
    }
    func testNonTasksStayOutsideCapture() {
        for text in ["今天天气真好", "天气好了", "跟朋友说材料已经交了", "他说材料已经交了", "明天会下雨", "清单功能很好", "帮我转录一下这段话", "请翻译明天面试这句话", "我明天不用面试", "我明天有个面试吗？", "如果材料已经交了", "面试还没完成", "材料差一点交完"] {
            XCTAssertFalse(CommandText.accepts(text), text)
        }
    }
    func testMixedIntentIsAcceptedWithoutAnAppName() {
        XCTAssertTrue(CommandText.accepts("报销好了，明天提醒我买牛奶"))
        XCTAssertTrue(CommandText.accepts("材料交了，帮我安排明天面试"))
        XCTAssertNil(LocalInterpreter.interpret("帮我安排一下这个软件如何显示", workspace: .init(), question: nil, now: now, timeZone: "Asia/Shanghai"))
    }
    func testNoopDoesNotDisplayEvenWithAnUnrelatedPendingQuestion() throws {
        var state = Workspace()
        state.questions.append(.init(kind: .reminder, question: "何时提醒", taskIDs: [], originalInput: "提醒我报销"))
        let proposal = Proposal(actions: [.init(kind: .noop, question: "普通聊天")])
        let result = try TaskReducer.apply(proposal, to: state, inputID: "chat", input: "天气好了", now: now)
        XCTAssertFalse(ExternalFeedback.shouldShow(result, previous: state, proposal: proposal))
    }
    func testPlannedFieldsSurviveStorageAndLegacyPayloadsDecode() throws {
        let result = try run("帮我安排，我明天有个面试就好了")
        XCTAssertEqual(try JSONDecoder().decode(Workspace.self, from: JSONEncoder().encode(result)), result)
        var old = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(result.tasks[0])) as? [String: Any])
        old.removeValue(forKey: "plannedAt"); old.removeValue(forKey: "plannedHasTime")
        let restored = try JSONDecoder().decode(TodoItem.self, from: JSONSerialization.data(withJSONObject: old))
        XCTAssertNil(restored.plannedAt)
        XCTAssertNil(restored.plannedHasTime)
        XCTAssertThrowsError(try TaskReducer.apply(.init(actions: [.init(kind: .create, title: "面试", plannedISO: "tomorrow")]), to: .init(), inputID: "bad", input: "明天面试", now: now))
    }
}
