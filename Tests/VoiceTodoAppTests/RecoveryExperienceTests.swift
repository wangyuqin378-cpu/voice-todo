import XCTest
import UserNotifications
import VoiceTodoCore
@testable import VoiceTodoApp

@MainActor private final class RecoveryNotifications: TaskNotifications {
    var onStatus: ((String?) -> Void)?
    var onOpen: (() -> Void)?
    var tasks: [TodoItem] = []
    func requestPermission() async -> Bool { false }
    func authorization() async -> UNAuthorizationStatus { .denied }
    func reconcile(_ tasks: [TodoItem]) async { self.tasks = tasks }
}

@MainActor final class RecoveryExperienceTests: XCTestCase {
    private func app(_ repository: Repository) throws -> AppState {
        let name = "com.wyq.voicetodo.qa." + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: name))
        addTeardownBlock { defaults.removePersistentDomain(forName: name) }
        let settings = AppSettings(defaults: defaults); settings.speakQuestions = false
        return try AppState(repository: repository, settings: settings, notifications: RecoveryNotifications())
    }
    private func settle(_ state: AppState) async throws {
        for _ in 0..<200 where state.busy { try await Task.sleep(for: .milliseconds(5)) }
        XCTAssertFalse(state.busy)
    }
    func testQuestionAndTargetsSurviveReopenAndRemainVisibleAfterResolution() throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appending(path: "tasks.store")
        var repository: Repository? = try Repository(url: url)
        let item = TodoItem(title: "交材料", needsReminder: true)
        var workspace = Workspace(tasks: [item])
        let question = FollowUp(kind: .reminder, question: "材料什么时候提醒？", taskIDs: [item.id], originalInput: "提醒我交材料")
        workspace.questions = [question]; try repository!.save(workspace)
        let capture = try repository!.capture("明天下午三点", questionID: question.id)
        try repository!.fail(capture, message: "网络失败")
        workspace.questions = []; try repository!.save(workspace)
        repository = nil
        let reopened = try Repository(url: url)
        let record = try XCTUnwrap(reopened.pending().first)
        let context = try reopened.captureContext(for: record)
        XCTAssertEqual(context.question, question)
        XCTAssertEqual(context.relatedTasks, [item])
        XCTAssertNotNil(CaptureRecovery.issue(questionID: record.questionID, context: context, workspace: workspace))
    }
    func testStaleAnswerCannotRunAsNewInstructionAndCanBeRewritten() async throws {
        let repository = try Repository(inMemory: true)
        let capture = try repository.capture("是的", questionID: "removed-question")
        let state = try app(repository)
        state.retry(capture); try await settle(state)
        XCTAssertTrue(state.errorMessage.contains("原问题"))
        XCTAssertTrue(state.workspace.tasks.isEmpty)
        state.editCapture(capture); state.submitDraft()
        XCTAssertEqual(state.draft, "是的")
        XCTAssertTrue(state.errorMessage.contains("完整"))
        state.draft = "帮我安排明天面试"
        state.submitDraft(); try await settle(state)
        XCTAssertTrue(state.errorMessage.isEmpty, state.errorMessage)
        XCTAssertEqual(state.workspace.tasks.map(\.title), ["面试"])
        XCTAssertTrue(state.pending.isEmpty)
        XCTAssertNil(capture.questionID)
        state.retry(capture); try await settle(state)
        XCTAssertEqual(state.workspace.tasks.count, 1)
    }
    func testOrphanedYesIsPreservedWithoutCallingAIOrCompletingTasks() async throws {
        let repository = try Repository(inMemory: true)
        let item = TodoItem(title: "交材料")
        try repository.save(.init(tasks: [item]))
        let capture = try repository.capture("是的。", questionID: nil)
        let state = try app(repository)
        state.retry(capture); try await settle(state)
        XCTAssertEqual(state.workspace.tasks, [item])
        XCTAssertTrue(state.errorMessage.contains("没有对应的问题"))
        XCTAssertEqual(state.pending.map(\.id), [capture.id])
    }
    func testLiveQuestionCanRetryAnswerAndCloseOnlyItsReminder() async throws {
        let repository = try Repository(inMemory: true)
        let item = TodoItem(title: "报销", needsReminder: true)
        var workspace = Workspace(tasks: [item])
        let q = FollowUp(kind: .reminder, question: "什么时候提醒报销？", taskIDs: [item.id], originalInput: "提醒我报销")
        workspace.questions = [q]; try repository.save(workspace)
        let capture = try repository.capture("不用提醒", questionID: q.id)
        try repository.fail(capture, message: "测试失败")
        let state = try app(repository)
        XCTAssertNil(state.recoveryIssue(capture))
        state.retry(capture); try await settle(state)
        XCTAssertTrue(state.errorMessage.isEmpty, state.errorMessage)
        XCTAssertFalse(try XCTUnwrap(state.workspace.tasks.first).needsReminder)
        XCTAssertTrue(state.workspace.questions.isEmpty)
        XCTAssertTrue(state.pending.isEmpty)
    }
    func testAddressedAnswerWithoutQuestionCannotCreateOrCompleteAnything() async throws {
        let repository = try Repository(inMemory: true)
        let item = TodoItem(title: "交材料")
        try repository.save(.init(tasks: [item]))
        let state = try app(repository)
        for text in ["清单，是的", "随口清单，不用提醒"] {
            state.enqueueExternal(text, id: UUID().uuidString)
            try await settle(state)
            XCTAssertEqual(state.workspace.tasks, [item])
            XCTAssertTrue(state.errorMessage.contains("没有对应的问题"), state.errorMessage)
        }
        XCTAssertEqual(state.pending.count, 2)
    }
    func testChangedCandidateBlocksOldAnswer() throws {
        let repository = try Repository(inMemory: true)
        let item = TodoItem(title: "报销", needsReminder: true)
        var workspace = Workspace(tasks: [item])
        let q = FollowUp(kind: .reminder, question: "什么时候提醒？", taskIDs: [item.id], originalInput: "提醒我报销")
        workspace.questions = [q]; try repository.save(workspace)
        let capture = try repository.capture("十分钟后", questionID: q.id)
        workspace.tasks[0].title = "报销差旅费"
        XCTAssertNotNil(CaptureRecovery.issue(questionID: q.id, context: try repository.captureContext(for: capture), workspace: workspace))
    }
    func testManualCancelDisableAndUndoPersistAndRestoreReminderPlan() throws {
        let repository = try Repository(inMemory: true)
        let item = TodoItem(title: "面试", reminderAt: .now.addingTimeInterval(3600), plannedAt: .now.addingTimeInterval(3600), plannedHasTime: true)
        let other = TodoItem(title: "面试", reminderAt: .now.addingTimeInterval(86400))
        try repository.save(.init(tasks: [item, other]))
        let state = try app(repository)
        state.disableReminder(item)
        XCTAssertNil(state.workspace.tasks[0].reminderAt)
        XCTAssertEqual(state.workspace.tasks[0].plannedAt, item.plannedAt)
        state.undo()
        XCTAssertEqual(state.workspace.tasks[0].reminderAt, item.reminderAt)
        XCTAssertNotEqual(state.workspace.tasks[0].reminderRevision, item.reminderRevision)
        state.cancelTask(item)
        XCTAssertEqual(state.workspace.tasks.map(\.id), [other.id])
        XCTAssertTrue(state.workspace.lastActivity?.summary.contains("已取消") == true)
        let reopened = try app(repository)
        XCTAssertEqual(reopened.workspace.lastActivity, state.workspace.lastActivity)
        reopened.undo()
        XCTAssertEqual(Set(reopened.workspace.tasks.map(\.id)), Set([item.id, other.id]))
        let plans = ReminderPlanner.plans(tasks: reopened.workspace.tasks, delivered: [], scheduled: [], now: .now)
        XCTAssertEqual(plans.count, 2)
        XCTAssertTrue(reopened.workspace.lastActivity?.summary.contains("已撤销") == true)
    }
    func testStaleEditorCannotRecreateCancelledTaskOrLoseDraft() throws {
        let repository = try Repository(inMemory: true)
        let item = TodoItem(title: "面试")
        try repository.save(.init(tasks: [item]))
        let capture = try repository.capture("需要修改的原话", questionID: nil)
        let state = try app(repository)
        state.cancelTask(item)
        XCTAssertFalse(state.edit(item, mustExist: true))
        XCTAssertTrue(state.workspace.tasks.isEmpty)
        state.draft = "尚未提交的重要内容"
        state.editCapture(capture)
        XCTAssertEqual(state.draft, "尚未提交的重要内容")
        XCTAssertNil(state.editingCaptureID)
    }
    func testCandidateButtonUsesDisplayedQuestionNotUnrelatedFirstQuestion() throws {
        let repository = try Repository(inMemory: true)
        let a = TodoItem(title: "报销", needsReminder: true), b = TodoItem(title: "交材料")
        var workspace = Workspace(tasks: [a, b])
        let first = FollowUp(kind: .reminder, question: "报销什么时候提醒？", taskIDs: [a.id], originalInput: "提醒我报销")
        let second = FollowUp(kind: .chooseTask, question: "取消哪件事？", taskIDs: [b.id], originalInput: "取消材料", intent: .cancelTask)
        workspace.questions = [first, second]; try repository.save(workspace)
        let state = try app(repository)
        state.choose(b.id, questionID: second.id)
        XCTAssertEqual(state.workspace.tasks.map(\.id), [a.id])
        XCTAssertEqual(state.workspace.questions, [first])
    }
    func testMenuFeedbackStaysSilentButDistinguishesRecordingAndNoText() throws {
        let state = try app(Repository(inMemory: true)); var popups = 0
        state.showOverlay = { popups += 1 }
        state.fnSpeech.onBegin?(); state.fnSpeech.onState?(.starting)
        XCTAssertTrue(state.captureStatus.title.contains("打开麦克风"))
        state.fnSpeech.onState?(.listening)
        XCTAssertTrue(state.captureStatus.title.contains("正在听"))
        state.fnSpeech.onState?(.finishing)
        XCTAssertTrue(state.captureStatus.title.contains("已结束"))
        state.fnSpeech.onState?(.idle); state.fnSpeech.onStatus?("Fn 本机识别 · 未听到文字")
        XCTAssertTrue(state.captureStatus.title.contains("未听到文字"))
        XCTAssertEqual(popups, 0)
    }
    func testInvalidAIReplacementLeavesExistingConfigurationUntouched() async throws {
        let state = try app(Repository(inMemory: true))
        let original = state.settings.configuration
        state.settings.defaults.set("local-reference", forKey: AIKey.referenceKey)
        state.checkConnection(key: "", configuration: .init(baseURL: "invalid", model: "new-model"))
        for _ in 0..<100 where state.checkingConnection { try await Task.sleep(for: .milliseconds(5)) }
        XCTAssertFalse(state.checkingConnection)
        XCTAssertFalse(state.connectionOK)
        XCTAssertEqual(state.settings.configuration, original)
        XCTAssertEqual(state.settings.defaults.string(forKey: AIKey.referenceKey), "local-reference")
    }
    func testConcurrentEditCannotOverwriteMoreRecentTaskChanges() throws {
        let repository = try Repository(inMemory: true)
        let item = TodoItem(title: "交材料")
        try repository.save(.init(tasks: [item]))
        let state = try app(repository)
        state.toggle(item)
        var staleEdit = item; staleEdit.title = "交签证材料"
        XCTAssertFalse(state.edit(staleEdit, mustExist: true, expected: item))
        XCTAssertTrue(try XCTUnwrap(state.workspace.tasks.first).isCompleted)
        XCTAssertEqual(state.workspace.tasks.first?.title, item.title)
    }
    func testLegacyWorkspaceAndCaptureContextDecodeWithoutNewFields() throws {
        let legacy = Data(#"{"tasks":[],"questions":[],"appliedInputs":[],"undo":[]}"#.utf8)
        XCTAssertNil(try JSONDecoder().decode(Workspace.self, from: legacy).lastActivity)
        let oldContext = Data(#"{"originalText":"是的","originalDate":0,"originalTimeZone":"Asia/Shanghai","interpretationDate":0,"interpretationTimeZone":"Asia/Shanghai"}"#.utf8)
        XCTAssertNil(try JSONDecoder().decode(CaptureContext.self, from: oldContext).question)
    }
    func testResolvingOneQuestionContinuesToTheNextAndClearsOldNoSpeechState() async throws {
        let repository = try Repository(inMemory: true)
        let a = TodoItem(title: "报销", needsReminder: true), b = TodoItem(title: "买牛奶", needsReminder: true)
        var workspace = Workspace(tasks: [a, b])
        let qa = FollowUp(kind: .reminder, question: "报销什么时候提醒？", taskIDs: [a.id], originalInput: "提醒我报销")
        let qb = FollowUp(kind: .reminder, question: "牛奶什么时候提醒？", taskIDs: [b.id], originalInput: "提醒我买牛奶")
        workspace.questions = [qa, qb]; try repository.save(workspace)
        let state = try app(repository)
        state.lastVoiceOutcome = "本次未听到文字"
        state.submit("不用提醒", answerID: qa.id); try await settle(state)
        XCTAssertEqual(state.workspace.questions, [qb])
        XCTAssertEqual(state.overlayQuestion?.id, qb.id)
        XCTAssertNil(state.lastVoiceOutcome)
    }
    func testScheduleDistinguishesEventAndReminderAndCombinesIdenticalTimes() throws {
        let date = Date.now.addingTimeInterval(3600)
        var item = TodoItem(title: "面试", reminderAt: date, plannedAt: date, plannedHasTime: true)
        XCTAssertEqual(TaskPresentation.schedule(item).count, 1)
        XCTAssertTrue(TaskPresentation.schedule(item)[0].contains("到时提醒"))
        item.reminderAt = date.addingTimeInterval(-600)
        XCTAssertEqual(TaskPresentation.schedule(item).count, 2)
        XCTAssertTrue(TaskPresentation.schedule(item)[0].hasPrefix("安排在"))
        XCTAssertTrue(TaskPresentation.schedule(item)[1].hasPrefix("提醒于"))
        item.reminderAt = nil
        XCTAssertEqual(TaskPresentation.schedule(item).last, "不提醒")
    }
}
