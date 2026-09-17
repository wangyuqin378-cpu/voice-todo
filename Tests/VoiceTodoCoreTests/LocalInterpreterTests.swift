import XCTest
@testable import VoiceTodoCore

final class LocalInterpreterTests: XCTestCase {
    let now = Dates.parse("2026-09-15T10:00:00+08:00")!
    func parse(_ text: String, tasks: [TodoItem] = [], question: FollowUp? = nil) -> Proposal? {
        LocalInterpreter.interpret(text, workspace: .init(tasks: tasks), question: question, now: now, timeZone: "Asia/Shanghai")
    }
    func testCreateAndCompleteWithoutAI() throws {
        let input = "清单，明天下午三点提醒我交材料"
        let proposal = try XCTUnwrap(parse(input))
        let created = try TaskReducer.apply(proposal, to: .init(), inputID: "new", input: input, now: now).workspace
        XCTAssertEqual(created.tasks.first?.title, "交材料")
        XCTAssertEqual(created.tasks.first?.reminderAt, Dates.parse("2026-09-16T14:50:00+08:00"))
        let done = try XCTUnwrap(parse("清单，材料已经交了", tasks: created.tasks))
        let result = try TaskReducer.apply(done, to: created, inputID: "done", input: "清单，材料已经交了", now: now)
        XCTAssertTrue(result.workspace.tasks[0].isCompleted)
        XCTAssertEqual(parse("材料已经交了", tasks: result.workspace.tasks)?.actions.first?.kind, .alreadyCompleted)
    }
    func testMissingReminderAndFollowUp() throws {
        let p = try XCTUnwrap(parse("提醒我报销"))
        let created = try TaskReducer.apply(p, to: .init(), inputID: "1", input: "提醒我报销", now: now).workspace
        let q = try XCTUnwrap(created.questions.first)
        for reply in ["不用提醒", "明天下午三点"] {
            let p = try XCTUnwrap(parse(reply, tasks: created.tasks, question: q))
            let changed = try TaskReducer.apply(p, to: created, inputID: reply, input: reply, answering: q.id, now: now).workspace
            XCTAssertTrue(changed.questions.isEmpty)
            XCTAssertFalse(changed.tasks[0].needsReminder)
        }
    }
    func testUsualTranscriptionPhrasingStaysLocal() throws {
        for input in ["创建 to do，买牛奶，不用提醒", "创建一个To-do：买牛奶，不用提醒"] {
            XCTAssertEqual(try XCTUnwrap(parse(input)).actions.first?.title, "买牛奶")
        }
        XCTAssertEqual(try XCTUnwrap(parse("牛奶买好了", tasks: [.init(title: "买牛奶")])).actions.first?.kind, .complete)
        XCTAssertEqual(try XCTUnwrap(parse("半小时后提醒我取快递")).actions.first?.reminderISO, Dates.iso(now.addingTimeInterval(1800)))
    }
    func testNoMatchUsesSemanticPathButPartialAndDuplicateNamesAskLocally() {
        XCTAssertNil(parse("材料已经交了"))
        XCTAssertEqual(parse("材料已经交了", tasks: [.init(title: "交材料"), .init(title: "交材料")])?.actions.first?.kind, .clarify)
        XCTAssertEqual(parse("材料交好了", tasks: [.init(title: "交签证材料"), .init(title: "交报销材料")])?.actions.first?.kind, .clarify)
    }
    func testNoAccidentalCompletionOrPartialApplication() {
        let task = TodoItem(title: "交材料")
        for input in ["材料还没交", "材料差一点交完", "材料交了？", "明天材料交了", "材料交了再买牛奶", "材料已经交了，不对，还没交", "他说材料交了", "比如材料已经交了", "材料已经交了，明天下午三点提醒我买牛奶", "创建待办买牛奶，算了不用了", "创建待办买牛奶，不用提醒，算了还是提醒我", "创建待办写方案，已经写好了"] {
            XCTAssertNil(parse(input, tasks: [task]), input)
        }
    }
    func testTimeIsBoundedAndUsesTimeZone() {
        XCTAssertEqual(LocalInterpreter.time("十分钟后", now: now, timeZone: "Asia/Shanghai"), now.addingTimeInterval(600))
        XCTAssertEqual(LocalInterpreter.time("周五下午三点半", now: now, timeZone: "Asia/Shanghai"), Dates.parse("2026-09-18T15:30:00+08:00"))
        for text in ["下午", "明天", "今天上午九点", "明天二十五点", "明天下午三点七十分", "每天三点", "明天下午三点或者四点"] {
            XCTAssertNil(LocalInterpreter.time(text, now: now, timeZone: "Asia/Shanghai"), text)
        }
    }
    func testExplicitCommandBoundary() {
        for text in ["普通聊天，明天提醒我买牛奶", "他说清单，材料已经交了", "清单功能很好", "“清单，材料已经交了”"] { XCTAssertNil(CommandText.body(text)) }
        XCTAssertEqual(CommandText.body("清单，材料已经交了"), "材料已经交了")
        XCTAssertEqual(CommandText.body("创建 to do，买牛奶"), "创建待办买牛奶")
    }
    func testRealWeTypeTranscriptDoesNotNeedInventedPunctuation() {
        XCTAssertEqual(CommandText.body("清单创建，代办测试，买牛奶不用提醒。"), "创建待办测试，买牛奶不用提醒。")
        XCTAssertEqual(CommandText.body("清单创建待办买牛奶不用提醒。"), "创建待办买牛奶不用提醒。")
        XCTAssertEqual(CommandText.body("清单明天下午三点提醒我交材料"), "明天下午三点提醒我交材料")
        XCTAssertEqual(CommandText.body("清单材料已经交了"), "材料已经交了")
        XCTAssertEqual(CommandText.body("创建代办买牛奶"), "创建待办买牛奶")
        for text in ["清单功能很好", "清单有什么特点", "他说清单创建代办", "这份清单创建了三次"] {
            XCTAssertNil(CommandText.body(text), text)
        }
        XCTAssertEqual(parse("清单创建待办买牛奶不用提醒。")?.actions.first?.title, "买牛奶")
    }
}

