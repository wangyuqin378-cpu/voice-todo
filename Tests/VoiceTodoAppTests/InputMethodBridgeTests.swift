import AppKit
import ApplicationServices
import XCTest
import VoiceTodoCore
@testable import VoiceTodoApp

/// AX references are opaque tokens here. All reads are served by this fake;
/// neither live application contents nor the general pasteboard are accessed.
@MainActor private final class DictationDesktop {
    let app = AXUIElementCreateApplication(100_001)
    let window = AXUIElementCreateApplication(100_002)
    let parent = AXUIElementCreateApplication(100_003)
    let original = AXUIElementCreateApplication(100_004)
    let replacement = AXUIElementCreateApplication(100_005)
    let otherWindow = AXUIElementCreateApplication(100_006)
    let button = AXUIElementCreateApplication(100_007)
    var clock: TimeInterval = 0
    var clipboardReads = 0
    var clipboardCount = 10
    var copiedText: String?
    var reads: [(AXUIElement, String)] = []
    var attributes: [CFHashCode: [String: CFTypeRef]] = [:]
    var foreground: DictationApplication? = .init(pid: 100_001, bundleID: "test.editor", bundlePath: "/Applications/Test.app")
    var environment: DictationEnvironment {
        .init(foreground: { self.foreground }, trusted: { true }, now: { self.clock },
              clipboardCount: { self.clipboardCount }, clipboardText: {
                  self.clipboardReads += 1
                  if self.clipboardCount == 10 { XCTFail("Old clipboard read") }
                  return self.copiedText
              },
              application: { _ in self.app }, attribute: { element, key in
                  self.reads.append((element, key)); return self.attributes[CFHash(element)]?[key]
              })
    }
    func set(_ element: AXUIElement, _ key: String, _ value: CFTypeRef?) {
        attributes[CFHash(element), default: [:]][key] = value
    }
    func focus(_ element: AXUIElement) { set(app, kAXFocusedUIElementAttribute, element) }
    func text(_ element: AXUIElement, _ text: String) { set(element, kAXValueAttribute, text as CFString) }
    func field(_ element: AXUIElement, value: String = "", selection: NSRange = .init(location: 0, length: 0), identifier: String? = "composer", x: CGFloat = 20, window: AXUIElement? = nil) {
        set(element, kAXRoleAttribute, kAXTextAreaRole as CFString)
        set(element, kAXWindowAttribute, window ?? self.window)
        set(element, kAXParentAttribute, parent)
        set(element, kAXIdentifierAttribute, identifier.map { $0 as CFString })
        var point = CGPoint(x: x, y: 80)
        set(element, kAXPositionAttribute, AXValueCreate(.cgPoint, &point))
        var range = CFRange(location: selection.location, length: selection.length)
        set(element, kAXSelectedTextRangeAttribute, AXValueCreate(.cfRange, &range))
        text(element, value)
    }
}

