import AppKit
import XCTest
import VoiceTodoCore
@testable import VoiceTodoApp

@MainActor final class ClipboardIntegrationTests: XCTestCase {
    func testPrivatePasteboardClearThenWriteAndNoStaleReads() {
        // Named scratch board only: never touch the user's general clipboard.
        let board = NSPasteboard(name: .init("com.wyq.voicetodo.qa." + UUID().uuidString))
        defer { board.releaseGlobally() }
        board.clearContents(); board.setString("清单，旧命令", forType: .string)
        var capture = ClipboardTranscriptionCapture(changeCount: board.changeCount)
        var reads = 0
        capture.observe(changeCount: board.changeCount, at: 0) { reads += 1; return board.string(forType: .string) }
        XCTAssertEqual(reads, 0)
        board.clearContents()
        capture.observe(changeCount: board.changeCount, at: 1) { board.string(forType: .string) }
        capture.end(at: 2)
        XCTAssertEqual(capture.result(at: 4), .waiting)
        board.setString("清单，记得买牛奶", forType: .string)
        capture.observe(changeCount: board.changeCount, at: 5) { board.string(forType: .string) }
        XCTAssertEqual(capture.result(at: 7), .command("清单，记得买牛奶"))
        XCTAssertEqual(board.string(forType: .string), "清单，记得买牛奶")
    }
    func testPrivatePasteboardSameOwnerCorrectionResetsQuietPeriod() {
        let board = NSPasteboard(name: .init("com.wyq.voicetodo.qa." + UUID().uuidString))
        defer { board.releaseGlobally() }
        var capture = ClipboardTranscriptionCapture(changeCount: board.changeCount)
        board.clearContents(); board.setString("清单，材料交了", forType: .string)
        capture.observe(changeCount: board.changeCount, at: 1) { board.string(forType: .string) }
        capture.end(at: 2)
        board.setString("清单，材料交了，不对，还没交", forType: .string)
        capture.observe(changeCount: board.changeCount, at: 2.9) { board.string(forType: .string) }
        XCTAssertEqual(capture.result(at: 3.3), .waiting)
        capture.observe(changeCount: board.changeCount, at: 4) { board.string(forType: .string) }
        XCTAssertEqual(capture.result(at: 4.2), .command("清单，材料交了，不对，还没交"))
    }
    func testManualCopyCancelsClipboardPathButSyntheticPasteDoesNot() {
        let hotkey = GlobalHotkey(); hotkey.useInputMethod = true
        var manualCopies = 0
        hotkey.onManualCopy = { manualCopies += 1 }
        let cmd = NSEvent.ModifierFlags.command.rawValue
        hotkey.handle(.keyDown, code: 9, flags: cmd) // V: input-method commit
        XCTAssertEqual(manualCopies, 0)
        hotkey.handle(.keyUp, code: 9, flags: cmd)
        hotkey.handle(.keyDown, code: 8, flags: cmd) // C: user copy
        hotkey.handle(.keyUp, code: 8, flags: cmd)
        hotkey.handle(.keyDown, code: 7, flags: cmd) // X: user cut
        XCTAssertEqual(manualCopies, 2)
    }
}
