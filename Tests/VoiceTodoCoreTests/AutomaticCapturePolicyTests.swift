import XCTest
@testable import VoiceTodoCore

final class AutomaticCapturePolicyTests: XCTestCase {
    func testDiverseTaskLanguageReachesBothChannelsWithoutOpeningPhrase() throws {
        let phrases = ["帮我安排明天的面试", "我明天下午三点面试", "明天下午三点提醒我面试",
            "我10月1号要买车票，提醒我一下", "材料交好了", "面试完成了", "取消面试", "帮我取消面试",
            "撤销", "刚才弄错了，撤销", "记录一下项目介绍", "记一下，明天交材料", "请提醒我明天面试",
            "帮我记录明天交材料", "清单，面试完成了", "  提醒我买牛奶  ", "车票买到了", "麻烦到时候提醒我交房租",
            "明天有个面试，帮忙记一下", "我打算整理照片", "下周去看牙", "今晚需要浇花", "能不能提醒我明天交材料？",
            "明天开会，不对，后天开会", "报销还没完成了，别勾选", "明天见客户，周五再寄合同",
            "我需要办护照", "报销搞定了", "周五去滑雪", "发票提交了", "后天去遛狗", "买牛奶这件事帮我记录一下", "面试已经做完了", "我今晚要复习英语"]
        for text in phrases {
            XCTAssertTrue(AutomaticCapturePolicy.accepts(text), text)
            var field = try XCTUnwrap(TranscriptionCapture(baseline: "", selection: .init(location: 0, length: 0)))
            field.end(at: 1); field.observe(text, at: 2)
            XCTAssertEqual(field.ready(at: 4), text.trimmingCharacters(in: .whitespacesAndNewlines), text)
            var clipboard = ClipboardTranscriptionCapture(changeCount: 1)
            clipboard.end(at: 1); clipboard.observe(changeCount: 2, at: 2) { text }
            XCTAssertEqual(clipboard.result(at: 4), .command(text.trimmingCharacters(in: .whitespacesAndNewlines)), text)
        }
    }
    func testOrdinaryTextIsNotMadeIntoAnInstruction() {
        for text in ["优化公开项目介绍", "根据GitHub最新内容整体更新GitHub主页", "新增公开项目水口清单（PC端产品，主推）",
            "土地", "新增土地", "添加一个按钮", "安排一下页面布局", "天气好了", "网络好了",
            "这段文案里加上提醒我明天面试", "他说提醒我明天面试", "请在开头写帮我记录一下",
            "“提醒我明天面试”", "「帮我记录一下买牛奶」", "比如清单，面试完成了",
            "清单功能很好", "随口清单有什么特点", "提醒我", "帮我记录一下，。", "清单，", "", "  "] {
            XCTAssertFalse(AutomaticCapturePolicy.accepts(text), text)
            XCTAssertFalse(AutomaticCapturePolicy.accepts(text, answering: true), text)
        }
    }
    func testShortAnswersRequireLiveContextInBothChannels() throws {
        for text in ["明天下午三点", "十分钟后", "是的", "不用提醒", "第二条", "不是第一条"] {
            XCTAssertFalse(AutomaticCapturePolicy.accepts(text), text)
            XCTAssertTrue(AutomaticCapturePolicy.accepts(text, answering: true), text)
            var field = try XCTUnwrap(TranscriptionCapture(baseline: "", selection: .init(location: 0, length: 0), questionID: "q"))
            field.end(at: 1); field.observe(text, at: 2)
            XCTAssertEqual(field.ready(at: 4), text)
        }
    }
}
