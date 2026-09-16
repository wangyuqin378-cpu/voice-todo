import Foundation

/// A bounded health snapshot, never key codes, typed text, or an event history.
@MainActor final class HotkeyDiagnostics {
    enum Source: String, Codable { case eventTap, localMonitor }
    enum Outcome: String, Codable { case accepted, stale, duplicate }
    struct Receipt: Codable {
        var count = 0
        var accepted = 0
        var stale = 0
        var duplicate = 0
        var lastAt: Date?
        var timestampAheadBy: Double = 0
    }
    struct FnReceipt: Codable {
        var at: Date
        var source: Source
        var outcome: Outcome
        var down: Bool
    }
    struct Snapshot: Codable {
        var build: String
        var processID: Int32
        var startedAt: Date
        var updatedAt: Date
        var connected = false
        var connection = "尚未连接"
        var inputMethodEnabled = false
        var sources: [String: Receipt] = [:]
        var fnReceived = 0
        var lastFn: FnReceipt?
    }
    private(set) var snapshot: Snapshot
    private let url: URL
    private let now: () -> Date
    private var lastSavedAt = Date.distantPast

    init(url: URL, now: @escaping () -> Date = { .now }) {
        self.url = url; self.now = now
        snapshot = Snapshot(build: Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "test",
                            processID: ProcessInfo.processInfo.processIdentifier, startedAt: now(), updatedAt: now())
    }
    func connection(_ enabled: Bool, detail: String, inputMethodEnabled: Bool) {
        snapshot.connected = enabled; snapshot.connection = detail
        snapshot.inputMethodEnabled = inputMethodEnabled
        save()
    }
    func receive(source: Source, outcome: Outcome, fnDown: Bool?, timestampAheadBy: Double) {
        let time = now()
        var receipt = snapshot.sources[source.rawValue, default: Receipt()]
        receipt.count += 1; receipt.lastAt = time
        receipt.timestampAheadBy = timestampAheadBy.isFinite ? timestampAheadBy : 0
        switch outcome {
        case .accepted: receipt.accepted += 1
        case .stale: receipt.stale += 1
        case .duplicate: receipt.duplicate += 1
        }
        snapshot.sources[source.rawValue] = receipt
        if let fnDown {
            snapshot.fnReceived += 1
            snapshot.lastFn = FnReceipt(at: time, source: source, outcome: outcome, down: fnDown)
        }
        // Fn evidence is immediate; ordinary input only updates bounded totals.
        if fnDown != nil || time.timeIntervalSince(lastSavedAt) >= 2 { save() }
    }
    private func save() {
        snapshot.updatedAt = now()
        do {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            let encoder = JSONEncoder(); encoder.dateEncodingStrategy = .iso8601
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            try encoder.encode(snapshot).write(to: url, options: .atomic)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
            lastSavedAt = snapshot.updatedAt
        } catch { /* Diagnostics must never interrupt input handling. */ }
    }
}
