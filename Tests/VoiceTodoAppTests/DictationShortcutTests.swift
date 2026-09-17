import AppKit
import XCTest
@testable import VoiceTodoApp

@MainActor final class DictationShortcutTests: XCTestCase {
    private let command = NSEvent.ModifierFlags.command.rawValue
    private let shift = NSEvent.ModifierFlags.shift.rawValue
    private let fn = NSEvent.ModifierFlags.function.rawValue
    private var combo: DictationShortcut { .init(keyCode: 40, modifiers: command | shift, keyLabel: "K") }
    private func listener(_ shortcut: DictationShortcut) -> GlobalHotkey {
        let key = GlobalHotkey(); key.useInputMethod = true; key.dictationShortcut = shortcut
        return key
    }
    func testCombinationReleaseOrdersRepeatAndNewPress() {
        for modifierFirst in [false, true] {
            let key = listener(combo); var events: [String] = []
            key.onFnPress = { events.append("press") }; key.onFnRelease = { events.append("release") }
            key.onExternalCancel = { events.append("cancel") }
            key.handle(.flagsChanged, code: 55, flags: command)
            key.handle(.flagsChanged, code: 56, flags: command | shift)
            XCTAssertTrue(events.isEmpty)
            key.handle(.keyDown, code: 40, flags: command | shift)
            key.handle(.keyDown, code: 40, flags: command | shift)
            if modifierFirst {
                key.handle(.flagsChanged, code: 56, flags: command)
                key.handle(.flagsChanged, code: 56, flags: command | shift)
            }
            key.handle(.keyUp, code: 40, flags: command | shift)
            XCTAssertEqual(events, ["press", "release"])
            key.handle(.keyDown, code: 40, flags: command | shift)
            key.handle(.keyUp, code: 40, flags: command | shift)
            XCTAssertEqual(events, ["press", "release", "press", "release"])
        }
    }
    func testExtraKeysCancelAndCannotSubmitPartialCapture() {
        let key = listener(combo); var presses = 0, releases = 0, cancellations = 0
        key.onFnPress = { presses += 1 }; key.onFnRelease = { releases += 1 }; key.onExternalCancel = { cancellations += 1 }
        key.handle(.keyDown, code: 40, flags: command | shift)
        key.handle(.keyDown, code: 0, flags: command | shift)
        key.handle(.keyUp, code: 0, flags: command | shift)
        key.handle(.keyUp, code: 40, flags: command | shift)
        XCTAssertEqual(presses, 1); XCTAssertEqual(releases, 0); XCTAssertEqual(cancellations, 1)
        key.handle(.keyDown, code: 40, flags: command | shift)
        key.handle(.keyDown, code: 53, flags: command | shift)
        key.handle(.keyUp, code: 53, flags: command | shift)
        key.handle(.keyUp, code: 40, flags: command | shift)
        XCTAssertEqual(releases, 0); XCTAssertEqual(cancellations, 2)
        key.handle(.keyDown, code: 40, flags: command | shift)
        key.handle(.keyUp, code: 40, flags: command | shift)
        XCTAssertEqual(presses, 3); XCTAssertEqual(releases, 1)
    }
    func testRightModifierOnlyAndOppositeSideChord() {
        let key = listener(.init(keyCode: 61, modifiers: 0, keyLabel: "右侧 ⌥"))
        let option = NSEvent.ModifierFlags.option.rawValue
        var presses = 0, releases = 0, cancellations = 0
        key.onFnPress = { presses += 1 }; key.onFnRelease = { releases += 1 }; key.onExternalCancel = { cancellations += 1 }
        key.handle(.flagsChanged, code: 58, flags: option | 0x20)
        key.handle(.flagsChanged, code: 58, flags: 0)
        XCTAssertEqual(presses, 0)
        key.handle(.flagsChanged, code: 61, flags: option | 0x40)
        key.handle(.flagsChanged, code: 58, flags: option | 0x60)
        key.handle(.flagsChanged, code: 58, flags: option | 0x40)
        key.handle(.flagsChanged, code: 61, flags: 0)
        XCTAssertEqual(releases, 0); XCTAssertEqual(cancellations, 1)
        key.handle(.flagsChanged, code: 61, flags: option | 0x40)
        key.handle(.flagsChanged, code: 61, flags: 0)
        XCTAssertEqual(presses, 2); XCTAssertEqual(releases, 1)
    }
    func testModifierOnlyCombinationWorksInEitherPressOrder() {
        for fnFirst in [false, true] {
            let key = listener(.init(keyCode: 55, modifiers: fn, keyLabel: "左侧 ⌘"))
            var presses = 0, releases = 0
            key.onFnPress = { presses += 1 }; key.onFnRelease = { releases += 1 }
            key.handle(.flagsChanged, code: fnFirst ? 63 : 55, flags: fnFirst ? fn : command)
            XCTAssertEqual(presses, 0)
            key.handle(.flagsChanged, code: fnFirst ? 55 : 63, flags: fn | command)
            key.handle(.flagsChanged, code: 63, flags: command)
            key.handle(.flagsChanged, code: 55, flags: 0)
            XCTAssertEqual(presses, 1); XCTAssertEqual(releases, 1)
        }
    }
    func testFunctionKeyFlagDoesNotRequirePhysicalFnButFnComboDoes() {
        let shortcut = DictationShortcut(keyCode: 109, modifiers: 0, keyLabel: "F10")
        let key = listener(shortcut); var presses = 0, releases = 0
        key.onFnPress = { presses += 1 }; key.onFnRelease = { releases += 1 }
        key.handle(.keyDown, code: 109, flags: fn); key.handle(.keyUp, code: 109, flags: fn)
        XCTAssertEqual(presses, 1); XCTAssertEqual(releases, 1)
        key.dictationShortcut = .init(keyCode: 40, modifiers: fn, keyLabel: "K")
        key.handle(.keyDown, code: 40, flags: fn); key.handle(.keyUp, code: 40, flags: fn)
        XCTAssertEqual(presses, 1)
        key.handle(.flagsChanged, code: 63, flags: fn)
        key.handle(.keyDown, code: 40, flags: fn); key.handle(.keyUp, code: 40, flags: fn)
        key.handle(.flagsChanged, code: 63, flags: 0)
        XCTAssertEqual(presses, 2); XCTAssertEqual(releases, 2)
    }
    func testRecordingSuspendsCommandsAndResetDropsOrphanRelease() {
        let key = listener(combo); var presses = 0, releases = 0
        key.onFnPress = { presses += 1 }; key.onFnRelease = { releases += 1 }
        key.recordingShortcut = true
        key.handle(.keyDown, code: 40, flags: command | shift)
        key.handle(.keyUp, code: 40, flags: command | shift)
        XCTAssertEqual(presses, 0)
        key.recordingShortcut = false
        key.handle(.keyDown, code: 40, flags: command | shift)
        key.reset(clearHeldKeys: true)
        key.handle(.keyUp, code: 40, flags: command | shift)
        XCTAssertEqual(presses, 1); XCTAssertEqual(releases, 0)
        key.dictationShortcut = .fn
        key.handle(.flagsChanged, code: 63, flags: fn); key.handle(.flagsChanged, code: 63, flags: 0)
        XCTAssertEqual(presses, 2); XCTAssertEqual(releases, 1)
    }
    func testSettingsPersistAndInvalidStoredBindingFallsBackToFn() throws {
        let name = "shortcut-test-" + UUID().uuidString, defaults = try XCTUnwrap(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        XCTAssertEqual(AppSettings(defaults: defaults).dictationShortcut, .fn)
        AppSettings(defaults: defaults).dictationShortcut = combo
        XCTAssertEqual(AppSettings(defaults: defaults).dictationShortcut, combo)
        let invalid = DictationShortcut(keyCode: 53, modifiers: 0, keyLabel: "Esc")
        defaults.set(try JSONEncoder().encode(invalid), forKey: "inputMethod.shortcut")
        XCTAssertEqual(AppSettings(defaults: defaults).dictationShortcut, .fn)
        defaults.set(Data("broken".utf8), forKey: "inputMethod.shortcut")
        XCTAssertEqual(AppSettings(defaults: defaults).dictationShortcut, .fn)
    }
    func testAutoRepeatAfterResetOrShortcutRecordingCannotStartAgain() {
        let key = listener(combo); var presses = 0, releases = 0
        key.onFnPress = { presses += 1 }; key.onFnRelease = { releases += 1 }
        key.receive(.keyDown, code: 40, flags: command | shift, timestamp: 10)
        key.reset(clearHeldKeys: true)
        key.receive(.keyDown, code: 40, flags: command | shift, timestamp: 11, isRepeat: true)
        key.receive(.keyUp, code: 40, flags: command | shift, timestamp: 12)
        XCTAssertEqual(presses, 1); XCTAssertEqual(releases, 0)
        key.recordingShortcut = true
        key.receive(.keyDown, code: 40, flags: command | shift, timestamp: 13)
        key.recordingShortcut = false
        key.receive(.keyDown, code: 40, flags: command | shift, timestamp: 14, source: .localMonitor, isRepeat: true)
        XCTAssertEqual(presses, 1)
        key.receive(.keyUp, code: 40, flags: command | shift, timestamp: 15)
        key.receive(.keyDown, code: 40, flags: command | shift, timestamp: 16)
        key.receive(.keyUp, code: 40, flags: command | shift, timestamp: 17)
        XCTAssertEqual(presses, 2); XCTAssertEqual(releases, 1)
    }
    func testRecorderWaitsForReleaseAndRecordsFunctionKeysWithoutFalseFn() throws {
        var recorder = ShortcutRecording()
        func event(_ type: NSEvent.EventType, _ code: UInt16, _ flags: UInt, _ chars: String = "") throws -> NSEvent {
            try XCTUnwrap(NSEvent.keyEvent(with: type, location: .zero, modifierFlags: .init(rawValue: flags), timestamp: 1,
                windowNumber: 0, context: nil, characters: chars, charactersIgnoringModifiers: chars, isARepeat: false, keyCode: code))
        }
        XCTAssertNil(recorder.receive(try event(.flagsChanged, 55, command)))
        XCTAssertNil(recorder.receive(try event(.flagsChanged, 56, command | shift)))
        XCTAssertNil(recorder.receive(try event(.keyDown, 40, command | shift, "K")))
        XCTAssertNil(recorder.receive(try event(.flagsChanged, 56, command)))
        XCTAssertNil(recorder.receive(try event(.flagsChanged, 55, 0)))
        XCTAssertEqual(recorder.receive(try event(.keyUp, 40, 0, "K")), combo)
        XCTAssertNil(recorder.receive(try event(.keyDown, 109, fn)))
        XCTAssertEqual(recorder.receive(try event(.keyUp, 109, fn))?.label, "F10")
        XCTAssertNil(recorder.receive(try event(.flagsChanged, 63, fn)))
        XCTAssertEqual(recorder.receive(try event(.flagsChanged, 63, 0)), .fn)
    }
}
