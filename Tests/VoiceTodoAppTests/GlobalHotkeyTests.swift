import AppKit
import XCTest
@testable import VoiceTodoApp

@MainActor final class GlobalHotkeyTests: XCTestCase {
    func testReleasingListenerInvalidatesItsSystemTapAndRunLoopSource() {
        var listener: GlobalHotkey? = GlobalHotkey()
        _ = listener?.install()
        // Hold the system handles past the owner to verify actual resource cleanup.
        let tap = listener?.tap, source = listener?.source
        weak var released = listener
        listener = nil
        XCTAssertNil(released)
        if let tap { XCTAssertFalse(CFMachPortIsValid(tap)) }
        if let source { XCTAssertFalse(CFRunLoopContainsSource(CFRunLoopGetMain(), source, .commonModes)) }
    }
    private let option: UInt = NSEvent.ModifierFlags.option.rawValue | 0x40

    func testInputMethodFnIsSeparateFromOwnMicrophoneAndAllowsPasteCommit() {
        let key = GlobalHotkey(); key.useInputMethod = true
        var presses = 0, releases = 0, cancelled = 0, ownRecordings = 0
        key.onFnPress = { presses += 1 }; key.onFnRelease = { releases += 1 }
        key.onExternalCancel = { cancelled += 1 }; key.onTap = { ownRecordings += 1 }
        let fn = NSEvent.ModifierFlags.function.rawValue
        key.receive(.flagsChanged, code: 63, flags: fn, timestamp: 1)
        key.receive(.flagsChanged, code: 63, flags: fn, timestamp: 1)
        key.receive(.flagsChanged, code: 63, flags: 0, timestamp: 2)
        key.handle(.flagsChanged, code: 55, flags: NSEvent.ModifierFlags.command.rawValue)
        key.handle(.keyDown, code: 9, flags: NSEvent.ModifierFlags.command.rawValue)
        key.handle(.keyUp, code: 9, flags: NSEvent.ModifierFlags.command.rawValue)
        key.handle(.flagsChanged, code: 55, flags: 0)
        key.handle(.flagsChanged, code: 61, flags: option)
        key.handle(.flagsChanged, code: 61, flags: 0)
        XCTAssertEqual(presses, 1); XCTAssertEqual(releases, 1)
        XCTAssertEqual(cancelled, 0); XCTAssertEqual(ownRecordings, 0)
        key.handle(.keyDown, code: 53, flags: 0)
        XCTAssertEqual(cancelled, 1)
    }
    func testFnChordAbandonsExternalCapture() {
        let key = GlobalHotkey(); key.useInputMethod = true
        var cancelled = 0
        key.onExternalCancel = { cancelled += 1 }
        key.handle(.flagsChanged, code: 63, flags: NSEvent.ModifierFlags.function.rawValue)
        key.handle(.keyDown, code: 49, flags: NSEvent.ModifierFlags.function.rawValue)
        XCTAssertEqual(cancelled, 1)
    }

    // Feed the application's real event handler directly. No system events,
    // microphone access, permissions, or personal task data are used here.
    func testRightOptionTapReachesActionWithoutPollingUnrelatedKeyStates() {
        let key = GlobalHotkey()
        var taps = 0
        key.onTap = { taps += 1 }
        key.handle(.flagsChanged, code: 61, flags: option)
        key.handle(.flagsChanged, code: 61, flags: 0)
        XCTAssertEqual(taps, 1)
    }

    func testKeyHeldBeforeOptionSuppressesAndReleaseRestoresShortcut() {
        let key = GlobalHotkey()
        var taps = 0
        key.onTap = { taps += 1 }
        key.handle(.keyDown, code: 0, flags: 0)
        key.handle(.flagsChanged, code: 61, flags: option)
        key.handle(.flagsChanged, code: 61, flags: 0)
        XCTAssertEqual(taps, 0)
        key.handle(.keyUp, code: 0, flags: 0)
        key.handle(.flagsChanged, code: 61, flags: option)
        key.handle(.flagsChanged, code: 61, flags: 0)
        XCTAssertEqual(taps, 1)
    }

