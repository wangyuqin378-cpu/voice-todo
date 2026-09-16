import XCTest
@testable import VoiceTodoCore

final class AutomaticCapturePolicyTests: XCTestCase {
    // Includes the user's accidental records and ordinary work instructions.
    private let ordinary = [
        "优化公开项目介绍", "根据GitHub最新内容整体更新GitHub主页", "新增公开项目水口清单（PC端产品，主推）",
        "土地", "新增土地", "添加一个按钮", "安排一下页面布局", "帮我安排明天的面试",
        "我明天下午三点面试", "明天下午三点提醒我面试", "我10月1号要买车票，提醒我一下",
        "这段文案里加上提醒我明天面试", "他说提醒我明天面试", "请在开头写帮我记录一下",
        "材料交好了", "面试完成了", "取消面试", "帮我取消面试", "撤销", "刚才弄错了，撤销",
        "记录一下项目介绍", "记一下，明天交材料", "请提醒我明天面试", "帮我记录明天交材料",
        "“提醒我明天面试”", "「帮我记录一下买牛奶」", "比如清单，面试完成了", "水果清单，明天面试",
        "清单功能很好", "随口清单有什么特点", "明天下午三点", "是的", "不用提醒",
        "提醒我", "帮我记录一下，。", "清单，", "", "  "
    ]

    func testOrdinarySpeechIsRejectedInBothChannelsEvenDuringAQuestion() throws {
        for text in ordinary {
            XCTAssertFalse(AutomaticCapturePolicy.accepts(text), text)
            for questionID: String? in [nil, "active-question"] {
                var field = try XCTUnwrap(TranscriptionCapture(baseline: "", selection: .init(location: 0, length: 0), questionID: questionID))
                field.end(at: 1); field.observe(text, at: 2)
                XCTAssertNil(field.ready(at: 4), text)
                var clipboard = ClipboardTranscriptionCapture(changeCount: 1, questionID: questionID)
                clipboard.end(at: 1); clipboard.observe(changeCount: 2, at: 2) { text }
                if case .command = clipboard.result(at: 4) { XCTFail("Imported ordinary clipboard: \(text)") }
            }
        }
    }

    func testExplicitOpeningIsAcceptedWithoutRewritingOriginalWords() throws {
        for text in ["提醒我明天下午三点面试", "帮我记录一下，明天交材料", "清单，材料交好了",
                     "清单材料已经交了", "清单，取消明天的面试", "清单，撤销", "随口清单，面试完成了",
                     "清单，明天下午三点", "清单，是的", "清单，不用提醒", "  提醒我买牛奶  "] {
            XCTAssertTrue(AutomaticCapturePolicy.accepts(text), text)
            var capture = try XCTUnwrap(TranscriptionCapture(baseline: "", selection: .init(location: 0, length: 0)))
            capture.end(at: 1); capture.observe(text, at: 2)
            XCTAssertEqual(capture.ready(at: 4), text.trimmingCharacters(in: .whitespacesAndNewlines))
        }
    }

    func testManualUnderstandingStillSupportsSuffixReminder() throws {
        let input = "我10月1号要买车票，提醒我一下"
        XCTAssertFalse(AutomaticCapturePolicy.accepts(input))
        let proposal = try XCTUnwrap(LocalInterpreter.interpret(input, workspace: .init(), question: nil,
            now: Dates.parse("2026-09-17T10:00:00+08:00")!, timeZone: "Asia/Shanghai"))
        XCTAssertEqual(proposal.actions.first?.title, "买车票")
        XCTAssertEqual(proposal.actions.first?.reminderISO.flatMap(Dates.parse), Dates.parse("2026-10-01T09:00:00+08:00"))
    }
}
