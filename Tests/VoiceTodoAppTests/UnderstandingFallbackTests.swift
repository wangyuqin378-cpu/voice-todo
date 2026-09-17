import XCTest
import UserNotifications
import VoiceTodoCore
@testable import VoiceTodoApp

@MainActor private final class OfflineNotifications: TaskNotifications {
    var onStatus: ((String?) -> Void)?
    var onOpen: (() -> Void)?
    func requestPermission() async -> Bool { false }
    func authorization() async -> UNAuthorizationStatus { .denied }
    func reconcile(_ tasks: [TodoItem]) async {}
}
private actor StubUnderstanding: AIInterpreting {
    var calls = 0
    let proposal: Proposal?
    var failure: Error?
    init(_ proposal: Proposal? = nil, failure: Error? = nil) { self.proposal = proposal; self.failure = failure }
    func recover() { failure = nil }
    func interpret(input: String, workspace: Workspace, question: FollowUp?, key: String,
                   now: Date, timeZone: String, defaultReminderHour: Int, defaultReminderLeadMinutes: Int) async throws -> Proposal {
        calls += 1
        if let failure { throw failure }
        guard let proposal else { throw URLError(.notConnectedToInternet) }
        return proposal
    }
}
private actor HeldUnderstanding: AIInterpreting {
    var calls = 0
    private let proposal: Proposal
    private var released = false
    private var waiters: [CheckedContinuation<Void, Never>] = []
    init(_ proposal: Proposal) { self.proposal = proposal }
    func release() { released = true; waiters.forEach { $0.resume() }; waiters = [] }
    func interpret(input: String, workspace: Workspace, question: FollowUp?, key: String,
                   now: Date, timeZone: String, defaultReminderHour: Int, defaultReminderLeadMinutes: Int) async throws -> Proposal {
        calls += 1
        if !released { await withCheckedContinuation { waiters.append($0) } }
        return proposal
    }
}
@MainActor final class UnderstandingFallbackTests: XCTestCase {
    private func app(key: String = "", ai: any AIInterpreting = StubUnderstanding(), workspace: Workspace = .init(), timeout: TimeInterval = 8, keyReader: (() throws -> String)? = nil) throws -> AppState {
        let suite = "com.wyq.voicetodo.qa." + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        addTeardownBlock { defaults.removePersistentDomain(forName: suite) }
        let settings = AppSettings(defaults: defaults); settings.speakQuestions = false
        let repository = try Repository(inMemory: true); try repository.save(workspace)
        return try AppState(repository: repository, settings: settings, notifications: OfflineNotifications(),
                            aiKeyReader: keyReader ?? { key }, aiInterpreter: ai, aiWaitLimit: timeout)
    }
    private func settle(_ state: AppState, attempts: Int = 200) async throws {
        for _ in 0..<attempts where state.busy { try await Task.sleep(for: .milliseconds(5)) }
        XCTAssertFalse(state.busy)
    }
    private func say(_ text: String, to state: AppState) async throws {
        state.enqueueExternal(text, id: UUID().uuidString)
        try await settle(state)
        XCTAssertTrue(state.errorMessage.isEmpty, state.errorMessage)
    }
    func testLegacyMissingKeyRecordNoLongerDemandsConfiguration() {
        let message = CaptureRecovery.explanation("请先在设置中填写 AI API Key。原话已经保留。")
        XCTAssertTrue(message.contains("无需 Key"))
        XCTAssertTrue(message.contains("手动整理"))
        XCTAssertFalse(message.contains("填写"))
        XCTAssertEqual(CaptureRecovery.explanation("网络失败"), "网络失败")
    }
    func testTravelDiscussionDoesNotReadKeyCallAIOrStoreCapture() async throws {
        let ai = StubUnderstanding(.init(actions: [.init(kind: .create, title: "住两天水屋", noReminder: true)]))
        var keyReads = 0
        let existing = TodoItem(title: "预订酒店")
        let state = try app(ai: ai, workspace: .init(tasks: [existing]), keyReader: {
            keyReads += 1; return "fake-qa-key-not-a-credential"
        })
        var overlays = 0
        state.showOverlay = { overlays += 1 }
        for input in ["如果我想住两天水屋呢，再帮我安排一下",
            "如果我想住两天水屋呢 ，再帮我安排一下 ，在仙本那住两天水屋",
            "帮我规划一下明天的旅行路线"] {
            try await say(input, to: state)
        }
        XCTAssertEqual(state.workspace.tasks, [existing])
        XCTAssertTrue(state.workspace.questions.isEmpty)
        XCTAssertTrue(state.pending.isEmpty)
        XCTAssertEqual(overlays, 0)
        XCTAssertEqual(keyReads, 0)
        let calls = await ai.calls; XCTAssertEqual(calls, 0)
    }
    func testNoKeyCreateCompleteCancelUndoAndDuplicateDelivery() async throws {
        let ai = StubUnderstanding(); let state = try app(ai: ai)
        try await say("我明天下午三点面试，提醒我一下", to: state)
        let task = try XCTUnwrap(state.workspace.tasks.first)
        XCTAssertEqual(task.title, "面试")
        XCTAssertEqual(try XCTUnwrap(task.plannedAt).timeIntervalSince(try XCTUnwrap(task.reminderAt)), 600)
        try await say("面试完成了", to: state)
        XCTAssertTrue(state.workspace.tasks[0].isCompleted)
        try await say("面试完成了", to: state)
        XCTAssertEqual(state.workspace.tasks.count, 1)
        try await say("撤销", to: state)
        XCTAssertFalse(state.workspace.tasks[0].isCompleted)
        try await say("帮我取消面试", to: state)
        XCTAssertTrue(state.workspace.tasks.isEmpty)
        state.enqueueExternal("记一下买牛奶", id: "same")
        try await settle(state)
        state.enqueueExternal("记一下买牛奶", id: "same")
        try await settle(state)
        XCTAssertEqual(state.workspace.tasks.map(\.title), ["买牛奶"])
        let count = await ai.calls; XCTAssertEqual(count, 0)
    }
    func testNoKeyMixedInputAndCompletedRecord() async throws {
        let state = try app(workspace: .init(tasks: [.init(title: "报销")]))
        try await say("报销好了，明天下午三点提醒我买牛奶", to: state)
        XCTAssertTrue(state.workspace.tasks[0].isCompleted)
        XCTAssertEqual(state.workspace.tasks.last?.title, "买牛奶")
        XCTAssertNotNil(state.workspace.tasks.last?.reminderAt)
        try await say("车票买好了", to: state)
        XCTAssertEqual(state.workspace.tasks.last?.title, "买车票")
        XCTAssertTrue(state.workspace.tasks.last?.isCompleted == true)
    }
    func testManualPlainTextNeedsNoAIAndUnknownTextCanBeRecovered() async throws {
        let state = try app()
        state.draft = "买牛奶"; state.submitDraft(); try await settle(state)
        XCTAssertEqual(state.workspace.tasks.map(\.title), ["买牛奶"])
        state.draft = "如果周末不下雨再考虑安排旅行"; state.submitDraft(); try await settle(state)
        XCTAssertEqual(state.workspace.tasks.count, 1)
        XCTAssertEqual(state.pending.count, 1)
        XCTAssertTrue(state.errorMessage.contains("手动"))
        XCTAssertFalse(state.errorMessage.contains("填写"))
        let capture = try XCTUnwrap(state.pending.first)
        XCTAssertTrue(state.edit(TodoItem(title: "规划旅行", originalInput: capture.text), message: "已手动添加"))
        XCTAssertEqual(state.workspace.tasks.count, 2)
        XCTAssertEqual(state.pending.count, 1, "Keep the source until all items have been organized")
        state.dismissCapture(capture); XCTAssertTrue(state.pending.isEmpty)
    }
    private let complex = "记一下买牛奶以及买面包"
    private let split = Proposal(actions: [
        .init(kind: .create, title: "买牛奶", noReminder: true),
        .init(kind: .create, title: "买面包", noReminder: true)
    ])
    func testSimpleCommandsNeverReadKeyOrCallConfiguredAI() async throws {
        let ai = StubUnderstanding(.init(actions: [.init(kind: .clarify, question: "具体哪一种牛奶？")]))
        var keyReads = 0
        let state = try app(ai: ai, keyReader: { keyReads += 1; throw URLError(.notConnectedToInternet) })
        try await say("记一下买牛奶", to: state)
        try await say("我明天下午三点面试，提醒我一下", to: state)
        try await say("面试完成了", to: state)
        try await say("撤销", to: state)
        try await say("帮我取消面试", to: state)
        XCTAssertEqual(state.workspace.tasks.map(\.title), ["买牛奶"])
        XCTAssertTrue(state.workspace.questions.isEmpty)
        XCTAssertTrue(state.understandingNotice.isEmpty)
        XCTAssertEqual(keyReads, 0)
        let calls = await ai.calls; XCTAssertEqual(calls, 0)
    }
    func testConfiguredSlowAIIsSkippedForSimpleMixedInput() async throws {
        let ai = HeldUnderstanding(split)
        let state = try app(key: "fake-qa-key-not-a-credential", ai: ai, workspace: .init(tasks: [.init(title: "报销")]))
        try await say("报销好了，明天下午三点提醒我买牛奶", to: state)
        XCTAssertTrue(state.workspace.tasks[0].isCompleted)
        XCTAssertEqual(state.workspace.tasks.last?.title, "买牛奶")
        XCTAssertFalse(state.waitingForAI)
        let calls = await ai.calls; XCTAssertEqual(calls, 0)
    }
    func testComplexPhraseUsesAIAndCommitsAllActionsTogether() async throws {
        let ai = StubUnderstanding(split)
        let state = try app(key: "fake-qa-key-not-a-credential", ai: ai)
        try await say(complex, to: state)
        let calls = await ai.calls; XCTAssertEqual(calls, 1)
        XCTAssertEqual(state.workspace.tasks.map(\.title), ["买牛奶", "买面包"])
        XCTAssertTrue(state.pending.isEmpty)
    }
    func testAmbiguousCompletionAsksLocallyWithoutCallingAI() async throws {
        let old = TodoItem(id: "visa", title: "交签证材料")
        let ai = StubUnderstanding(.init(actions: [.init(kind: .complete, taskID: old.id, candidates: [old.id], evidence: "材料交好了")]))
        let state = try app(key: "fake-qa-key-not-a-credential", ai: ai, workspace: .init(tasks: [old]))
        try await say("材料交好了", to: state)
        XCTAssertEqual(state.workspace.tasks, [old])
        XCTAssertEqual(state.workspace.questions.first?.intent, .complete)
        let calls = await ai.calls; XCTAssertEqual(calls, 0)
    }
    func testBrokenConfigurationPausesComplexRequestsButSimpleCommandsStayInstant() async throws {
        let ai = StubUnderstanding(.init(actions: [.init(kind: .noop)]), failure: AIServiceError(.credentials, "密钥无效"))
        let state = try app(key: "fake-qa-key-not-a-credential", ai: ai)
        state.enqueueExternal(complex, id: "failed"); try await settle(state)
        XCTAssertEqual(state.pending.count, 1)
        XCTAssertFalse(state.errorMessage.isEmpty)
        XCTAssertTrue(state.understandingNotice.contains("本机处理"))
        state.enqueueExternal(complex, id: "paused"); try await settle(state)
        try await say("记一下买车票", to: state)
        var count = await ai.calls; XCTAssertEqual(count, 1)
        XCTAssertEqual(state.workspace.tasks.map(\.title), ["买车票"])
        XCTAssertTrue(state.understandingNotice.isEmpty, "Simple success must not show an irrelevant AI warning")
        await ai.recover()
        state.checkLocalConnection()
        for _ in 0..<200 where state.checkingConnection { try await Task.sleep(for: .milliseconds(5)) }
        XCTAssertTrue(state.connectionOK)
        try await say(complex, to: state)
        count = await ai.calls; XCTAssertEqual(count, 3, "Manual check and complex input reach the recovered service")
        XCTAssertEqual(state.workspace.tasks.count, 1)
    }
    func testNetworkOutageRetainsUnresolvedTextAndDoesNotBlockLocalTasks() async throws {
        let ai = StubUnderstanding(); let state = try app(key: "fake-qa-key-not-a-credential", ai: ai)
        state.enqueueExternal(complex, id: "offline"); try await settle(state)
        state.enqueueExternal(complex, id: "cooldown"); try await settle(state)
        XCTAssertTrue(state.understandingNotice.contains("1 分钟"))
        XCTAssertEqual(state.pending.count, 2)
        try await say("记一下买车票", to: state)
        let count = await ai.calls; XCTAssertEqual(count, 1)
        XCTAssertEqual(state.workspace.tasks.count, 1)
    }
    func testConfigurationChangeRestoresComplexAttemptWithoutChangingKey() async throws {
        let ai = StubUnderstanding(split, failure: AIServiceError(.configuration, "模型不存在"))
        let state = try app(key: "fake-qa-key-not-a-credential", ai: ai)
        state.enqueueExternal(complex, id: "broken"); try await settle(state)
        XCTAssertEqual(state.workspace.tasks.count, 0)
        await ai.recover(); state.settings.model = "correct-model"
        try await say(complex, to: state)
        let count = await ai.calls; XCTAssertEqual(count, 2)
        XCTAssertEqual(state.workspace.tasks.count, 2)
        XCTAssertTrue(state.understandingNotice.isEmpty)
    }
    func testTimeoutReleasesQueueAndLateSuccessCannotWriteTasks() async throws {
        let ai = HeldUnderstanding(split)
        let state = try app(key: "fake-qa-key-not-a-credential", ai: ai, timeout: 0.08)
        state.enqueueExternal(complex, id: "slow")
        for _ in 0..<100 where !state.waitingForAI { try await Task.sleep(for: .milliseconds(1)) }
        XCTAssertTrue(state.waitingForAI)
        // This input must proceed when the deadline expires, without waiting for
        // the non-cooperative first response. The failed source remains recoverable.
        state.enqueueExternal("记一下买车票", id: "next")
        try await settle(state)
        XCTAssertFalse(state.waitingForAI)
        XCTAssertEqual(state.workspace.tasks.map(\.title), ["买车票"])
        XCTAssertEqual(state.pending.map(\.text), [complex])
        XCTAssertTrue(state.pending.first?.issue.contains("超时") == true)
        await ai.release()
        try await Task.sleep(for: .milliseconds(20))
        XCTAssertEqual(state.workspace.tasks.map(\.title), ["买车票"])
        XCTAssertFalse(state.workspace.appliedInputs.contains("external-slow"))
    }
    func testStopWaitingRetainsTextAndRetryCannotDoubleApplyLateResponse() async throws {
        let ai = HeldUnderstanding(split)
        let state = try app(key: "fake-qa-key-not-a-credential", ai: ai)
        state.enqueueExternal(complex, id: "cancel")
        for _ in 0..<100 where !state.waitingForAI { try await Task.sleep(for: .milliseconds(1)) }
        XCTAssertTrue(state.waitingForAI)
        for _ in 0..<100 {
            if await ai.calls == 1 { break }
            try await Task.sleep(for: .milliseconds(1))
        }
        state.stopWaitingForAI(); try await settle(state)
        XCTAssertTrue(state.workspace.tasks.isEmpty)
        XCTAssertTrue(state.errorMessage.contains("取消"))
        XCTAssertFalse(state.waitingForAI)
        let capture = try XCTUnwrap(state.pending.first)
        await ai.release()
        state.retry(capture); try await settle(state)
        XCTAssertTrue(state.errorMessage.isEmpty, state.errorMessage)
        XCTAssertEqual(state.workspace.tasks.map(\.title), ["买牛奶", "买面包"])
        XCTAssertTrue(state.pending.isEmpty)
        let calls = await ai.calls; XCTAssertEqual(calls, 2, "User cancellation must not pause AI health")
        try await Task.sleep(for: .milliseconds(20))
        XCTAssertEqual(state.workspace.tasks.count, 2)
    }
    func testInvalidComplexAIResultIsRetainedWithoutPartialWrites() async throws {
        let old = TodoItem(id: "visa", title: "交签证材料")
        let ai = StubUnderstanding(.init(actions: [
            .init(kind: .create, title: "买牛奶", noReminder: true),
            .init(kind: .complete, taskID: old.id, candidates: [old.id])
        ]))
        let state = try app(key: "fake-qa-key-not-a-credential", ai: ai, workspace: .init(tasks: [old]))
        state.enqueueExternal(complex, id: "unsafe"); try await settle(state)
        let calls = await ai.calls; XCTAssertEqual(calls, 1)
        XCTAssertEqual(state.workspace.tasks, [old])
        XCTAssertEqual(state.pending.count, 1)
    }
    func testConnectionCheckAlsoHasDeadlineAndIgnoresLateSuccess() async throws {
        let ai = HeldUnderstanding(.init(actions: [.init(kind: .noop)]))
        let state = try app(key: "fake-qa-key-not-a-credential", ai: ai, timeout: 0.03)
        state.checkLocalConnection()
        for _ in 0..<200 where state.checkingConnection { try await Task.sleep(for: .milliseconds(5)) }
        XCTAssertFalse(state.checkingConnection)
        XCTAssertFalse(state.connectionOK)
        XCTAssertTrue(state.connectionStatus.contains("超时"))
        await ai.release()
        try await Task.sleep(for: .milliseconds(20))
        XCTAssertFalse(state.connectionOK)
        XCTAssertTrue(state.workspace.tasks.isEmpty)
    }
    func testLiveLocalFirstRoutingWithConfiguredService() async throws {
        guard ProcessInfo.processInfo.environment["VOICETODO_LIVE_ROUTING_QA"] == "1" else {
            throw XCTSkip("Explicit live routing QA only")
        }
        let liveDefaults = try XCTUnwrap(UserDefaults(suiteName: "com.wyq.voicetodo"))
        let configuration = AppSettings(defaults: liveDefaults).configuration
        var keyReads = 0
        let state = try app(ai: AIClient(configuration: configuration), keyReader: {
            keyReads += 1
            return try AIKey.read(configuration: configuration, defaults: liveDefaults)
        })
        state.settings.baseURL = configuration.baseURL; state.settings.model = configuration.model
        state.settings.apiProtocol = configuration.apiProtocol
        let localStart = Date.now
        try await say("明天下午三点提醒我面试", to: state)
        print("Routing QA: simple text-to-task \(Int(Date.now.timeIntervalSince(localStart) * 1000)) ms; key reads \(keyReads)")
        XCTAssertEqual(keyReads, 0)
        XCTAssertEqual(state.workspace.tasks.first?.title, "面试")
        let aiStart = Date.now
        state.enqueueExternal(complex, id: "live-complex")
        try await settle(state, attempts: 2000)
        print("Routing QA: complex text-to-result \(Int(Date.now.timeIntervalSince(aiStart) * 1000)) ms; retained inputs \(state.pending.count)")
        XCTAssertEqual(keyReads, 1)
        XCTAssertTrue(state.errorMessage.isEmpty, state.errorMessage)
        XCTAssertTrue(state.pending.isEmpty)
        XCTAssertEqual(state.workspace.tasks.map(\.title), ["面试", "买牛奶", "买面包"])
    }
    func testConnectionCheckRequiresNoopAndDoesNotWriteTasks() {
        XCTAssertThrowsError(try AppState.validateConnection(.init(actions: [.init(kind: .create, title: "wrong task")])))
        XCTAssertThrowsError(try AppState.validateConnection(.init(actions: [])))
        XCTAssertNoThrow(try AppState.validateConnection(.init(actions: [.init(kind: .noop)])))
    }
    func testNegativeMixedInputCannotPartiallyCompleteWithoutAI() async throws {
        let old = TodoItem(title: "报销")
        let state = try app(workspace: .init(tasks: [old]))
        state.enqueueExternal("报销好了，不对，还没完成，明天提醒我买牛奶", id: "negative")
        try await settle(state)
        XCTAssertEqual(state.workspace.tasks, [old])
        XCTAssertEqual(state.pending.count, 1)
        XCTAssertFalse(state.errorMessage.contains("填写"))
    }
    func testNoKeyFollowUpUsesSameVoiceEntryWithoutPrefix() async throws {
        let state = try app()
        try await say("提醒我报销", to: state)
        let q = try XCTUnwrap(state.workspace.questions.first)
        state.enqueueExternal("明天下午三点", id: "reply", answerID: q.id)
        try await settle(state)
        XCTAssertTrue(state.errorMessage.isEmpty, state.errorMessage)
        XCTAssertTrue(state.workspace.questions.isEmpty)
        XCTAssertNotNil(state.workspace.tasks.first?.reminderAt)
    }
}
