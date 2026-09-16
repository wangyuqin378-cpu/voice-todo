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

        state.enqueueExternal("帮我安排，我明天有个面试就好了", id: "plan")
        try await finish(state)
        XCTAssertEqual(shown, 1)
        XCTAssertEqual(processingPopups, 0)
        XCTAssertEqual(state.workspace.tasks.first?.title, "面试")
        XCTAssertNotNil(state.workspace.tasks.first?.plannedAt)
        XCTAssertNil(state.workspace.tasks.first?.reminderAt)
        XCTAssertTrue(state.workspace.questions.isEmpty)
        XCTAssertTrue(alerts.tasks.allSatisfy { $0.reminderAt == nil })

        state.enqueueExternal("面试完成了", id: "done")
        try await finish(state)
        XCTAssertEqual(shown, 2)
        XCTAssertEqual(state.workspace.tasks.count, 1)
        XCTAssertTrue(try XCTUnwrap(state.workspace.tasks.first).isCompleted)
        XCTAssertTrue(state.workspace.questions.isEmpty)
    }
    private func finish(_ state: AppState) async throws {
        for _ in 0..<100 where state.busy { try await Task.sleep(for: .milliseconds(10)) }
        XCTAssertFalse(state.busy, "Local capture did not finish within one second")
        XCTAssertTrue(state.errorMessage.isEmpty, state.errorMessage)
    }
}
