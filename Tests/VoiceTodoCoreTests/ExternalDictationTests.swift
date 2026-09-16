import XCTest
@testable import VoiceTodoCore

final class ExternalDictationTests: XCTestCase {
    let text = "提醒我明天下午三点面试"
    func capture(questionID: String? = nil) -> ExternalDictationCapture {
        .init(baseline: "草稿", selection: NSRange(location: 2, length: 0), clipboardCount: 10, questionID: questionID)
    }
    func testReadableButUnchangedFieldStillReceivesClipboard() {
        var c = capture()
        c.observeField("草稿", at: 1)
        c.observeClipboard(changeCount: 10, at: 1) { XCTFail("Old clipboard must never be read"); return text }
        c.observeClipboard(changeCount: 11, at: 2) { text }
        XCTAssertEqual(c.result(at: 5), .waiting)
        c.end(at: 6)
        XCTAssertEqual(c.result(at: 6.5), .waiting)
        XCTAssertEqual(c.result(at: 8), .command(text, .clipboard))
        XCTAssertEqual(c.result(at: 10), .waiting)
    }
    func testOrdinaryClipboardUpdateDoesNotDiscardLaterFinalUtterance() {
        for finalCount in [11, 12] {
            var c = capture()
            c.end(at: 1)
            c.observeClipboard(changeCount: 11, at: 2) { "正在转写…" }
            XCTAssertEqual(c.result(at: 3.3), .waiting)
            c.observeClipboard(changeCount: finalCount, at: 5) { "提醒我明天下午 6 点面试。" }
            XCTAssertEqual(c.result(at: 6.1), .waiting)
            XCTAssertEqual(c.result(at: 6.3), .command("提醒我明天下午 6 点面试。", .clipboard))
            XCTAssertEqual(c.result(at: 7), .waiting)
        }
    }
    func testPartialFieldDoesNotDiscardLaterFinalUtterance() {
        var c = capture()
        c.end(at: 1)
        c.observeField("草稿面试", at: 2)
        XCTAssertEqual(c.result(at: 3.3), .waiting)
        c.observeField("草稿提醒我明天下午 6 点面试。", at: 5)
        XCTAssertEqual(c.result(at: 6.3), .command("提醒我明天下午 6 点面试。", .field))
    }
    func testUnsettledFieldCorrectionBlocksOlderClipboardCompletion() {
        var c = capture()
        c.end(at: 1)
        c.observeClipboard(changeCount: 11, at: 2) { "材料交好了" }
        c.observeField("草稿材料还没交", at: 3)
        XCTAssertEqual(c.result(at: 3.3), .waiting)
        XCTAssertEqual(c.result(at: 4.3), .waiting)
        XCTAssertEqual(c.result(at: 21), .ignored)
    }
    func testTwoChannelsDeliverOnlyOnceAndPreferField() {
        var c = capture()
        c.observeField("草稿" + text, at: 1)
        c.observeClipboard(changeCount: 11, at: 1) { text }
        c.end(at: 2)
        XCTAssertEqual(c.result(at: 4), .command(text, .field))
        XCTAssertEqual(c.result(at: 6), .waiting)
    }
    func testFinalFieldCorrectionCannotBeOverriddenByCopiedCommand() {
        var c = capture()
        c.observeClipboard(changeCount: 11, at: 1) { text }
        c.observeField("草稿今天聊得很开心", at: 1)
        c.end(at: 2)
        XCTAssertEqual(c.result(at: 4), .waiting)
        XCTAssertEqual(c.result(at: 22), .ignored)
    }
    func testOrdinaryFieldTextFinishesAtReceiveDeadline() {
        var c = capture()
        c.end(at: 1)
        c.observeField("草稿今天聊得很开心", at: 2)
        XCTAssertEqual(c.result(at: 2.5), .waiting)
        XCTAssertEqual(c.result(at: 4), .waiting)
        XCTAssertEqual(c.result(at: 21), .ignored)
    }
    func testOrdinaryClipboardUpdatesCannotExtendDeadlineOrReadAfterIt() {
        var c = capture()
        c.end(at: 1)
        for time in [2.0, 6, 10, 18] {
            c.observeClipboard(changeCount: Int(time), at: time) { "随便聊聊" }
            XCTAssertEqual(c.result(at: time + 1.3), .waiting)
        }
        XCTAssertEqual(c.result(at: 21), .ignored)
        c.observeClipboard(changeCount: 99, at: 22) { XCTFail("Read beyond receive window"); return text }
        XCTAssertEqual(c.result(at: 24), .waiting)
    }
    func testBothPathsHaveFiniteWaitAfterFnEnds() {
        for baseline: String? in [nil, ""] {
            var c = ExternalDictationCapture(baseline: baseline, selection: .init(location: 0, length: 0), clipboardCount: 10)
            XCTAssertEqual(c.result(at: 100), .waiting)
            c.end(at: 101)
            XCTAssertEqual(c.result(at: 120.9), .waiting)
            XCTAssertEqual(c.result(at: 121), .timedOut)
        }
    }
    func testSameFnAnswerCanUseEitherChannelWithQuestionContext() {
        var c = capture(questionID: "q")
        c.end(at: 1)
        c.observeClipboard(changeCount: 11, at: 2) { "清单，是的。" }
        XCTAssertEqual(c.result(at: 4), .command("清单，是的。", .clipboard))
        XCTAssertEqual(c.questionID, "q")
        var field = capture(questionID: "q")
        field.end(at: 1)
        field.observeField("草稿清单，不用。", at: 2)
        XCTAssertEqual(field.result(at: 4), .command("清单，不用。", .field))
    }
}
