import XCTest
@testable import VoiceTodoCore

final class HotkeyTests: XCTestCase {
    func testQuickTapStartsAndNextTapEndsThroughToggle() {
        var key = HotkeyGesture()
        XCTAssertEqual(key.press(hasOtherKeys: false), .armHold)
        XCTAssertEqual(key.release(), .tap)
        XCTAssertEqual(key.state, .idle)
        XCTAssertEqual(key.press(hasOtherKeys: false), .armHold)
        XCTAssertEqual(key.release(), .tap)
    }
    func testHoldStartsAndReleaseEnds() {
        var key = HotkeyGesture(); _ = key.press(hasOtherKeys: false)
        XCTAssertEqual(key.holdThreshold(), .startHold)
        XCTAssertEqual(key.release(), .endHold)
        XCTAssertEqual(key.state, .idle)
    }
    func testOrdinaryTapAfterFeedbackKeepsRecording() {
        var key = HotkeyGesture(); _ = key.press(hasOtherKeys: false)
        XCTAssertEqual(key.holdThreshold(), .startHold)
        XCTAssertEqual(key.release(heldFor: 0.22), .latchRecording)
        XCTAssertEqual(key.state, .idle)
    }
    func testLongPressReleaseEndsAtTapBoundary() {
        var key = HotkeyGesture(); _ = key.press(hasOtherKeys: false); _ = key.holdThreshold()
        XCTAssertEqual(key.release(heldFor: 0.35), .endHold)
    }
    func testLateTimerCannotStartAfterQuickTap() {
        var key = HotkeyGesture(); _ = key.press(hasOtherKeys: false); _ = key.release()
        XCTAssertEqual(key.holdThreshold(), .none)
    }
    func testComboBeforePressNeverRecords() {
        var key = HotkeyGesture()
        XCTAssertEqual(key.press(hasOtherKeys: true), .none)
        XCTAssertEqual(key.holdThreshold(), .none)
        XCTAssertEqual(key.release(), .none)
    }
    func testComboAfterPressNeverBecomesTap() {
        var key = HotkeyGesture(); _ = key.press(hasOtherKeys: false)
        XCTAssertEqual(key.combine(), .none)
        XCTAssertEqual(key.holdThreshold(), .none)
        XCTAssertEqual(key.release(), .none)
    }
    func testComboDuringHoldCancelsAndNextPressWorks() {
        var key = HotkeyGesture(); _ = key.press(hasOtherKeys: false); _ = key.holdThreshold()
        XCTAssertEqual(key.combine(), .cancelHold)
        XCTAssertEqual(key.release(), .none)
        XCTAssertEqual(key.press(hasOtherKeys: false), .armHold)
        XCTAssertEqual(key.release(), .tap)
    }
    func testCancelStopsHoldAndIgnoresItsLaterRelease() {
        var key = HotkeyGesture(); _ = key.press(hasOtherKeys: false); _ = key.holdThreshold()
        XCTAssertEqual(key.reset(), .cancelHold)
        XCTAssertEqual(key.release(), .none)
        XCTAssertEqual(key.holdThreshold(), .none)
    }
    func testRepeatedPressCannotDoubleStart() {
        var key = HotkeyGesture(); _ = key.press(hasOtherKeys: false)
        XCTAssertEqual(key.press(hasOtherKeys: false), .none)
        XCTAssertEqual(key.holdThreshold(), .startHold)
        XCTAssertEqual(key.holdThreshold(), .none)
    }
}
