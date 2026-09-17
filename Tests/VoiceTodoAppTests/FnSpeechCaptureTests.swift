import XCTest
import AVFoundation
import UserNotifications
import VoiceTodoCore
@testable import VoiceTodoApp

@MainActor private final class FakeFnSpeech: SpeechRecognizing {
    var text = ""
    var onFailure: ((String) -> Void)?
    var starts = 0, stops = 0, finishes = 0, cancellations = 0
    var holdStart = false, holdFinish = false
    var startup: CheckedContinuation<Void, Never>?
    var ending: CheckedContinuation<String, Never>?
    func start() async throws {
        starts += 1
        if holdStart { await withCheckedContinuation { startup = $0 } }
    }
    func stopInput() { stops += 1 }
    func finish() async throws -> String {
        finishes += 1
        if holdFinish { return await withCheckedContinuation { ending = $0 } }
        return text
    }
    func cancel() { cancellations += 1; text = "" }
}

@MainActor private final class FnNotifications: TaskNotifications {
    var onStatus: ((String?) -> Void)?
    var onOpen: (() -> Void)?
    var tasks: [TodoItem] = []
    func requestPermission() async -> Bool { false }
    func authorization() async -> UNAuthorizationStatus { .denied }
    func reconcile(_ tasks: [TodoItem]) async { self.tasks = tasks }
}

