import XCTest
@testable import VoiceTodoCore

final class ReminderLeadTests: XCTestCase {
    let now = Dates.parse("2026-09-17T10:00:00+08:00")!
    let zone = "Asia/Shanghai"
    func run(_ input: String, lead: Int = 10, hour: Int = 9, at: Date? = nil) throws -> Workspace {
        XCTAssertTrue(CommandText.accepts(input), input)
        let at = at ?? now
        let p = try XCTUnwrap(LocalInterpreter.interpret(input, workspace: .init(), question: nil,
            now: at, timeZone: zone, defaultReminderHour: hour, defaultReminderLeadMinutes: lead), input)
        return try TaskReducer.apply(p, to: .init(), inputID: input, input: input, now: at, timeZone: zone).workspace
    }
    func testReportedSuffixRequestUsesNamedDateAndDefaultHour() throws {
        for input in ["我 10 月 1 号要买车票，提醒我一下", "我十月一号要买车票，提醒我一下。", "10月1日买车票提醒我", "我10月1号要买车票。帮我提醒一下"] {
            let task = try XCTUnwrap(run(input).tasks.first)
            XCTAssertEqual(task.title, "买车票", input)
            XCTAssertEqual(task.plannedAt, Dates.parse("2026-10-01T00:00:00+08:00"))
            XCTAssertEqual(task.plannedHasTime, false)
            XCTAssertEqual(task.reminderAt, Dates.parse("2026-10-01T09:00:00+08:00"))
        }
        XCTAssertEqual(try run("10月1号买车票，提醒我一下", hour: 10).tasks[0].reminderAt, Dates.parse("2026-10-01T10:00:00+08:00"))
        XCTAssertEqual(try run("10月1号买车票，提醒我一下", hour: -1).questions.first?.kind, .reminder)
    }
    func testEventTimeAndConfiguredLeadAreIndependent() throws {
        for input in ["我下午一点面试，提醒我一下", "提醒我今天下午一点面试", "今天下午一点提醒我面试", "我10月1号下午一点要面试，提醒我一下"] {
            for lead in [0, 5, 10, 15, 30, 60] {
                let task = try XCTUnwrap(run(input, lead: lead).tasks.first)
                let date = input.contains("10月") ? "2026-10-01" : "2026-09-17"
                let event = Dates.parse(date + "T13:00:00+08:00")!
                XCTAssertEqual(task.title, "面试")
                XCTAssertEqual(task.plannedAt, event)
                XCTAssertEqual(task.plannedHasTime, true)
                XCTAssertEqual(task.reminderAt, event.addingTimeInterval(-Double(lead * 60)), input)
            }
        }
    }
    func testExplicitLeadAndAtTimeOverridePreference() throws {
        for (suffix, minutes) in [("提前半小时提醒我",30), ("提前 30 分钟提醒我",30), ("提前十五分钟提醒我一下",15), ("提前1小时提醒我",60), ("到时提醒我",0)] {
            let task = try XCTUnwrap(run("明天下午一点面试，" + suffix).tasks.first)
            XCTAssertEqual(task.plannedAt?.timeIntervalSince(task.reminderAt!), Double(minutes * 60))
        }
    }
    func testRelativeDelayIsNotShortened() throws {
        for (input, seconds) in [("十分钟后提醒我取快递",600), ("半小时后提醒我取快递",1800)] {
            let task = try XCTUnwrap(run(input).tasks.first)
            XCTAssertEqual(task.reminderAt, now.addingTimeInterval(Double(seconds)))
        }
    }
    func testAlreadyInsideLeadWindowSchedulesNowWithoutLosingEvent() throws {
        let at = Dates.parse("2026-09-17T12:55:00+08:00")!
        let task = try XCTUnwrap(run("下午一点面试，提醒我一下", at: at).tasks.first)
        XCTAssertEqual(task.plannedAt, Dates.parse("2026-09-17T13:00:00+08:00"))
        XCTAssertEqual(task.reminderAt, at.addingTimeInterval(1))
    }
    func testImmediateLeadIsRebasedAfterProcessingLatency() throws {
        let start = Dates.parse("2026-09-17T12:55:00+08:00")!
        let input = "下午一点面试，提醒我一下"
        let p = try XCTUnwrap(LocalInterpreter.interpret(input, workspace: .init(), question: nil, now: start, timeZone: zone))
        let later = start.addingTimeInterval(5)
        let finalized = ReminderTiming.apply(to: p, input: input, now: later, leadMinutes: 10)
        let state = try TaskReducer.apply(finalized, to: .init(), inputID: "latency", input: input, now: later, inputDate: start, timeZone: zone).workspace
        XCTAssertEqual(state.tasks[0].reminderAt, later.addingTimeInterval(1))
    }
    func testLeadCanCrossMidnightWithoutChangingEventDay() throws {
        let task = try XCTUnwrap(run("明天凌晨0点5分面试，提醒我一下").tasks.first)
        XCTAssertEqual(task.plannedAt, Dates.parse("2026-09-18T00:05:00+08:00"))
        XCTAssertEqual(task.reminderAt, Dates.parse("2026-09-17T23:55:00+08:00"))
    }
    func testNoReminderAndNegatedOrQuotedSpeechAreNotConverted() throws {
        let task = try XCTUnwrap(run("记录10月1号下午一点面试，不用提醒").tasks.first)
        XCTAssertNil(task.reminderAt)
        XCTAssertEqual(task.plannedAt, Dates.parse("2026-10-01T13:00:00+08:00"))
        for input in ["他说我10月1号买车票，提醒我一下", "如果我10月1号买车票，提醒我一下", "我10月1号不买车票，不要提醒我"] {
            XCTAssertNil(LocalInterpreter.interpret(input, workspace: .init(), question: nil, now: now, timeZone: zone))
        }
    }
    func testNamedDateValidationAndRollover() throws {
        XCTAssertEqual(try run("我1月1号买车票，提醒我一下").tasks[0].plannedAt, Dates.parse("2027-01-01T00:00:00+08:00"))
        XCTAssertNil(NaturalTaskIntent.day("2月30号", now: now, timeZone: zone))
        let p = Proposal(actions: [.init(kind: .create, title: "买车票", reminderISO: "2026-09-18T09:00:00+08:00")])
        XCTAssertThrowsError(try TaskReducer.apply(p, to: .init(), inputID: "bad", input: "10月1号买车票，提醒我一下", now: now, timeZone: zone))
    }
    func testAIEventUsesSameLeadAndDoesNotSubtractTwice() throws {
        let p = Proposal(actions: [.init(kind: .create, title: "面试", reminderISO: "2026-09-18T13:00:00+08:00", plannedISO: "2026-09-18T13:00:00+08:00", plannedHasTime: true)])
        let adjusted = ReminderTiming.apply(to: p, input: "明天下午一点面试，提醒我一下", now: now, leadMinutes: 10)
        XCTAssertEqual(adjusted.actions[0].reminderISO.flatMap(Dates.parse), Dates.parse("2026-09-18T12:50:00+08:00"))
        XCTAssertEqual(ReminderTiming.apply(to: adjusted, input: "明天下午一点面试，提醒我一下", now: now, leadMinutes: 10).actions, adjusted.actions)
    }
    func testReminderClauseCannotBecomeAnExtraTask() {
        let p = Proposal(actions: [.init(kind: .create, title: "面试", noReminder: true),
                                   .init(kind: .create, title: "提醒我", noReminder: true)])
        XCTAssertThrowsError(try TaskReducer.apply(p, to: .init(), inputID: "split", input: "后天面试，明天提醒我", now: now, timeZone: zone))
    }
    func testExplicitSeparateReminderTimeIsPreserved() throws {
        let input = "后天下午一点面试，明天下午三点提醒我"
        let p = Proposal(actions: [.init(kind: .create, title: "面试", reminderISO: "2026-09-18T15:00:00+08:00", plannedISO: "2026-09-19T13:00:00+08:00", plannedHasTime: true)])
        let result = ReminderTiming.apply(to: p, input: input, now: now, leadMinutes: 10)
        XCTAssertEqual(result.actions, p.actions)
        let local = try run(input)
        XCTAssertEqual(local.tasks.count, 1)
        XCTAssertEqual(local.tasks[0].plannedAt, Dates.parse("2026-09-19T13:00:00+08:00"))
        XCTAssertEqual(local.tasks[0].reminderAt, Dates.parse("2026-09-18T15:00:00+08:00"))
        XCTAssertNoThrow(try TaskReducer.apply(result, to: .init(), inputID: "separate", input: input, now: now, timeZone: zone))
    }
}
