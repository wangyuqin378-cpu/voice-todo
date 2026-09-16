import XCTest
@testable import VoiceTodoCore

@MainActor final class CaptureContextTests: XCTestCase {
    func testExternalQueueSurvivesRestartAndDeduplicatesAppliedEvents() throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appending(path: "tasks.store")
        var first: Repository? = try Repository(url: url)
        let text = "清单，创建待办买牛奶"
        _ = try first!.capture(text, questionID: nil, id: "external-one", queued: true)
        _ = try first!.capture(text, questionID: nil, id: "external-one", queued: true)
        XCTAssertEqual(try first!.pending().count, 1)
        first = nil
        let reopened = try Repository(url: url)
        let capture = try XCTUnwrap(reopened.pending().first)
        XCTAssertEqual(capture.status, "queued")
        let result = try TaskReducer.apply(.init(actions: [.init(kind: .create, title: "买牛奶", noReminder: true)]), to: .init(), inputID: capture.id, input: text)
        try reopened.save(result.workspace, capture: capture)
        let duplicate = try reopened.capture(text, questionID: nil, id: "external-one", queued: true)
        XCTAssertEqual(duplicate.status, "applied")
        XCTAssertTrue(try reopened.pending().isEmpty)
        XCTAssertEqual(try reopened.load().tasks.count, 1)
        XCTAssertThrowsError(try reopened.capture("另一段文字", questionID: nil, id: "external-one", queued: true))
    }
    func testFailureAndRetryPreserveOriginalDateAndTimeZone() throws {
        let repository = try Repository(inMemory: true)
        let date = Date(timeIntervalSince1970: 1_900_000_000)
        let capture = try repository.capture("明天下午三点提醒我", questionID: nil, now: date, timeZone: "Asia/Shanghai")
        try repository.fail(capture, message: "断网")
        let retry = try XCTUnwrap(repository.pending().first)
        let context = try repository.captureContext(for: retry)
        XCTAssertEqual(context.interpretationDate, date)
        XCTAssertEqual(context.interpretationTimeZone, "Asia/Shanghai")
        XCTAssertEqual(context.originalText, "明天下午三点提醒我")
    }
    func testEditingKeepsRawInputAndUsesTheNewUtteranceTime() throws {
        let repository = try Repository(inMemory: true)
        let date = Date(timeIntervalSince1970: 1_900_000_000)
        let capture = try repository.capture("交才料", questionID: "q", now: date, timeZone: "Asia/Shanghai")
        let editedAt = date.addingTimeInterval(86400)
        try repository.update(capture, text: "明天交材料", now: editedAt, timeZone: "Europe/London")
        let context = try repository.captureContext(for: capture)
        XCTAssertEqual(context.originalText, "交才料")
        XCTAssertEqual(context.originalDate, date)
        XCTAssertEqual(context.originalTimeZone, "Asia/Shanghai")
        XCTAssertEqual(context.interpretationDate, editedAt)
        XCTAssertEqual(context.interpretationTimeZone, "Europe/London")
        XCTAssertEqual(capture.text, "明天交材料")
        XCTAssertEqual(capture.createdAt, date)
        XCTAssertEqual(capture.questionID, "q")
    }
    func testContextSurvivesDiskReopenAndFurtherEdits() throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appending(path: "tasks.store")
        let date = Date(timeIntervalSince1970: 1_900_000_000)
        var first: Repository? = try Repository(url: url)
        _ = try first!.capture("明天交材料", questionID: nil, now: date, timeZone: "Asia/Shanghai")
        first = nil
        let reopened = try Repository(url: url)
        let capture = try XCTUnwrap(reopened.pending().first)
        XCTAssertEqual(try reopened.captureContext(for: capture).interpretationDate, date)
        try reopened.update(capture, text: "后天交材料", now: date.addingTimeInterval(10))
        XCTAssertEqual(try reopened.captureContext(for: capture).originalText, "明天交材料")
    }
}
