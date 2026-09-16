import XCTest
@testable import VoiceTodoCore

final class DictationSourceTests: XCTestCase {
    let editor = DictationApplication(pid: 101, bundleID: "test.editor", bundlePath: "/Applications/Editor.app")
    let provider = DictationApplication(pid: 202, bundleID: "com.tencent.inputmethod.wetype", bundlePath: "/Library/Input Methods/WeType.app")
    func testInputMethodFocusDoesNotAbandonOriginalEditor() throws {
        let source = DictationSource(original: editor)
        var capture = ExternalDictationCapture(baseline: "", selection: .init(location: 0, length: 0), clipboardCount: 10)
        XCTAssertEqual(source.route(editor), .original)
        XCTAssertEqual(source.route(provider), .inputMethod)
        capture.observeClipboard(changeCount: 10, at: 1) { XCTFail("Must not read old clipboard"); return nil }
        capture.observeClipboard(changeCount: 11, at: 2) { "帮我记录一下，我明天有个面试就好了" }
        capture.end(at: 3)
        XCTAssertEqual(source.route(editor), .original)
        guard case .command(let text, .clipboard) = capture.result(at: 5) else { return XCTFail("Provider-to-editor handoff lost its capture") }
        let now = Dates.parse("2026-09-16T10:00:00+08:00")!
        let p = try XCTUnwrap(LocalInterpreter.interpret(text, workspace: .init(), question: nil, now: now, timeZone: "Asia/Shanghai"))
        let result = try TaskReducer.apply(p, to: .init(), inputID: capture.id, input: text, now: now)
        XCTAssertEqual(result.workspace.tasks.first?.title, "面试")
        XCTAssertNil(result.workspace.tasks.first?.reminderAt)
        XCTAssertEqual(capture.result(at: 7), .waiting)
    }
    func testOrdinaryApplicationSwitchStillEndsSession() {
        let source = DictationSource(original: editor)
        let other = DictationApplication(pid: 303, bundleID: "test.other", bundlePath: "/Applications/Other.app")
        XCTAssertEqual(source.route(other), .otherApplication)
        XCTAssertEqual(source.route(nil), .otherApplication)
        XCTAssertEqual(source.original, editor)
    }
    func testLateFnCallbackUsesRememberedEditorWhenProviderAlreadyFront() {
        XCTAssertEqual(DictationSource.initial(foreground: provider, previousEditor: editor), editor)
        XCTAssertNil(DictationSource.initial(foreground: provider, previousEditor: nil))
        XCTAssertEqual(DictationSource.initial(foreground: editor, previousEditor: nil), editor)
    }
    func testSettingsWindowsAndMatchingNamesAreNotInputMethods() {
        XCTAssertFalse(DictationApplication(pid: 1, bundleID: provider.bundleID, bundlePath: "/Applications/WeType.app").isInputMethod)
        XCTAssertFalse(DictationApplication(pid: 1, bundleID: "test.settings", bundlePath: "/Library/Input Methods/WeType.app/Contents/MacOS/WeTypeSettings.app").isInputMethod)
        XCTAssertFalse(DictationApplication(pid: 1, bundleID: "test", bundlePath: "").isInputMethod)
        XCTAssertTrue(provider.isInputMethod)
    }
}
