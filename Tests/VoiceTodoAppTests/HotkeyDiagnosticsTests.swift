import AppKit
import XCTest
@testable import VoiceTodoApp

@MainActor final class HotkeyDiagnosticsTests: XCTestCase {
    func testDifferentClockFnIsRecordedAndDuplicateCopiesStaySeparate() throws {
        let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appending(path: "hotkey.json")
        let log = HotkeyDiagnostics(url: url)
        let key = GlobalHotkey(); key.useInputMethod = true
        key.onReceipt = { log.receive(source: $0, outcome: $1, fnDown: $2, timestampAheadBy: $3) }
        var presses = 0
        key.onFnPress = { presses += 1 }
        let fn = NSEvent.ModifierFlags.function.rawValue
        key.receive(.keyUp, code: 0, flags: 0, timestamp: 100)
        key.receive(.flagsChanged, code: 63, flags: fn, timestamp: 1)
        XCTAssertEqual(presses, 1)
        XCTAssertEqual(log.snapshot.fnReceived, 1)
        XCTAssertEqual(log.snapshot.lastFn?.outcome, .accepted)
        let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .iso8601
        let saved = try decoder.decode(HotkeyDiagnostics.Snapshot.self, from: Data(contentsOf: url))
        XCTAssertEqual(saved.lastFn?.outcome, .accepted)
        key.receive(.flagsChanged, code: 63, flags: 0, timestamp: 1.1)
        key.receive(.flagsChanged, code: 63, flags: fn, timestamp: 101)
        key.receive(.flagsChanged, code: 63, flags: fn, timestamp: 101, source: .localMonitor)
        XCTAssertEqual(presses, 2)
        XCTAssertEqual(log.snapshot.lastFn?.outcome, .duplicate)
        XCTAssertEqual(log.snapshot.sources["eventTap"]?.stale, 0)
        XCTAssertEqual(log.snapshot.sources["localMonitor"]?.duplicate, 1)
    }

    func testOnlyBoundedHealthFieldsPersistAndNewRunDoesNotInheritOldReceipts() throws {
        let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appending(path: "hotkey.json")
        let log = HotkeyDiagnostics(url: url)
        for _ in 0..<100 { log.receive(source: .eventTap, outcome: .accepted, fnDown: nil, timestampAheadBy: 0) }
        log.connection(true, detail: "connected", inputMethodEnabled: true)
        let data = try Data(contentsOf: url)
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertEqual(Set(object.keys), ["build", "processID", "startedAt", "updatedAt", "connected", "connection", "inputMethodEnabled", "sources", "fnReceived"])
        let sources = try XCTUnwrap(object["sources"] as? [String: [String: Any]])
        XCTAssertEqual(Set(sources["eventTap"]!.keys), ["count", "accepted", "stale", "duplicate", "lastAt", "timestampAheadBy"])
        XCTAssertEqual(log.snapshot.sources["eventTap"]?.count, 100)
        XCTAssertLessThan(data.count, 1500)
        XCTAssertEqual((try FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions] as? NSNumber)?.intValue, 0o600)
        let fresh = HotkeyDiagnostics(url: url)
        fresh.connection(true, detail: "connected", inputMethodEnabled: true)
        XCTAssertTrue(fresh.snapshot.sources.isEmpty)
        XCTAssertEqual(fresh.snapshot.fnReceived, 0)
    }
}
