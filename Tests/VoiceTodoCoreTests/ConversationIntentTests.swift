import XCTest
@testable import VoiceTodoCore

final class ConversationIntentTests: XCTestCase {
    private let discussions = [
        "如果我想住两天水屋呢，再帮我安排一下",
        "如果我想住两天水屋呢 ，再帮我安排一下 ，在仙本那住两天水屋",
        "如果我想住两天水屋呢再帮我安排一下在仙本那住两天水屋",
        "清单，如果我想住两天水屋呢，再帮我安排一下",
        "那我如果多玩两天，帮我安排一下",
        "假如改成三天，明天去海边会不会太赶",
        "要是在酒店多住一晚呢，帮我安排一下",
        "假设我明天去看牙，行程怎么安排",
        "我想明天买车票呢，再帮我安排一下",
        "帮我规划一下明天的旅行路线",
        "给我推荐一下下周旅行的酒店",
        "帮我安排一下行程，明天去海边",
        "我应该怎么安排明天的面试",
        "如果我说提醒我明天面试，会不会被记录"
    ]
    func testDiscussionIsIgnoredByBothTranscriptionChannels() throws {
        for text in discussions {
            XCTAssertTrue(ConversationIntent.isDiscussion(text), text)
            for answering in [false, true] {
                XCTAssertFalse(AutomaticCapturePolicy.accepts(text, answering: answering), text)
                let questionID = answering ? "q" : nil
                var field = try XCTUnwrap(TranscriptionCapture(baseline: "", selection: .init(location: 0, length: 0), questionID: questionID))
                field.end(at: 1); field.observe(text, at: 2)
                XCTAssertNil(field.ready(at: 4), text)
                var clipboard = ClipboardTranscriptionCapture(changeCount: 1, questionID: questionID)
                clipboard.end(at: 1); clipboard.observe(changeCount: 2, at: 2) { text }
                XCTAssertEqual(clipboard.result(at: 4), .ignored, text)
            }
        }
    }
    func testNaturalTaskRequestsAndTaskNamesAreNotDiscussion() {
        for text in ["帮我安排，我明天有个面试就好了", "我明天入住酒店", "我打算整理照片",
            "我10月1号要买车票，提醒我一下", "能不能提醒我明天交材料？", "买牛奶这件事帮我记录一下",
            "记录一下：如果下雨就取消露营", "如果下雨就带伞，这件事帮我记下", "如果下雨就带伞，帮我记录下来",
            "明天整理假设检验报告", "假设检验报告写好了", "明天的旅行方案写好了"] {
            XCTAssertFalse(ConversationIntent.isDiscussion(text), text)
            XCTAssertTrue(AutomaticCapturePolicy.accepts(text), text)
        }
    }
    func testNeitherLocalParserExtractsAnAffirmativeFragment() {
        for text in discussions {
            XCTAssertNil(LocalInterpreter.interpret(text, workspace: .init(), question: nil, now: .now, timeZone: "Asia/Shanghai"), text)
            XCTAssertNil(OfflineInterpreter.interpret(text, workspace: .init(), question: nil, now: .now, timeZone: "Asia/Shanghai", allowPlainCreation: true), text)
        }
    }
    func testModelCannotBypassConditionWithSelectedEvidenceOrPartialBatch() throws {
        let original = Workspace(tasks: [.init(id: "hotel", title: "预订酒店")])
        let input = discussions[1]
        for actions: [ProposedAction] in [
            [.init(kind: .create, title: "在仙本那住两天水屋", noReminder: true, evidence: "在仙本那住两天水屋")],
            [.init(kind: .noop), .init(kind: .create, title: "住两天水屋", noReminder: true)],
            [.init(kind: .clarify, question: "什么时候入住？")]
        ] {
            XCTAssertThrowsError(try TaskReducer.apply(.init(actions: actions), to: original,
                inputID: "discussion", input: input)) { error in
                XCTAssertTrue(error.localizedDescription.contains("讨论方案"))
            }
        }
        let result = try TaskReducer.apply(.init(actions: [.init(kind: .noop)]), to: original,
            inputID: "discussion", input: input)
        XCTAssertEqual(result.workspace.tasks, original.tasks)
        XCTAssertTrue(result.workspace.questions.isEmpty)
    }
}