@MainActor final class FnSpeechCaptureTests: XCTestCase {
    private func settle(_ condition: () -> Bool) async throws {
        for _ in 0..<200 {
            if condition() { return }
            try await Task.sleep(for: .milliseconds(5))
        }
        XCTFail("Capture did not settle")
    }
    func testPrefixedCapturePersistsConfiguredLeadAndDoesNotChangeOldTask() async throws {
        let name = "com.wyq.voicetodo.qa." + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        let settings = AppSettings(defaults: defaults)
        XCTAssertEqual(settings.defaultReminderLeadMinutes, 10)
        settings.defaultReminderLeadMinutes = 30
        XCTAssertEqual(AppSettings(defaults: defaults).defaultReminderLeadMinutes, 30)
        settings.fnLocalSpeech = true; settings.speakQuestions = false
        let repository = try Repository(inMemory: true), notifications = FnNotifications()
        let old = TodoItem(title: "面试", reminderAt: Date.now.addingTimeInterval(86400))
        try repository.save(.init(tasks: [old]))
        let speech = FakeFnSpeech(); var time = 0.0
        let capture = FnSpeechCapture(speech: speech, now: { time })
        let state = try AppState(repository: repository, settings: settings, notifications: notifications, fnSpeechCapture: capture, aiKeyReader: { "" })
        state.hotkey.useInputMethod = true
        func say(_ input: String) async throws {
            let before = speech.starts
            state.hotkey.handle(.flagsChanged, code: 63, flags: NSEvent.ModifierFlags.function.rawValue)
            try await settle { speech.starts == before + 1 }
            speech.text = input; time += 1
            state.hotkey.handle(.flagsChanged, code: 63, flags: 0)
            try await settle { !capture.active && !state.busy }
            XCTAssertTrue(state.errorMessage.isEmpty, state.errorMessage)
            time += 1
        }
        try await say("提醒我明天下午一点面试")
        let task = try XCTUnwrap(state.workspace.tasks.last)
        XCTAssertEqual(task.title, "面试")
        XCTAssertEqual(task.plannedAt?.timeIntervalSince(task.reminderAt!), 1800)
        XCTAssertEqual(Calendar.current.component(.hour, from: task.plannedAt!), 13)
        XCTAssertEqual(state.workspace.tasks.first, old)
        try await say("帮我记录一下，我10月1号要买车票，提醒我一下")
        XCTAssertEqual(state.workspace.tasks.last?.title, "买车票")
        XCTAssertEqual(Calendar.current.component(.month, from: state.workspace.tasks.last!.reminderAt!), 10)
        XCTAssertEqual(Calendar.current.component(.day, from: state.workspace.tasks.last!.reminderAt!), 1)
        XCTAssertEqual(Calendar.current.component(.hour, from: state.workspace.tasks.last!.reminderAt!), 9)
        try await settle { notifications.tasks.count == 3 }
        XCTAssertEqual(try repository.load().tasks, state.workspace.tasks)
        XCTAssertTrue(try repository.pending().isEmpty)
        let plans = ReminderPlanner.plans(tasks: notifications.tasks, delivered: [], scheduled: [], now: .now)
        XCTAssertEqual(plans.first { $0.taskID == task.id }?.fireAt, task.reminderAt)
    }
    func testTapStartTapEndDeliversOnlyFinalTextOnce() async throws {
        let speech = FakeFnSpeech(); var time = 0.0
        let capture = FnSpeechCapture(speech: speech, now: { time })
        var delivered: [String] = []
        capture.onCommand = { words, _, _ in delivered.append(words) }
        capture.press(); try await settle { speech.starts == 1 }
        time = 0.1; capture.release()
        XCTAssertTrue(capture.active); XCTAssertEqual(speech.stops, 0)
        speech.text = "材料交好了"
        XCTAssertTrue(delivered.isEmpty)
        speech.text = "材料还没交"
        time = 2; capture.press(); time = 2.1; capture.release(); capture.release()
        try await settle { !capture.active }
        XCTAssertEqual(speech.stops, 1); XCTAssertEqual(speech.finishes, 1)
        XCTAssertFalse(delivered.contains("材料交好了"))
        XCTAssertTrue(speech.text.isEmpty)
    }
    func testFnModifierChordCannotSavePartialTaskAndNextNormalPressWorks() async throws {
        let name = "com.wyq.voicetodo.qa." + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        let settings = AppSettings(defaults: defaults); settings.speakQuestions = false
        let repository = try Repository(inMemory: true)
        let original = TodoItem(title: "交材料")
        try repository.save(.init(tasks: [original]))
        let speech = FakeFnSpeech(); var time = 0.0, keyReads = 0
        let capture = FnSpeechCapture(speech: speech, now: { time })
        let state = try AppState(repository: repository, settings: settings, notifications: FnNotifications(),
            fnSpeechCapture: capture, aiKeyReader: { keyReads += 1; return "" })
        state.hotkey.useInputMethod = true
        var popups = 0
        state.showOverlay = { popups += 1 }
        let fn = NSEvent.ModifierFlags.function.rawValue
        state.hotkey.handle(.flagsChanged, code: 63, flags: fn)
        try await settle { capture.phase == .listening }
        speech.text = "材料交好了"
        state.hotkey.handle(.flagsChanged, code: 55, flags: fn | NSEvent.ModifierFlags.command.rawValue)
        XCTAssertFalse(capture.active)
        XCTAssertTrue(speech.text.isEmpty)
        state.hotkey.handle(.flagsChanged, code: 55, flags: fn)
        time = 1
        state.hotkey.handle(.flagsChanged, code: 63, flags: 0)
        XCTAssertEqual(speech.finishes, 0)
        XCTAssertEqual(state.workspace.tasks, [original])
        XCTAssertEqual(try repository.load().tasks, [original])
        XCTAssertTrue(try repository.pending().isEmpty)
        XCTAssertEqual(popups, 0); XCTAssertEqual(keyReads, 0)

        time = 2
        state.hotkey.handle(.flagsChanged, code: 63, flags: fn)
        try await settle { capture.phase == .listening }
        speech.text = "材料交好了"; time = 3
        state.hotkey.handle(.flagsChanged, code: 63, flags: 0)
        try await settle { !capture.active && !state.busy }
        XCTAssertTrue(try XCTUnwrap(try repository.load().tasks.first).isCompleted)
        XCTAssertEqual(speech.finishes, 1)
        XCTAssertEqual(keyReads, 0)
    }
    func testReleaseDuringStartupStopsAudioBeforeReadyAndRetainsOpeningWords() async throws {
        let speech = FakeFnSpeech(); speech.holdStart = true; var time = 0.0
        let capture = FnSpeechCapture(speech: speech, now: { time })
        var result = ""
        capture.onCommand = { words, _, _ in result = words }
        capture.press(); try await settle { speech.startup != nil }
        speech.text = "提醒我明天下午六点面试"
        time = 1; capture.release()
        XCTAssertEqual(speech.stops, 1); XCTAssertEqual(speech.finishes, 0)
        speech.startup?.resume(); speech.startup = nil
        try await settle { !capture.active }
        XCTAssertEqual(result, "提醒我明天下午六点面试")
        XCTAssertEqual(speech.finishes, 1)
    }
    func testCancelDiscardsLateFinishAndNextCaptureStillWorks() async throws {
        let speech = FakeFnSpeech(); speech.holdFinish = true; var time = 0.0
        let capture = FnSpeechCapture(speech: speech, now: { time })
        var delivered: [String] = []
        capture.onCommand = { words, _, _ in delivered.append(words) }
        capture.press(); try await settle { speech.starts == 1 }
        time = 1; capture.release(); try await settle { speech.ending != nil }
        let late = speech.ending; speech.ending = nil
        capture.cancel(); speech.holdFinish = false
        time = 2; capture.press(); try await settle { speech.starts == 2 }
        speech.text = "提醒我买牛奶"
        late?.resume(returning: "材料已经交了")
        time = 3; capture.release(); try await settle { !capture.active }
        XCTAssertEqual(delivered, ["提醒我买牛奶"])
    }
    func testNoAudioStartsAfterCancelledOrAlreadyEndedGesture() async throws {
        let speech = FakeFnSpeech(); var time = 0.0
        let capture = FnSpeechCapture(speech: speech, now: { time })
        capture.press(); capture.cancel()
        time = 2; capture.press(); time = 3; capture.release()
        try await settle { !capture.active }
        XCTAssertEqual(speech.starts, 0)
    }
    func testActualAppFnRouteQuietThenCreateReplyCompleteUndo() async throws {
        let name = "com.wyq.voicetodo.qa." + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        let settings = AppSettings(defaults: defaults)
        settings.fnLocalSpeech = true; settings.speakQuestions = false
        let repository = try Repository(inMemory: true), notifications = FnNotifications()
        let speech = FakeFnSpeech(); var time = 0.0
        let capture = FnSpeechCapture(speech: speech, now: { time })
        let state = try AppState(repository: repository, settings: settings, notifications: notifications, fnSpeechCapture: capture, aiKeyReader: { "" })
        var popups = 0, legacyBegins = 0
        state.showOverlay = { popups += 1 }
        state.inputMethod.onBegin = { legacyBegins += 1 }
        state.hotkey.useInputMethod = true
        state.hotkey.handle(.flagsChanged, code: 63, flags: NSEvent.ModifierFlags.function.rawValue)
        try await settle { speech.starts == 1 }
        speech.text = "报销好了"
        state.hotkey.handle(.keyDown, code: 53, flags: 0)
        state.hotkey.handle(.keyUp, code: 53, flags: 0)
        state.hotkey.handle(.flagsChanged, code: 63, flags: 0)
        XCTAssertFalse(capture.active); XCTAssertTrue(speech.text.isEmpty)
        XCTAssertTrue(try repository.pending().isEmpty); XCTAssertEqual(popups, 0)
        func say(_ words: String) async throws {
            let before = speech.starts
            state.hotkey.handle(.flagsChanged, code: 63, flags: NSEvent.ModifierFlags.function.rawValue)
            try await settle { speech.starts == before + 1 }
            speech.text = words
            time += 1
            state.hotkey.handle(.flagsChanged, code: 63, flags: 0)
            try await settle { !capture.active && !state.busy }
            XCTAssertTrue(state.errorMessage.isEmpty, state.errorMessage)
            time += 1
        }
        for text in ["今天天气真好，我们聊点别的", "优化公开项目介绍", "新增公开项目水口清单（PC端产品，主推）", "土地", "新增一个按钮"] {
            try await say(text)
        }
        XCTAssertEqual(popups, 0); XCTAssertTrue(try repository.pending().isEmpty)
        try await say("提醒我报销")
        XCTAssertEqual(state.workspace.tasks.count, 1); XCTAssertTrue(state.awaitingFnReply)
        let questionBefore = state.workspace.questions.first
        XCTAssertEqual(state.workspace.questions.first, questionBefore)
        XCTAssertEqual(state.workspace.tasks.count, 1)
        XCTAssertNil(state.workspace.tasks.first?.reminderAt)
        try await say("明天下午六点")
        XCTAssertTrue(state.workspace.questions.isEmpty)
        let reminder = try XCTUnwrap(state.workspace.tasks.first?.reminderAt)
        XCTAssertEqual(Calendar.current.component(.hour, from: reminder), 18)
        try await say("报销好了")
        XCTAssertEqual(state.workspace.tasks.count, 1)
        XCTAssertTrue(try XCTUnwrap(state.workspace.tasks.first).isCompleted)
        XCTAssertTrue(ReminderPlanner.plans(tasks: state.workspace.tasks, delivered: [], scheduled: [], now: .now).isEmpty)
        try await say("清单，撤销")
        XCTAssertFalse(try XCTUnwrap(state.workspace.tasks.first).isCompleted)
        XCTAssertEqual(state.workspace.tasks.first?.reminderAt, reminder)
        XCTAssertEqual(popups, 4); XCTAssertEqual(legacyBegins, 0)
        XCTAssertTrue(speech.text.isEmpty)
        try await say("清单，帮我取消报销")
        XCTAssertTrue(state.workspace.tasks.isEmpty)
        XCTAssertTrue(try repository.load().tasks.isEmpty)
        XCTAssertTrue(notifications.tasks.isEmpty)
        XCTAssertTrue(state.message.contains("已取消"))
        try await say("清单，撤销")
        XCTAssertEqual(state.workspace.tasks.first?.reminderAt, reminder)
        XCTAssertEqual(notifications.tasks.first?.reminderAt, reminder)
        try await say("清单，取消报销的提醒")
        XCTAssertEqual(state.workspace.tasks.count, 1)
        XCTAssertEqual(state.workspace.tasks.first?.reminderAt, reminder)
        XCTAssertEqual(notifications.tasks.first?.reminderAt, reminder)
        XCTAssertTrue(state.message.contains("语音不修改"))
        XCTAssertEqual(popups, 7)
        try await say("提醒我明天下午六点面试")
        XCTAssertEqual(state.workspace.tasks.count, 2)
        try await say("清单，帮我取消明天下午 6 点的面试。")
        XCTAssertEqual(state.workspace.tasks.map(\.title), ["报销"])
        XCTAssertEqual(notifications.tasks.map(\.title), ["报销"])
        XCTAssertEqual(popups, 9)
        state.hotkey.onFnPress?(); try await settle { capture.phase == .listening }
        state.sleep()
        XCTAssertFalse(capture.active)
    }
    func testExpiredReplyDoesNotPersistOrdinarySpeech() async throws {
        let speech = FakeFnSpeech(); var time = 0.0
        let capture = FnSpeechCapture(speech: speech, now: { time })
        var deliveries = 0
        capture.currentQuestionID = { "question" }
        capture.onCommand = { _, id, _ in
            deliveries += 1; capture.awaitReply(to: "question", after: "external-" + id)
        }
        capture.press(); try await settle { speech.starts == 1 }
        speech.text = "提醒我报销"; time = 1; capture.release()
        try await settle { !capture.active }
        XCTAssertTrue(capture.awaitingReply)
        time = 123; XCTAssertFalse(capture.awaitingReply)
        capture.press(); try await settle { speech.starts == 2 }
        speech.text = "随便聊点别的"; time = 124; capture.release()
        try await settle { !capture.active }
        XCTAssertEqual(deliveries, 1)
    }
    func testRecognitionFailureNeverAppliesPartialCompletion() async throws {
        let speech = FakeFnSpeech()
        let subject = FnSpeechCapture(speech: speech)
        var commands = 0, retained = ""
        subject.onCommand = { _, _, _ in commands += 1 }
        subject.onFailure = { words, _, _, _ in retained = words }
        subject.press(); try await settle { speech.starts == 1 }
        speech.text = "清单，材料交好了"; speech.onFailure?("interrupted")
        XCTAssertEqual(commands, 0); XCTAssertEqual(retained, "清单，材料交好了")
        XCTAssertFalse(subject.active); XCTAssertTrue(speech.text.isEmpty)
    }
    func testInterruptedOrdinarySpeechIsNotSavedOrShownEvenDuringAQuestion() async throws {
        let name = "com.wyq.voicetodo.qa." + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        let settings = AppSettings(defaults: defaults)
        settings.speakQuestions = false
        let repository = try Repository(inMemory: true)
        let speech = FakeFnSpeech()
        // Exercise the app callback as well as the recognizer's import boundary.
        let subject = FnSpeechCapture(speech: speech)
        let state = try AppState(repository: repository, settings: settings,
                                 notifications: FnNotifications(), fnSpeechCapture: subject)
        var popups = 0
        state.showOverlay = { popups += 1 }
        subject.currentQuestionID = { "pending-question" }
        for (index, words) in ["新增公开项目介绍", "今天天气真好", "土地"].enumerated() {
            subject.press(); try await settle { speech.starts == index + 1 }
            speech.text = words; speech.onFailure?("识别中断")
            XCTAssertFalse(subject.active)
            XCTAssertTrue(try repository.pending().isEmpty)
            XCTAssertTrue(state.workspace.tasks.isEmpty)
            XCTAssertEqual(popups, 0)
            XCTAssertEqual(state.lastVoiceOutcome, "识别中断")
        }
    }
    func testEarlyAudioIsCopiedInOrderAndBoundedOverflowFails() async throws {
        let format = try XCTUnwrap(AVAudioFormat(standardFormatWithSampleRate: 16000, channels: 1))
        let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 2))
        buffer.frameLength = 2
        let input = SpeechAudioInput(capacity: 2)
        buffer.floatChannelData![0][0] = 0.25; input.append(buffer)
        buffer.floatChannelData![0][0] = 0.75; input.append(buffer)
        buffer.floatChannelData![0][0] = 1; input.finish()
        var samples: [Float] = []
        for try await owned in input.stream { samples.append(owned.pcm.floatChannelData![0][0]) }
        XCTAssertEqual(samples, [0.25, 0.75])
        let overflow = SpeechAudioInput(capacity: 1)
        overflow.append(buffer); overflow.append(buffer)
        do {
            for try await _ in overflow.stream {}
            XCTFail("Overflow must report incomplete audio, never silently lose words")
        } catch { XCTAssertTrue(error.localizedDescription.contains("不完整")) }
    }
}