    func testKeyPressedAfterOptionSuppressesEvenIfLetterReleasesFirst() {
        let key = GlobalHotkey()
        var taps = 0
        key.onTap = { taps += 1 }
        key.handle(.flagsChanged, code: 61, flags: option)
        key.handle(.keyDown, code: 0, flags: option)
        key.handle(.keyUp, code: 0, flags: option)
        key.handle(.flagsChanged, code: 61, flags: 0)
        XCTAssertEqual(taps, 0)
    }

    func testLeftOptionAndFnCombinationsDoNotTrigger() {
        let key = GlobalHotkey()
        var taps = 0
        key.onTap = { taps += 1 }
        key.handle(.flagsChanged, code: 58, flags: NSEvent.ModifierFlags.option.rawValue | 0x20)
        key.handle(.flagsChanged, code: 61, flags: option | 0x20)
        key.handle(.flagsChanged, code: 61, flags: 0x20)
        key.handle(.flagsChanged, code: 58, flags: 0)
        key.handle(.flagsChanged, code: 61, flags: option | NSEvent.ModifierFlags.function.rawValue)
        key.handle(.flagsChanged, code: 61, flags: NSEvent.ModifierFlags.function.rawValue)
        XCTAssertEqual(taps, 0)
    }

    func testEscapeCancelsAndDoesNotTurnReleaseIntoTap() {
        let key = GlobalHotkey()
        var taps = 0, cancellations = 0
        key.onTap = { taps += 1 }
        key.onCancel = { cancellations += 1 }
        key.handle(.flagsChanged, code: 61, flags: option)
        key.handle(.keyDown, code: 53, flags: option)
        key.handle(.keyUp, code: 53, flags: option)
        key.handle(.flagsChanged, code: 61, flags: 0)
        XCTAssertEqual(cancellations, 1)
        XCTAssertEqual(taps, 0)
        key.handle(.flagsChanged, code: 61, flags: option)
        key.handle(.flagsChanged, code: 61, flags: 0)
        XCTAssertEqual(taps, 1)
    }

    func testSleepClearsKeysWhoseReleaseCannotBeDelivered() {
        let key = GlobalHotkey()
        var taps = 0
        key.onTap = { taps += 1 }
        key.handle(.keyDown, code: 0, flags: 0)
        key.reset(clearHeldKeys: true)
        key.handle(.flagsChanged, code: 61, flags: option)
        key.handle(.flagsChanged, code: 61, flags: 0)
        XCTAssertEqual(taps, 1)
    }

    func testOtherConfiguredRightModifiersUseTheirOwnDeviceBits() {
        for (choice, code, flags) in [(HotkeyChoice.rightControl, UInt16(62), UInt(0x2000) | NSEvent.ModifierFlags.control.rawValue),
                                       (.rightCommand, UInt16(54), UInt(0x10) | NSEvent.ModifierFlags.command.rawValue)] {
            let key = GlobalHotkey(); key.choice = choice
            var taps = 0
            key.onTap = { taps += 1 }
            key.handle(.flagsChanged, code: code, flags: flags)
            key.handle(.flagsChanged, code: code, flags: 0)
            XCTAssertEqual(taps, 1)
        }
    }

    func testDuplicatedForegroundEventsToggleOnlyOnce() {
        let key = GlobalHotkey()
        var taps = 0
        key.onTap = { taps += 1 }
        for _ in 0..<2 { key.receive(.flagsChanged, code: 61, flags: option, timestamp: 1) }
        for _ in 0..<2 { key.receive(.flagsChanged, code: 61, flags: 0, timestamp: 1.1) }
        XCTAssertEqual(taps, 1)
    }

    func testDelayedLocalCopyCannotReplayAnAlreadyReleasedTap() {
        let key = GlobalHotkey()
        var taps = 0
        key.onTap = { taps += 1 }
        key.receive(.flagsChanged, code: 61, flags: option, timestamp: 1)
        key.receive(.flagsChanged, code: 61, flags: 0, timestamp: 1.1)
        key.receive(.flagsChanged, code: 61, flags: option, timestamp: 1)
        key.receive(.flagsChanged, code: 61, flags: 0, timestamp: 1.1)
        XCTAssertEqual(taps, 1)
        key.receive(.flagsChanged, code: 61, flags: option, timestamp: 2)
        key.receive(.flagsChanged, code: 61, flags: 0, timestamp: 2.1)
        XCTAssertEqual(taps, 2)
    }