@MainActor final class InputMethodBridgeTests: XCTestCase {
    func testSameFnConversationSurvivesEditorRefreshThroughReminderCompletionAndUndo() throws {
        let desktop = DictationDesktop()
        desktop.field(desktop.original); desktop.focus(desktop.original)
        let bridge = InputMethodBridge(environment: desktop.environment, automaticPolling: false)
        let now = try XCTUnwrap(Dates.parse("2026-09-16T02:00:00+08:00"))
        var workspace = Workspace(), received: [String] = [], questionIDs: [String?] = []
        bridge.currentQuestionID = { workspace.questions.first?.id }
        bridge.onCommand = { text, id, questionID in
            received.append(text); questionIDs.append(questionID)
            do {
                let question = workspace.questions.first { $0.id == questionID }
                let proposal = try XCTUnwrap(LocalInterpreter.interpret(text, workspace: workspace, question: question, now: now, timeZone: "Asia/Shanghai"))
                workspace = try TaskReducer.apply(proposal, to: workspace, inputID: "external-" + id, input: text, answering: questionID, now: now).workspace
                bridge.awaitReply(to: workspace.questions.first?.id, after: "external-" + id)
            } catch { XCTFail("\(error)") }
        }
        bridge.press(); desktop.clock = 1; bridge.release()
        desktop.text(desktop.original, "提醒我报销"); bridge.poll()
        desktop.clock = 2.3; bridge.poll()
        let question = try XCTUnwrap(workspace.questions.first)
        XCTAssertTrue(bridge.awaitingReply)
        let baseline = "提醒我报销"
        desktop.field(desktop.replacement, value: baseline, selection: .init(location: baseline.utf16.count, length: 0))
        desktop.focus(desktop.replacement)
        desktop.clock = 3; bridge.press(); desktop.clock = 4; bridge.release()
        desktop.text(desktop.replacement, baseline + "明天下午六点"); bridge.poll()
        desktop.clock = 5.3; bridge.poll()
        XCTAssertEqual(received, ["提醒我报销", "明天下午六点"])
        XCTAssertEqual(questionIDs.last, question.id)
        XCTAssertTrue(workspace.questions.isEmpty)
        let reminder = try XCTUnwrap(Dates.parse("2026-09-17T18:00:00+08:00"))
        XCTAssertEqual(workspace.tasks.first?.reminderAt, reminder)
        guard received.count == 2 else { return }
        let originalPlan = try XCTUnwrap(ReminderPlanner.plans(tasks: workspace.tasks, delivered: [], scheduled: [], now: now).first)
        XCTAssertEqual(originalPlan.fireAt, reminder)
        for (index, text) in ["报销好了", "撤销"].enumerated() {
            desktop.field(desktop.replacement); desktop.focus(desktop.replacement)
            desktop.clock = Double(7 + index * 4); bridge.press()
            desktop.clock += 1; bridge.release(); desktop.text(desktop.replacement, text); bridge.poll()
            desktop.clock += 1.3; bridge.poll()
            XCTAssertEqual(workspace.tasks.count, 1)
            XCTAssertEqual(workspace.tasks.first?.isCompleted, index == 0)
            let plans = ReminderPlanner.plans(tasks: workspace.tasks, delivered: [originalPlan.identifier], scheduled: [], now: now)
            if index == 0 { XCTAssertTrue(plans.isEmpty) }
            else {
                XCTAssertEqual(plans.count, 1)
                XCTAssertEqual(plans.first?.fireAt, reminder)
                XCTAssertNotEqual(plans.first?.identifier, originalPlan.identifier)
            }
        }
        XCTAssertEqual(received, ["提醒我报销", "明天下午六点", "报销好了", "撤销"])
    }
    func testRefreshMatchingCannotTransferQuestionToAnotherEditorOrExpiredConversation() {
        for scenario in 0..<3 {
            let desktop = DictationDesktop()
            desktop.field(desktop.original); desktop.focus(desktop.original)
            let bridge = InputMethodBridge(environment: desktop.environment, automaticPolling: false)
            var received: [String] = []
            bridge.currentQuestionID = { "q" }
            bridge.onCommand = { text, id, questionID in
                received.append(text)
                XCTAssertNil(questionID, "Unrelated input inherited a question")
                if received.count == 1 { bridge.awaitReply(to: "q", after: "external-" + id) }
            }
            bridge.press(); desktop.clock = 1; bridge.release()
            desktop.text(desktop.original, "提醒我报销"); bridge.poll()
            desktop.clock = 2.3; bridge.poll(); XCTAssertTrue(bridge.awaitingReply)
            desktop.field(desktop.replacement, identifier: scenario == 0 ? "other-editor" : "composer",
                          window: scenario == 1 ? desktop.otherWindow : desktop.window)
            desktop.focus(desktop.replacement)
            desktop.clock = scenario == 2 ? 123 : 3; bridge.press()
            desktop.clock += 1; bridge.release()
            desktop.text(desktop.replacement, "记得买牛奶"); bridge.poll()
            desktop.clock += 1.3; bridge.poll()
            XCTAssertEqual(received, ["提醒我报销", "记得买牛奶"])
        }
    }
    func testReportedInterviewUtteranceThroughObservedClipboardRoutePersistsExactTime() throws {
        try checkReportedInterviewUtterance(intermediate: nil)
    }
    func testLateReportedInterviewUtteranceSurvivesOrdinarySnapshotAndPersistsOnce() throws {
        try checkReportedInterviewUtterance(intermediate: "正在转写…")
    }
    private func checkReportedInterviewUtterance(intermediate: String?) throws {
        let utterance = "提醒我明天下午 6 点面试。"
        let now = try XCTUnwrap(Dates.parse("2026-09-16T02:00:00+08:00"))
        let expected = try XCTUnwrap(Dates.parse("2026-09-17T17:50:00+08:00"))
        XCTAssertTrue(CommandText.accepts(utterance))
        let desktop = DictationDesktop()
        desktop.field(desktop.original, value: "原有草稿", selection: .init(location: 4, length: 0))
        desktop.focus(desktop.original)
        let bridge = InputMethodBridge(environment: desktop.environment, automaticPolling: false)
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: folder) }
        let diagnostics = CaptureDiagnostics(url: folder.appendingPathComponent("capture.json"))
        bridge.diagnostics = diagnostics
        let repository = try Repository(inMemory: true)
        var delivered = 0
        bridge.onCommand = { text, id, question in
            delivered += 1
            XCTAssertEqual(text, utterance)
            do {
                let input = try repository.capture(text, questionID: question, now: now, timeZone: "Asia/Shanghai", id: "external-" + id, queued: true)
                let proposal = try XCTUnwrap(LocalInterpreter.interpret(text, workspace: repository.load(), question: nil, now: now, timeZone: "Asia/Shanghai"))
                let result = try TaskReducer.apply(proposal, to: repository.load(), inputID: input.id, input: text, now: now)
                try repository.save(result.workspace, capture: input)
            } catch { XCTFail("\(error)") }
        }
        bridge.press()
        desktop.clock = 3; desktop.text(desktop.original, "临时内容"); bridge.poll()
        desktop.clock = 35; bridge.release()
        desktop.clock = 37; desktop.clipboardCount = 11; desktop.copiedText = intermediate ?? utterance; bridge.poll()
        desktop.clock = 37.5
        desktop.set(desktop.button, kAXRoleAttribute, kAXButtonRole as CFString)
        desktop.set(desktop.button, kAXWindowAttribute, desktop.window)
        desktop.focus(desktop.button); desktop.set(desktop.original, kAXValueAttribute, nil); bridge.poll()
        desktop.clock = 38.3; bridge.poll(); bridge.poll()
        if intermediate != nil {
            XCTAssertEqual(delivered, 0)
            XCTAssertTrue(bridge.active)
            XCTAssertEqual(diagnostics.sessions.last?.events.last?.stage, .clipboardOrdinaryPending)
            desktop.clock = 41; desktop.copiedText = utterance; bridge.poll()
            desktop.clock = 42.1; bridge.poll(); XCTAssertEqual(delivered, 0)
            desktop.clock = 42.3; bridge.poll(); bridge.poll()
        }
        XCTAssertEqual(delivered, 1)
        XCTAssertFalse(bridge.active)
        let task = try XCTUnwrap(repository.load().tasks.first)
        XCTAssertEqual(task.title, "面试")
        XCTAssertEqual(task.reminderAt, expected)
        XCTAssertEqual(task.plannedAt, expected.addingTimeInterval(600))
        XCTAssertFalse(task.isCompleted)
        XCTAssertTrue(try repository.pending().isEmpty)
        let events = try XCTUnwrap(diagnostics.sessions.last).events
        XCTAssertTrue(events.contains { $0.stage == .clipboardCommandReceived })
        XCTAssertEqual(events.filter { $0.stage == .commandReceived }.count, 1)
    }
    func testRefreshedFieldDeliversFinalTextAndCompletesExactlyOnce() throws {
        let desktop = DictationDesktop()
        desktop.field(desktop.original); desktop.focus(desktop.original)
        let bridge = InputMethodBridge(environment: desktop.environment, automaticPolling: false)
        var texts: [String] = [], workspace = Workspace()
        bridge.onCommand = { text, id, question in
            texts.append(text)
            do {
                let proposal = try XCTUnwrap(LocalInterpreter.interpret(text, workspace: workspace, question: nil, now: .now, timeZone: "Asia/Shanghai"))
                workspace = try TaskReducer.apply(proposal, to: workspace, inputID: id, input: text).workspace
            } catch { XCTFail("\(error)") }
        }
        bridge.press()
        desktop.clock = 1; desktop.text(desktop.original, "帮我安排"); bridge.poll()
        desktop.clock = 2; bridge.release()
        desktop.clock = 3
        desktop.field(desktop.replacement, value: "帮我安排，我明天有个面试就好了", x: 25)
        desktop.focus(desktop.replacement)
        desktop.set(desktop.original, kAXValueAttribute, nil) // original AX object is retired
        bridge.poll()
        XCTAssertTrue(bridge.active); XCTAssertTrue(texts.isEmpty)
        desktop.clock = 4.1; bridge.poll(); XCTAssertTrue(texts.isEmpty)
        desktop.clock = 4.3; bridge.poll(); bridge.poll()
        XCTAssertEqual(texts, ["帮我安排，我明天有个面试就好了"])
        XCTAssertFalse(bridge.active)
        XCTAssertEqual(workspace.tasks.count, 1)
        XCTAssertEqual(workspace.tasks.first?.title, "面试")
        XCTAssertNil(workspace.tasks.first?.reminderAt)

        desktop.clock = 6; bridge.press()
        desktop.clock = 7; bridge.release()
        desktop.text(desktop.replacement, "面试完成了帮我安排，我明天有个面试就好了")
        bridge.poll()
        desktop.clock = 8.3; bridge.poll(); bridge.poll()
        XCTAssertEqual(texts.last, "面试完成了")
        XCTAssertEqual(workspace.tasks.count, 1)
        XCTAssertTrue(try XCTUnwrap(workspace.tasks.first).isCompleted)
        XCTAssertEqual(desktop.clipboardReads, 0)
    }

    func testParentAndPositionCanIdentifyRefreshedEditorWithoutIdentifier() {
        let desktop = DictationDesktop()
        desktop.field(desktop.original, identifier: nil); desktop.focus(desktop.original)
        let bridge = InputMethodBridge(environment: desktop.environment, automaticPolling: false)
        var delivered: [String] = []; bridge.onCommand = { text, _, _ in delivered.append(text) }
        bridge.press(); desktop.clock = 1; bridge.release()
        desktop.field(desktop.replacement, value: "记得买牛奶", identifier: nil)
        desktop.focus(desktop.replacement); bridge.poll()
        desktop.clock = 2.3; bridge.poll()
        XCTAssertEqual(delivered, ["记得买牛奶"])
    }

    func testDifferentEditorOrWindowCannotSupplyTextEvenWithIdenticalContent() {
        for scenario in 0..<3 {
            let desktop = DictationDesktop()
            desktop.field(desktop.original, identifier: scenario == 1 ? nil : "composer")
            desktop.focus(desktop.original)
            let bridge = InputMethodBridge(environment: desktop.environment, automaticPolling: false)
            bridge.onCommand = { _, _, _ in XCTFail("Read a different destination") }
            bridge.press(); desktop.clock = 1; bridge.release()
            desktop.field(desktop.replacement, value: "记得买牛奶", identifier: scenario == 1 ? nil : (scenario == 0 ? "search" : "composer"), x: scenario == 1 ? 200 : 20, window: scenario == 2 ? desktop.otherWindow : desktop.window)
            desktop.focus(desktop.replacement); bridge.poll()
            XCTAssertFalse(bridge.active)
            XCTAssertFalse(desktop.reads.contains { CFEqual($0.0, desktop.replacement) && $0.1 == kAXValueAttribute })
        }
    }

    func testTransientNonTextFocusKeepsOriginalFieldThenAcceptsCommit() {
        let desktop = DictationDesktop()
        desktop.field(desktop.original); desktop.focus(desktop.original)
        let bridge = InputMethodBridge(environment: desktop.environment, automaticPolling: false)
        var delivered: [String] = []; bridge.onCommand = { text, _, _ in delivered.append(text) }
        bridge.press(); desktop.clock = 1; bridge.release()
        desktop.set(desktop.button, kAXRoleAttribute, kAXButtonRole as CFString)
        desktop.set(desktop.button, kAXWindowAttribute, desktop.window)
        desktop.focus(desktop.button); bridge.poll()
        XCTAssertTrue(bridge.active); XCTAssertTrue(delivered.isEmpty)
        desktop.clock = 2; desktop.text(desktop.original, "记得报销")
        desktop.focus(desktop.original); bridge.poll()
        desktop.clock = 3.3; bridge.poll()
        XCTAssertEqual(delivered, ["记得报销"])
    }

    func testSecureReplacementIsNeverRead() {
        let desktop = DictationDesktop()
        desktop.field(desktop.original); desktop.focus(desktop.original)
        let bridge = InputMethodBridge(environment: desktop.environment, automaticPolling: false)
        bridge.onCommand = { _, _, _ in XCTFail("Secure field received") }
        bridge.press(); desktop.clock = 1; bridge.release()
        desktop.field(desktop.replacement, value: "must not read")
        desktop.set(desktop.replacement, kAXSubroleAttribute, kAXSecureTextFieldSubrole as CFString)
        desktop.focus(desktop.replacement); bridge.poll()
        XCTAssertFalse(bridge.active)
        XCTAssertFalse(desktop.reads.contains { CFEqual($0.0, desktop.replacement) && $0.1 == kAXValueAttribute })
    }

    func testRebindingKeepsOriginalDraftBoundaryAndReportsRejectedContext() throws {
        let desktop = DictationDesktop()
        let baseline = "前文🧪后文"
        desktop.field(desktop.original, value: baseline, selection: .init(location: 4, length: 0))
        desktop.focus(desktop.original)
        let bridge = InputMethodBridge(environment: desktop.environment, automaticPolling: false)
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: folder) }
        let diagnostics = CaptureDiagnostics(url: folder.appendingPathComponent("capture.json")); bridge.diagnostics = diagnostics
        var delivered: [String] = []; bridge.onCommand = { text, _, _ in delivered.append(text) }
        bridge.press(); desktop.clock = 1; bridge.release()
        desktop.field(desktop.replacement, value: "别的草稿记得买牛奶")
        desktop.focus(desktop.replacement); bridge.poll()
        desktop.clock = 2.4; bridge.poll()
        XCTAssertTrue(delivered.isEmpty)
        XCTAssertTrue(diagnostics.sessions.last!.events.contains { $0.stage == .fieldContextChanged })
        desktop.clock = 3; desktop.text(desktop.replacement, "前文🧪记得买牛奶后文"); bridge.poll()
        desktop.clock = 4.3; bridge.poll()
        XCTAssertEqual(delivered, ["记得买牛奶"])
        XCTAssertTrue(diagnostics.sessions.last!.events.contains { $0.stage == .fieldRebound })
        XCTAssertEqual(diagnostics.sessions.last?.events.last?.stage, .commandReceived)
    }

    func testCorrectionAfterRebuildDoesNotCompleteTaskEarly() {
        let desktop = DictationDesktop()
        desktop.field(desktop.original); desktop.focus(desktop.original)
        let bridge = InputMethodBridge(environment: desktop.environment, automaticPolling: false)
        bridge.onCommand = { _, _, _ in XCTFail("Negated completion should be ignored") }
        bridge.press(); desktop.clock = 1; bridge.release()
        desktop.field(desktop.replacement, value: "材料交好了")
        desktop.focus(desktop.replacement); bridge.poll()
        desktop.clock = 2; desktop.text(desktop.replacement, "材料还没交"); bridge.poll()
        desktop.clock = 2.3; bridge.poll(); XCTAssertTrue(bridge.active)
        desktop.clock = 3.3; bridge.poll(); XCTAssertTrue(bridge.active)
        desktop.clock = 21; bridge.poll(); XCTAssertFalse(bridge.active)
    }
}
