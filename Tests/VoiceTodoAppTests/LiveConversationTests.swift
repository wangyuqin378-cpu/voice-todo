import XCTest
import VoiceTodoCore
@testable import VoiceTodoApp

/// Opt-in live model acceptance with synthetic workspaces. Never opens the user's store.
@MainActor final class LiveConversationTests: XCTestCase {
    func testDiscussionVersusDefinitePlanWithRealModel() async throws {
        guard ProcessInfo.processInfo.environment["VOICETODO_LIVE_INTENT_QA"] == "1" else { throw XCTSkip("Explicit live intent QA only") }
        let defaults = try XCTUnwrap(UserDefaults(suiteName: "com.wyq.voicetodo"))
        let configuration = AppSettings(defaults: defaults).configuration
        let key = try AIKey.read(configuration: configuration, defaults: defaults)
        let client = AIClient(configuration: configuration)
        let now = Dates.parse("2026-09-17T10:00:00+08:00")!
        let workspace = Workspace(tasks: [.init(id: "existing", title: "预订酒店")])
        let cases: [(String, ProposedAction.Kind)] = [
            ("如果我想住两天水屋呢，再帮我安排一下", .noop),
            ("如果我想住两天水屋呢 ，再帮我安排一下 ，在仙本那住两天水屋", .noop),
            ("要是多玩两天，行程怎么安排", .noop),
            ("帮我规划一下明天的旅行路线", .noop),
            ("帮我安排，我明天有个面试就好了", .create),
            ("在海边住两晚这件事，帮我记一下", .create)
        ]
        for (input, kind) in cases {
            // Bypass the local filter deliberately to exercise the actual model.
            let proposal = try await AIRequestDeadline.run(seconds: 8) {
                try await client.interpret(input: input, workspace: workspace, question: nil,
                    key: key, now: now, timeZone: "Asia/Shanghai")
            }
            XCTAssertEqual(proposal.actions.map(\.kind), [kind], input)
            let result = try TaskReducer.apply(proposal, to: workspace, inputID: UUID().uuidString,
                input: input, now: now, timeZone: "Asia/Shanghai").workspace
            XCTAssertEqual(result.tasks.first, workspace.tasks.first)
            XCTAssertEqual(result.tasks.count, kind == .noop ? 1 : 2, input)
            XCTAssertTrue(result.questions.isEmpty, input)
        }
    }
    func testSuffixAndAdvanceReminderWithRealModel() async throws {
        guard ProcessInfo.processInfo.environment["VOICETODO_LIVE_QA"] == "1" else { throw XCTSkip("Explicit live QA only") }
        let defaults = try XCTUnwrap(UserDefaults(suiteName: "com.wyq.voicetodo"))
        let configuration = AppSettings(defaults: defaults).configuration
        let key = try AIKey.read(configuration: configuration, defaults: defaults)
        let client = AIClient(configuration: configuration)
        let now = Dates.parse("2026-09-17T10:00:00+08:00")!
        let old = TodoItem(id: "existing", title: "面试", plannedAt: Dates.parse("2026-09-18T13:00:00+08:00"))
        let workspace = Workspace(tasks: [old])
        let cases: [(String, Int, String, String, String)] = [
            ("我10月1号要买车票，提醒我一下", 10, "买车票", "2026-10-01T00:00:00+08:00", "2026-10-01T09:00:00+08:00"),
            ("我明天下午一点面试，提醒我一下", 10, "面试", "2026-09-18T13:00:00+08:00", "2026-09-18T12:50:00+08:00"),
            ("帮我记个面试，10月1号下午一点，提醒我一下", 30, "面试", "2026-10-01T13:00:00+08:00", "2026-10-01T12:30:00+08:00"),
            ("后天下午一点面试，明天下午三点提醒我", 10, "面试", "2026-09-19T13:00:00+08:00", "2026-09-18T15:00:00+08:00"),
            ("明天下午一点面试，提前半小时提醒我", 10, "面试", "2026-09-18T13:00:00+08:00", "2026-09-18T12:30:00+08:00")
        ]
        var rows: [[String: Any]] = []
        defer {
            if let path = ProcessInfo.processInfo.environment["VOICETODO_LIVE_QA_OUTPUT"],
               let data = try? JSONSerialization.data(withJSONObject: rows, options: [.prettyPrinted, .sortedKeys]) {
                try? data.write(to: URL(fileURLWithPath: path), options: .atomic)
            }
        }
        for (input, lead, title, planned, alarm) in cases {
            let start = Date.now
            let proposal = try await client.interpret(input: input, workspace: workspace, question: nil, key: key,
                now: now, timeZone: "Asia/Shanghai", defaultReminderLeadMinutes: lead)
            rows.append(["input": input, "leadMinutes": lead, "seconds": Date.now.timeIntervalSince(start),
                         "normalizedProposal": try JSONSerialization.jsonObject(with: JSONEncoder().encode(proposal))])
            let result = try TaskReducer.apply(proposal, to: workspace, inputID: UUID().uuidString, input: input, now: now, timeZone: "Asia/Shanghai").workspace
            XCTAssertEqual(result.tasks.count, 2, input)
            XCTAssertEqual(result.tasks.first, old)
            XCTAssertEqual(result.tasks.last?.title, title, input)
            XCTAssertEqual(result.tasks.last?.plannedAt, Dates.parse(planned), input)
            XCTAssertEqual(result.tasks.last?.reminderAt, Dates.parse(alarm), input)
        }
    }
    func testAddOnlyMidnightAndStrictCompletionWithRealModel() async throws {
        guard ProcessInfo.processInfo.environment["VOICETODO_LIVE_QA"] == "1" else { throw XCTSkip("Explicit live QA only") }
        let defaults = try XCTUnwrap(UserDefaults(suiteName: "com.wyq.voicetodo"))
        let configuration = AppSettings(defaults: defaults).configuration
        let key = try AIKey.read(configuration: configuration, defaults: defaults)
        let client = AIClient(configuration: configuration)
        let now = Dates.parse("2026-09-17T01:26:08+08:00")!
        let old = TodoItem(id: "existing-interview", title: "面试", createdAt: now.addingTimeInterval(-7200),
            plannedAt: Dates.parse("2026-09-18T00:00:00+08:00"), plannedHasTime: false)
        let material = TodoItem(id: "visa", title: "交签证材料", createdAt: now)
        let original = Workspace(tasks: [old, material])
        var rows: [[String: Any]] = []
        defer {
            if let path = ProcessInfo.processInfo.environment["VOICETODO_LIVE_QA_OUTPUT"],
               let data = try? JSONSerialization.data(withJSONObject: rows, options: [.prettyPrinted, .sortedKeys]) {
                try? data.write(to: URL(fileURLWithPath: path), options: .atomic)
            }
        }
        for (index, input) in ["提醒我一下明天面试。", "提醒我一下后天面试", "材料交好了", "签证材料已经交了", "把面试改到后天", "记一下，后天上午十点面试，明天下午三点提醒我"].enumerated() {
            let start = Date.now
            let proposal = try await client.interpret(input: input, workspace: original, question: nil, key: key, now: now, timeZone: "Asia/Shanghai")
            rows.append(["input": input, "seconds": Date.now.timeIntervalSince(start),
                         "proposal": try JSONSerialization.jsonObject(with: JSONEncoder().encode(proposal))])
            let result: Workspace
            do {
                result = try TaskReducer.apply(proposal, to: original, inputID: UUID().uuidString, input: input, now: now, timeZone: "Asia/Shanghai").workspace
            } catch {
                rows[rows.count - 1]["rejectedByApplication"] = String(describing: error)
                if index == 2 {
                    XCTAssertTrue(error.localizedDescription.contains("对应"))
                    continue // An unsafe model guess must be rejected, never applied.
                }
                throw error
            }
            XCTAssertEqual(result.tasks[0], old, input)
            if index < 2 {
                XCTAssertEqual(proposal.actions.map(\.kind), [.create], input)
                XCTAssertEqual(result.tasks.count, 3)
                XCTAssertEqual(result.tasks.last?.reminderAt, Dates.parse(index == 0 ? "2026-09-18T09:00:00+08:00" : "2026-09-19T09:00:00+08:00"))
            } else if index == 3 {
                XCTAssertTrue(result.tasks[1].isCompleted)
            } else if index == 5 {
                XCTAssertEqual(result.tasks.count, 3)
                XCTAssertEqual(result.tasks.last?.plannedAt, Dates.parse("2026-09-19T10:00:00+08:00"))
                XCTAssertEqual(result.tasks.last?.reminderAt, Dates.parse("2026-09-18T15:00:00+08:00"))
            } else {
                XCTAssertEqual(result.tasks, original.tasks, input)
            }
        }
    }