    func testEscapeDeliveredThroughOneOrBothSourcesCancelsOnce() {
        let key = GlobalHotkey()
        var cancellations = 0
        key.onCancel = { cancellations += 1 }
        key.receive(.keyDown, code: 53, flags: 0, timestamp: 1)
        key.receive(.keyDown, code: 53, flags: 0, timestamp: 1 + 0.00000001)
        XCTAssertEqual(cancellations, 1)
        key.receive(.keyUp, code: 53, flags: 0, timestamp: 1.1)
        key.receive(.keyDown, code: 53, flags: 0, timestamp: 2)
        XCTAssertEqual(cancellations, 2)
    }

    func testFocusTransitionDoesNotRequireBothSourcesForPressAndRelease() {
        let key = GlobalHotkey()
        var taps = 0
        key.onTap = { taps += 1 }
        key.receive(.flagsChanged, code: 61, flags: option, timestamp: 1)
        // A release delivered only by the other source still finishes the same gesture.
        key.receive(.flagsChanged, code: 61, flags: 0, timestamp: 1.1)
        XCTAssertEqual(taps, 1)
    }

    func testPhysicalFnAfterLocalEventWithDifferentClockStillReachesBridge() {
        let key = GlobalHotkey(); key.useInputMethod = true
        var presses = 0, releases = 0
        key.onFnPress = { presses += 1 }; key.onFnRelease = { releases += 1 }
        // Reproduce build20 receipts: the local timestamp is in the millions,
        // while the incoming global timestamp is in the tens of thousands.
        key.receive(.keyDown, code: 48, flags: 0, timestamp: 2_200_000, source: .localMonitor)
        key.receive(.keyUp, code: 48, flags: 0, timestamp: 2_200_000.1, source: .localMonitor)
        key.receive(.flagsChanged, code: 63, flags: NSEvent.ModifierFlags.function.rawValue, timestamp: 53_000)
        key.receive(.flagsChanged, code: 63, flags: 0, timestamp: 53_000.1)
        XCTAssertEqual(presses, 1); XCTAssertEqual(releases, 1)
    }

    func testOneSourceCanMixSyntheticAndPhysicalClocksWithoutGettingStuck() {
        let key = GlobalHotkey(); key.useInputMethod = true
        var presses = 0, releases = 0
        key.onFnPress = { presses += 1 }; key.onFnRelease = { releases += 1 }
        key.receive(.keyUp, code: 9, flags: 0, timestamp: 2_200_000)
        for time in [53_000.0, 53_001.0] {
            key.receive(.flagsChanged, code: 63, flags: NSEvent.ModifierFlags.function.rawValue, timestamp: time)
            key.receive(.flagsChanged, code: 63, flags: 0, timestamp: time + 0.1)
        }
        XCTAssertEqual(presses, 2); XCTAssertEqual(releases, 2)
    }

    func testBothSourceCopiesCannotReplayFnAfterReleaseDespiteUnrelatedClockJump() {
        let key = GlobalHotkey(); key.useInputMethod = true
        var presses = 0, releases = 0
        key.onFnPress = { presses += 1 }; key.onFnRelease = { releases += 1 }
        let fn = NSEvent.ModifierFlags.function.rawValue
        key.receive(.flagsChanged, code: 63, flags: fn, timestamp: 53_000)
        key.receive(.flagsChanged, code: 63, flags: 0, timestamp: 53_000.1)
        key.receive(.keyUp, code: 48, flags: 0, timestamp: 2_200_000, source: .localMonitor)
        key.receive(.flagsChanged, code: 63, flags: fn, timestamp: 53_000, source: .localMonitor)
        key.receive(.flagsChanged, code: 63, flags: 0, timestamp: 53_000.1, source: .localMonitor)
        XCTAssertEqual(presses, 1); XCTAssertEqual(releases, 1)
        key.receive(.flagsChanged, code: 63, flags: fn, timestamp: 53_001)
        key.receive(.flagsChanged, code: 63, flags: 0, timestamp: 53_001.1)
        XCTAssertEqual(presses, 2); XCTAssertEqual(releases, 2)
    }
}
