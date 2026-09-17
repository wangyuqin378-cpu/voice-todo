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
@MainActor final class UnderstandingFallbackTests: XCTestCase {
    private func app(key: String = "", ai: StubUnderstanding = .init(), workspace: Workspace = .init()) throws -> AppState {
        let suite = "com.wyq.voicetodo.qa." + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        addTeardownBlock { defaults.removePersistentDomain(forName: suite) }
        let settings = AppSettings(defaults: defaults); settings.speakQuestions = false
        let repository = try Repository(inMemory: true); try repository.save(workspace)
        return try AppState(repository: repository, settings: settings, notifications: OfflineNotifications(),
                            aiKeyReader: { key }, aiInterpreter: ai)
    }
    private func settle(_ state: AppState) async throws {
        for _ in 0..<200 where state.busy { try await Task.sleep(for: .milliseconds(5)) }
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
    func testConfiguredAIIsFirstEvenWhenLocalRuleCouldCreate() async throws {
        // The stub requests clarification; a local-first implementation would create immediately.
        let ai = StubUnderstanding(.init(actions: [.init(kind: .clarify, question: "具体哪一种牛奶？")]))
        let state = try app(key: "fake-qa-key-not-a-credential", ai: ai)
        try await say("记一下买牛奶", to: state)
        let count = await ai.calls; XCTAssertEqual(count, 1)
        XCTAssertTrue(state.workspace.tasks.isEmpty)
        XCTAssertEqual(state.workspace.questions.first?.question, "具体哪一种牛奶？")
    }
    func testAIOutageFallsBackWithoutLosingTheTask() async throws {
        let ai = StubUnderstanding(); let state = try app(key: "fake-qa-key-not-a-credential", ai: ai)
        try await say("明天下午三点面试", to: state)
        let count = await ai.calls; XCTAssertEqual(count, 1)
        XCTAssertEqual(state.workspace.tasks.first?.title, "面试")
        XCTAssertNil(state.workspace.tasks.first?.reminderAt)
        XCTAssertTrue(state.pending.isEmpty)
    }
    func testUnsafeAICompletionFallsBackWithoutCompletingSimilarTask() async throws {
        let old = TodoItem(id: "visa", title: "交签证材料")
        let ai = StubUnderstanding(.init(actions: [.init(kind: .complete, taskID: old.id, candidates: [old.id], evidence: "材料交好了")]))
        let state = try app(key: "fake-qa-key-not-a-credential", ai: ai, workspace: .init(tasks: [old]))
        try await say("材料交好了", to: state)
        XCTAssertEqual(state.workspace.tasks, [old])
        XCTAssertEqual(state.workspace.questions.first?.intent, .complete)
    }
    func testBrokenConfigurationIsNotCalledForEveryTaskAndCheckCanRecover() async throws {
        let ai = StubUnderstanding(.init(actions: [.init(kind: .noop)]), failure: AIServiceError(.credentials, "密钥无效"))
        let state = try app(key: "fake-qa-key-not-a-credential", ai: ai)
        try await say("记一下买牛奶", to: state)
        try await say("记一下买车票", to: state)
        var count = await ai.calls; XCTAssertEqual(count, 1)
        XCTAssertEqual(state.workspace.tasks.map(\.title), ["买牛奶", "买车票"])
        XCTAssertTrue(state.understandingNotice.contains("本机规则"))
        XCTAssertFalse(state.connectionOK)
        await ai.recover()
        state.checkLocalConnection()
        for _ in 0..<200 where state.checkingConnection { try await Task.sleep(for: .milliseconds(5)) }
        XCTAssertTrue(state.connectionOK)
        XCTAssertTrue(state.understandingNotice.isEmpty)
        try await say("记一下买面包", to: state)
        count = await ai.calls; XCTAssertEqual(count, 3, "Manual check and subsequent input must reach the service again")
        XCTAssertEqual(state.workspace.tasks.count, 2, "AI noop wins after recovery")
    }
    func testNetworkOutageUsesLocalRulesForSubsequentInputsDuringCooldown() async throws {
        let ai = StubUnderstanding(); let state = try app(key: "fake-qa-key-not-a-credential", ai: ai)
        try await say("记一下买牛奶", to: state)
        try await say("记一下买车票", to: state)
        let count = await ai.calls; XCTAssertEqual(count, 1)
        XCTAssertEqual(state.workspace.tasks.count, 2)
        XCTAssertTrue(state.understandingNotice.contains("1 分钟"))
    }
    func testConfigurationChangeRestoresAttemptWithoutChangingKey() async throws {
        let ai = StubUnderstanding(.init(actions: [.init(kind: .noop)]), failure: AIServiceError(.configuration, "模型不存在"))
        let state = try app(key: "fake-qa-key-not-a-credential", ai: ai)
        try await say("记一下买牛奶", to: state)
        await ai.recover(); state.settings.model = "correct-model"
        try await say("记一下买车票", to: state)
        let count = await ai.calls; XCTAssertEqual(count, 2)
        XCTAssertEqual(state.workspace.tasks.count, 1)
        XCTAssertTrue(state.understandingNotice.isEmpty)
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
