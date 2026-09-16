import XCTest
import UserNotifications
import VoiceTodoCore
@testable import VoiceTodoApp

@MainActor private final class QuietNotifications: TaskNotifications {
    var onStatus: ((String?) -> Void)?
    var onOpen: (() -> Void)?
    var tasks: [TodoItem] = []
    func requestPermission() async -> Bool { false }
    func authorization() async -> UNAuthorizationStatus { .denied }
    func reconcile(_ tasks: [TodoItem]) async { self.tasks = tasks }
}

@MainActor final class SilentCaptureTests: XCTestCase {
    func testRealAppCallbacksStaySilentUntilRecognizedResult() async throws {
        let name = "com.wyq.voicetodo.qa." + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        let settings = AppSettings(defaults: defaults); settings.speakQuestions = false
        let alerts = QuietNotifications()
        let repository = try Repository(inMemory: true)
        let state = try AppState(repository: repository, settings: settings, notifications: alerts)
        var shown = 0, processingPopups = 0
        state.showOverlay = { shown += 1; if state.phase == .processing { processingPopups += 1 } }
        state.hideOverlay = {}
        state.inputMethod.onBegin?()
        state.inputMethod.onStatus?("等待转写")
        state.inputMethod.onFinished?()
        state.inputMethod.onProblem?("无法读取本次转写")
        state.inputMethod.onEnd?()
        state.enqueueExternal("今天天气真好，我们聊点别的", id: "ordinary")
        XCTAssertEqual(shown, 0)
        XCTAssertTrue(try repository.pending().isEmpty)
        XCTAssertTrue(state.workspace.tasks.isEmpty)

        for (index, text) in ["优化公开项目介绍", "根据GitHub最新内容整体更新GitHub主页",
                              "新增公开项目水口清单（PC端产品，主推）", "土地",
                              "我明天下午三点面试，提醒我一下", "面试完成了", "帮我安排明天面试"].enumerated() {
            state.enqueueExternal(text, id: "ordinary-\(index)", answerID: "untrusted-answer")
        }
        XCTAssertTrue(try repository.pending().isEmpty)
        XCTAssertTrue(state.workspace.tasks.isEmpty)
        XCTAssertEqual(shown, 0)

        state.enqueueExternal("帮我记录一下，我明天有个面试就好了", id: "plan")
        try await finish(state)
        XCTAssertEqual(shown, 1)
        XCTAssertEqual(processingPopups, 0)
        XCTAssertEqual(state.workspace.tasks.first?.title, "面试")
        XCTAssertNotNil(state.workspace.tasks.first?.plannedAt)
        XCTAssertNil(state.workspace.tasks.first?.reminderAt)
        XCTAssertTrue(state.workspace.questions.isEmpty)
        XCTAssertTrue(alerts.tasks.allSatisfy { $0.reminderAt == nil })

        state.enqueueExternal("清单，面试完成了", id: "done")
        try await finish(state)
        XCTAssertEqual(shown, 2)
        XCTAssertEqual(state.workspace.tasks.count, 1)
        XCTAssertTrue(try XCTUnwrap(state.workspace.tasks.first).isCompleted)
        XCTAssertTrue(state.workspace.questions.isEmpty)
    }

    func testPendingQuestionDoesNotAuthorizeOrdinarySpeechAndOldQueueDoesNotAutoRun() async throws {
        let name = "com.wyq.voicetodo.qa." + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        let settings = AppSettings(defaults: defaults); settings.speakQuestions = false
        let repository = try Repository(inMemory: true)
        let legacy = try repository.capture("新增公开项目介绍", questionID: nil, id: "external-legacy", queued: true)
        let state = try AppState(repository: repository, settings: settings, notifications: QuietNotifications())
        var popups = 0
        state.showOverlay = { popups += 1 }
        state.enqueueExternal("提醒我报销", id: "create")
        for _ in 0..<200 where state.busy { try await Task.sleep(for: .milliseconds(10)) }
        XCTAssertEqual(legacy.status, "failed")
        XCTAssertTrue(legacy.issue.contains("没有开头口令"))
        XCTAssertEqual(state.workspace.tasks.map(\.title), ["报销"])
        XCTAssertEqual(popups, 1, "Legacy ordinary speech must not open a popup")
        let question = try XCTUnwrap(state.workspace.questions.first)
        let before = try repository.pending().count
        for text in ["新增一个页面", "明天下午三点", "是的", "面试完成了"] {
            state.enqueueExternal(text, id: UUID().uuidString, answerID: question.id)
        }
        XCTAssertEqual(try repository.pending().count, before)
        XCTAssertEqual(state.workspace.questions.first, question)
        XCTAssertNil(state.workspace.tasks.first?.reminderAt)
        state.enqueueExternal("清单，不用提醒", id: "answer", answerID: question.id)
        try await finish(state)
        XCTAssertTrue(state.workspace.questions.isEmpty)
        XCTAssertEqual(state.workspace.tasks.count, 1)
    }
    private func finish(_ state: AppState) async throws {
        for _ in 0..<100 where state.busy { try await Task.sleep(for: .milliseconds(10)) }
        XCTAssertFalse(state.busy, "Local capture did not finish within one second")
        XCTAssertTrue(state.errorMessage.isEmpty, state.errorMessage)
    }
}
