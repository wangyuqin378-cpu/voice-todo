import XCTest
@testable import VoiceTodoCore

final class ClipboardTranscriptionTests: XCTestCase {
    func testNeverReadsOldClipboardAndWaitsForEnd() {
        var capture = ClipboardTranscriptionCapture(changeCount: 41)
        var reads = 0
        capture.observe(changeCount: 41, at: 1) { reads += 1; return "清单，旧命令" }
        XCTAssertEqual(reads, 0)
        capture.observe(changeCount: 42, at: 2) { reads += 1; return "清单，记得买牛奶" }
        XCTAssertEqual(capture.result(at: 10), .waiting)
        capture.end(at: 11)
        XCTAssertEqual(capture.result(at: 12), .waiting)
        XCTAssertEqual(capture.result(at: 13), .command("清单，记得买牛奶"))
        capture.observe(changeCount: 43, at: 14) { reads += 1; return "清单，记得买牛奶" }
        XCTAssertEqual(reads, 1)
        XCTAssertEqual(capture.result(at: 20), .waiting)
    }
    func testLatestCopiedCorrectionWinsAfterQuietPeriod() {
        var capture = ClipboardTranscriptionCapture(changeCount: 1)
        capture.observe(changeCount: 2, at: 1) { "清单，材料已经交了" }
        capture.end(at: 2)
        capture.observe(changeCount: 3, at: 2.8) { "清单，材料已经交了，不对，还没有交" }
        XCTAssertEqual(capture.result(at: 3.3), .waiting)
        XCTAssertEqual(capture.result(at: 4.1), .command("清单，材料已经交了，不对，还没有交"))
    }
    func testOrdinaryCopiedChatDoesNotBecomeCommand() {
        for text in ["跟朋友说材料已经交了", "他说清单，材料已经交了", "清单功能很好", "“清单，材料交了”"] {
            var capture = ClipboardTranscriptionCapture(changeCount: 1)
            capture.observe(changeCount: 2, at: 1) { text }
            capture.end(at: 2)
            XCTAssertEqual(capture.result(at: 4), .ignored, text)
        }
    }
    func testEmptyNonTextAndOversizedClipboardAreNeverDelivered() {
        for text in [nil, "", String(repeating: "字", count: 25_001)] as [String?] {
            var capture = ClipboardTranscriptionCapture(changeCount: 1)
            capture.observe(changeCount: 2, at: 1) { text }
            capture.end(at: 2)
            XCTAssertEqual(capture.result(at: 4), .waiting)
        }
    }
    func testCopyOnlyCreateAnswerCompleteAndUndoUseOnePipeline() throws {
        let now = Dates.parse("2026-09-15T10:00:00+08:00")!
        var workspace = Workspace()
        func turn(_ text: String, questionID: String? = nil) throws {
            var capture = ClipboardTranscriptionCapture(changeCount: 1, questionID: questionID)
            capture.observe(changeCount: 2, at: 1) { text }
            capture.end(at: 2)
            guard case .command(let accepted) = capture.result(at: 4) else { return XCTFail("Did not receive dictation") }
            let q = workspace.questions.first { $0.id == questionID }
            let proposal = try XCTUnwrap(LocalInterpreter.interpret(accepted, workspace: workspace, question: q, now: now, timeZone: "Asia/Shanghai"))
            workspace = try TaskReducer.apply(proposal, to: workspace, inputID: capture.id, input: accepted, answering: questionID, now: now).workspace
        }
        try turn("清单提醒我买牛奶")
        let q = try XCTUnwrap(workspace.questions.first)
        try turn("不用提醒。", questionID: q.id)
        XCTAssertEqual(workspace.tasks.count, 1)
        XCTAssertFalse(workspace.tasks[0].needsReminder)
        XCTAssertTrue(workspace.questions.isEmpty)
        try turn("清单，牛奶买好了")
        XCTAssertTrue(workspace.tasks[0].isCompleted)
        try turn("清单撤销")
        XCTAssertFalse(workspace.tasks[0].isCompleted)
        XCTAssertNil(workspace.tasks[0].reminderAt)
    }
    func testUnaddressedClipboardRequiresScopedQuestionID() {
        var capture = ClipboardTranscriptionCapture(changeCount: 1)
        capture.observe(changeCount: 2, at: 1) { "不用提醒" }
        capture.end(at: 2)
        XCTAssertEqual(capture.result(at: 4), .ignored)
    }
}