final class TranscriptionCaptureTests: XCTestCase {
    func testReplyNeedsConversationContextButNoOpeningAddress() throws {
        var normal = try XCTUnwrap(TranscriptionCapture(baseline: "", selection: NSRange(location: 0, length: 0)))
        normal.end(at: 1); normal.observe("明天下午三点", at: 2)
        XCTAssertNil(normal.ready(at: 4))
        var reply = try XCTUnwrap(TranscriptionCapture(baseline: "", selection: NSRange(location: 0, length: 0), questionID: "q"))
        reply.end(at: 1); reply.observe("明天下午三点", at: 2)
        XCTAssertNil(reply.ready(at: 3))
        XCTAssertEqual(reply.ready(at: 4), "明天下午三点")
        XCTAssertEqual(reply.questionID, "q")
        XCTAssertNil(reply.ready(at: 8))
    }
    func testAddressedDictationReplyCreatesReminderWithSameShortcut() throws {
        let now = Dates.parse("2026-09-15T10:00:00+08:00")!
        let text = "清单提醒我报销"
        let proposal = try XCTUnwrap(LocalInterpreter.interpret(text, workspace: .init(), question: nil, now: now, timeZone: "Asia/Shanghai"))
        let created = try TaskReducer.apply(proposal, to: .init(), inputID: "first", input: text, now: now).workspace
        let question = try XCTUnwrap(created.questions.first)
        let window = DictationReplyWindow(questionID: question.id, sourceID: "same-field", now: 1)
        let qid = try XCTUnwrap(window.answerID(sourceID: "same-field", pendingQuestionID: question.id, now: 5))
        var capture = try XCTUnwrap(TranscriptionCapture(baseline: text, selection: NSRange(location: text.utf16.count, length: 0), questionID: qid))
        capture.end(at: 6); capture.observe(text + "清单，明天下午三点", at: 7)
        let answer = try XCTUnwrap(capture.ready(at: 9))
        let p = try XCTUnwrap(LocalInterpreter.interpret(answer, workspace: created, question: question, now: now, timeZone: "Asia/Shanghai"))
        let result = try TaskReducer.apply(p, to: created, inputID: capture.id, input: answer, answering: capture.questionID, now: now).workspace
        XCTAssertEqual(result.tasks.count, 1)
        XCTAssertEqual(result.tasks[0].reminderAt, Dates.parse("2026-09-16T15:00:00+08:00"))
        XCTAssertTrue(result.questions.isEmpty)
    }
    func testConversationCannotCaptureFromDifferentFieldExpiredOrResolvedQuestion() {
        let window = DictationReplyWindow(questionID: "q", sourceID: "field", now: 10)
        XCTAssertEqual(window.answerID(sourceID: "field", pendingQuestionID: "q", now: 20), "q")
        XCTAssertNil(window.answerID(sourceID: "other", pendingQuestionID: "q", now: 20))
        XCTAssertNil(window.answerID(sourceID: "field", pendingQuestionID: "q", now: 130))
        XCTAssertNil(window.answerID(sourceID: "field", pendingQuestionID: nil, now: 20))
        XCTAssertNil(window.answerID(sourceID: "field", pendingQuestionID: "other", now: 20))
    }
    func testCombiningCharactersDoNotShiftInsertionBoundary() throws {
        // The original selection is before a combining accent, a valid UTF-16
        // scalar boundary even though it lies inside a displayed grapheme.
        let c = try XCTUnwrap(TranscriptionCapture(baseline: "a\u{0301}X", selection: NSRange(location: 1, length: 0)))
        XCTAssertEqual(c.insertion(in: "a清单，材料交好了\u{0301}X"), "清单，材料交好了")
        let unchanged = try XCTUnwrap(TranscriptionCapture(baseline: "é后文", selection: NSRange(location: 1, length: 0)))
        XCTAssertNil(unchanged.insertion(in: "e\u{0301}清单，材料交好了后文"))
        XCTAssertEqual(unchanged.insertion(in: "é清单，材料交好了后文"), "清单，材料交好了")
    }
    func testWaitsForEndAndQuietAndUsesFinalRevisionOnce() throws {
        var capture = try XCTUnwrap(TranscriptionCapture(baseline: "", selection: NSRange(location: 0, length: 0)))
        capture.observe("清单，材料已交", at: 1)
        XCTAssertNil(capture.ready(at: 10))
        capture.end(at: 11)
        capture.observe("清单，材料已交，不对还没交", at: 11.5)
        XCTAssertNil(capture.ready(at: 12))
        XCTAssertEqual(capture.ready(at: 13), "清单，材料已交，不对还没交")
        XCTAssertNil(capture.ready(at: 20))
    }
    func testCapturesOnlyInsertionAndNeverAltersDraft() throws {
        let baseline = "🙂原来的草稿后半段"
        let c = try XCTUnwrap(TranscriptionCapture(baseline: baseline, selection: NSRange(location: 2, length: 5)))
        XCTAssertEqual(c.insertion(in: "🙂清单，创建待办买牛奶后半段"), "清单，创建待办买牛奶")
        XCTAssertNil(c.insertion(in: "改掉前文清单，创建待办买牛奶后半段"))
        XCTAssertNil(c.insertion(in: "🙂清单，创建待办买牛奶删除后文"))
        XCTAssertEqual(c.baseline, baseline)
    }
    func testOrdinaryTextAndInvalidUTF16SelectionCannotCapture() throws {
        XCTAssertNil(TranscriptionCapture(baseline: "🙂", selection: NSRange(location: 1, length: 0)))
        var c = try XCTUnwrap(TranscriptionCapture(baseline: "", selection: NSRange(location: 0, length: 0)))
        c.end(at: 1); c.observe("跟朋友说材料已经交了", at: 2)
        XCTAssertNil(c.ready(at: 20))
    }
}
