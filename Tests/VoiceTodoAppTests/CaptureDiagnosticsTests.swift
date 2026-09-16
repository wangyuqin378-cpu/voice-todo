import XCTest
@testable import VoiceTodoApp

@MainActor final class CaptureDiagnosticsTests: XCTestCase {
    func testTerminalReasonAndOnlyMetadataSurviveReopen() throws {
        let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appending(path: "diagnostics.json")
        let log = CaptureDiagnostics(url: url)
        log.start(id: "session-1", source: "test.editor", fieldReadable: true)
        log.record(.bound, id: "session-1")
        log.record(.released, id: "session-1")
        log.record(.inputMethodFront, id: "session-1", application: "test.inputmethod")
        for _ in 0..<5 { log.record(.clipboardChanged, id: "session-1", once: true) }
        log.record(.applicationChanged, id: "session-1", application: "test.other")
        let reopened = CaptureDiagnostics(url: url)
        XCTAssertEqual(reopened.sessions.count, 1)
        XCTAssertEqual(reopened.sessions[0].events.last?.stage, .applicationChanged)
        XCTAssertEqual(reopened.sessions[0].events.filter { $0.stage == .clipboardChanged }.count, 1)
        let rows = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [[String: Any]])
        XCTAssertEqual(Set(rows[0].keys), ["id", "startedAt", "sourceApplication", "fieldReadable", "events", "build"])
        let event = try XCTUnwrap((rows[0]["events"] as? [[String: Any]])?.last)
        XCTAssertEqual(Set(event.keys), ["stage", "at", "application"])
        XCTAssertEqual((try FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions] as? NSNumber)?.intValue, 0o600)
    }
    func testHistoryBoundedAndProcessingResultUsesCaptureID() throws {
        let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let log = CaptureDiagnostics(url: root.appending(path: "diagnostics.json"))
        for i in 0..<16 { log.start(id: "s\(i)", source: nil, fieldReadable: false) }
        log.record(.processing, id: "s14")
        log.record(.processingFailed, id: "s14")
        XCTAssertEqual(log.sessions.count, 12)
        XCTAssertEqual(log.sessions.first?.id, "s4")
        XCTAssertEqual(log.sessions.first { $0.id == "s14" }?.events.last?.stage, .processingFailed)
        XCTAssertEqual(log.sessions.last?.events.last?.stage, .pressed)
    }
}