    func testNaturalPlanningAndQuietNoopsWithRealModel() async throws {
        guard ProcessInfo.processInfo.environment["VOICETODO_LIVE_QA"] == "1" else { throw XCTSkip("Explicit live QA only") }
        let defaults = try XCTUnwrap(UserDefaults(suiteName: "com.wyq.voicetodo"))
        let configuration = AppSettings(defaults: defaults).configuration
        let key = try AIKey.read(configuration: configuration, defaults: defaults)
        let client = AIClient(configuration: configuration)
        let now = Dates.parse("2026-09-15T10:00:00+08:00")!
        var rows: [[String: Any]] = []
        defer {
            if let path = ProcessInfo.processInfo.environment["VOICETODO_LIVE_QA_OUTPUT"],
               let data = try? JSONSerialization.data(withJSONObject: rows, options: [.prettyPrinted, .sortedKeys]) {
                try? data.write(to: URL(fileURLWithPath: path + ".natural.json"), options: .atomic)
            }
        }
        let texts = ["帮我安排，我明天有个面试就好了", "记一下，后天上午十点面试，明天下午三点提醒我",
                     "报销好了，明天提醒我买牛奶", "帮我安排后天面试，不对，是明天，不用提醒",
                     "帮我安排一下这个软件如何显示", "他说报销已经好了", "报销还没好，差一点做完"]
        for (index, input) in texts.enumerated() {
            let original = Workspace(tasks: [.init(title: "报销", createdAt: now)])
            let start = Date.now
            let proposal = try await client.interpret(input: input, workspace: original, question: nil, key: key, now: now, timeZone: "Asia/Shanghai")
            // Keep the synthetic input and proposed action even when safety validation rejects it.
            rows.append(["input": input, "seconds": Date.now.timeIntervalSince(start),
                         "proposal": try JSONSerialization.jsonObject(with: JSONEncoder().encode(proposal))])
            let result: AppliedResult
            do {
                result = try TaskReducer.apply(proposal, to: original, inputID: UUID().uuidString, input: input, now: now)
            } catch {
                rows[rows.count - 1]["rejectedByApplication"] = error.localizedDescription
                throw error
            }
            rows[rows.count - 1]["workspace"] = try JSONSerialization.jsonObject(with: JSONEncoder().encode(result.workspace))
            if index >= 4 {
                XCTAssertEqual(result.workspace.tasks, original.tasks, input)
                XCTAssertFalse(ExternalFeedback.shouldShow(result, previous: original, proposal: proposal), input)
            } else {
                XCTAssertTrue(result.workspace.questions.isEmpty, input)
                let task = try XCTUnwrap(result.workspace.tasks.first { $0.id != original.tasks[0].id })
                if index == 2 {
                    XCTAssertEqual(task.title, "买牛奶")
                    XCTAssertTrue(result.workspace.tasks[0].isCompleted)
                    XCTAssertEqual(task.reminderAt, Dates.parse("2026-09-16T09:00:00+08:00"))
                } else {
                    XCTAssertEqual(task.title, "面试")
                    XCTAssertFalse(result.workspace.tasks[0].isCompleted)
                    XCTAssertEqual(task.plannedAt, Dates.parse(index == 1 ? "2026-09-17T10:00:00+08:00" : "2026-09-16T00:00:00+08:00"))
                    XCTAssertEqual(task.reminderAt, index == 1 ? Dates.parse("2026-09-16T15:00:00+08:00") : nil)
                }
            }
        }
    }
    func testObservedWeTypePunctuationAndHomophone() async throws {
        guard ProcessInfo.processInfo.environment["VOICETODO_LIVE_QA"] == "1" else { throw XCTSkip("Explicit live QA only") }
        let defaults = try XCTUnwrap(UserDefaults(suiteName: "com.wyq.voicetodo"))
        let configuration = AppSettings(defaults: defaults).configuration
        let key = try AIKey.read(configuration: configuration, defaults: defaults)
        let text = "清单创建，代办测试，买牛奶不用提醒。"
        var capture = try XCTUnwrap(TranscriptionCapture(baseline: "", selection: NSRange(location: 0, length: 0)))
        capture.end(at: 1); capture.observe(text, at: 2)
        let accepted = try XCTUnwrap(capture.ready(at: 4))
        let start = Date.now
        let proposal = try await AIClient(configuration: configuration).interpret(input: accepted, workspace: .init(), question: nil, key: key)
        let result = try TaskReducer.apply(proposal, to: .init(), inputID: capture.id, input: accepted).workspace
        XCTAssertEqual(result.tasks.count, 1)
        XCTAssertTrue(["买牛奶", "测试买牛奶"].contains(result.tasks.first?.title ?? ""))
        XCTAssertFalse(result.tasks.first?.isCompleted ?? true)
        XCTAssertNil(result.tasks.first?.reminderAt)
        XCTAssertFalse(result.tasks.first?.needsReminder ?? true)
        XCTAssertTrue(result.questions.isEmpty)
        if let path = ProcessInfo.processInfo.environment["VOICETODO_LIVE_QA_OUTPUT"] {
            let report: [String: Any] = ["input": text, "seconds": Date.now.timeIntervalSince(start),
                "workspace": try JSONSerialization.jsonObject(with: JSONEncoder().encode(result))]
            try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys]).write(to: URL(fileURLWithPath: path), options: .atomic)
        }
    }
    func testReminderCompletionUndoAndAmbiguousFollowUpsWithRealModel() async throws {
        guard ProcessInfo.processInfo.environment["VOICETODO_LIVE_QA"] == "1" else {
            throw XCTSkip("Only run explicitly with VOICETODO_LIVE_QA=1; may call the configured AI service.")
        }
        let now = Dates.parse("2026-09-15T10:00:00+08:00")!
        let defaults = try XCTUnwrap(UserDefaults(suiteName: "com.wyq.voicetodo"))
        let configuration = AppSettings(defaults: defaults).configuration
        let key = try AIKey.read(configuration: configuration, defaults: defaults)
        let client = AIClient(configuration: configuration)
        var workspace = Workspace()
        var rows: [[String: Any]] = []
        func turn(_ input: String) async throws {
            let start = Date.now
            let question = workspace.questions.first
            let proposal = try await client.interpret(input: input, workspace: workspace, question: question,
                key: key, now: now, timeZone: "Asia/Shanghai")
            workspace = try TaskReducer.apply(proposal, to: workspace, inputID: UUID().uuidString, input: input, answering: question?.id, now: now).workspace
            rows.append(["input": input, "route": "ai", "seconds": Date.now.timeIntervalSince(start),
                         "actions": try JSONSerialization.jsonObject(with: JSONEncoder().encode(proposal)),
                         "workspace": try JSONSerialization.jsonObject(with: JSONEncoder().encode(workspace))])
        }
        defer {
            if let path = ProcessInfo.processInfo.environment["VOICETODO_LIVE_QA_OUTPUT"],
               let data = try? JSONSerialization.data(withJSONObject: rows, options: [.prettyPrinted, .sortedKeys]) {
                try? data.write(to: URL(fileURLWithPath: path), options: .atomic)
            }
        }
        try await turn("提醒我报销")
        XCTAssertEqual(workspace.tasks.count, 1); XCTAssertEqual(workspace.questions.first?.kind, .reminder)
        try await turn("清单，明天下午三点")
        XCTAssertEqual(workspace.tasks[0].reminderAt, Dates.parse("2026-09-16T15:00:00+08:00"))
        XCTAssertTrue(workspace.questions.isEmpty)
        try await turn("报销好了")
        XCTAssertTrue(workspace.tasks[0].isCompleted)
        try await turn("报销好了")
        XCTAssertEqual(workspace.tasks.count, 1)
        try await turn("撤销")
        XCTAssertFalse(workspace.tasks[0].isCompleted)
        XCTAssertEqual(workspace.tasks[0].reminderAt, Dates.parse("2026-09-16T15:00:00+08:00"))

        workspace = Workspace()
        try await turn("明天下午三点提醒我交报销材料")
        try await turn("明天下午四点提醒我交入职材料")
        let originalTasks = workspace.tasks
        try await turn("材料交好了")
        let completionQuestion = try XCTUnwrap(workspace.questions.first)
        XCTAssertEqual(completionQuestion.intent, .complete)
        XCTAssertEqual(completionQuestion.taskIDs.count, 2)
        XCTAssertEqual(workspace.tasks, originalTasks)
        try await turn("都还没做完")
        XCTAssertEqual(workspace.tasks, originalTasks)
        let continuingQuestion = try XCTUnwrap(workspace.questions.first)
        guard continuingQuestion.taskIDs.count == 2 else { XCTFail("Lost the candidates after a negative answer"); return }
        let target = continuingQuestion.taskIDs[1]
        try await turn("第二条已经交了")
        XCTAssertEqual(workspace.tasks.filter(\.isCompleted).map(\.id), [target])
        XCTAssertTrue(workspace.questions.isEmpty)
        try await turn("撤销")
        XCTAssertTrue(workspace.tasks.allSatisfy { !$0.isCompleted })
        XCTAssertEqual(workspace.questions.first?.intent, .complete)

        workspace = Workspace(tasks: originalTasks)
        try await turn("把材料的提醒改到后天下午五点")
        XCTAssertEqual(workspace.tasks, originalTasks, "Voice edits are disabled; guide the user to manual editing")
        XCTAssertTrue(workspace.questions.isEmpty)
    }
}
