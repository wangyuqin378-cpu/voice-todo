import Foundation
import SwiftData

@Model public final class StoredTask {
    @Attribute(.unique) public var id: String
    public var payload: Data
    public init(id: String, payload: Data) { self.id = id; self.payload = payload }
}
@Model public final class StoredMetadata {
    @Attribute(.unique) public var key: String
    public var payload: Data
    public init(key: String, payload: Data) { self.key = key; self.payload = payload }
}
@Model public final class InputCapture {
    @Attribute(.unique) public var id: String
    public var text: String
    public var createdAt: Date
    public var questionID: String?
    public var status: String
    public var issue: String
    public init(id: String = UUID().uuidString, text: String, questionID: String?, createdAt: Date = .now) {
        self.id = id; self.text = text; self.questionID = questionID; self.createdAt = createdAt
        self.status = "pending"; self.issue = ""
    }
}

public struct CaptureContext: Codable, Equatable, Sendable {
    public var originalText: String
    public var originalDate: Date
    public var originalTimeZone: String
    public var interpretationDate: Date
    public var interpretationTimeZone: String
    public var question: FollowUp?
    public var relatedTasks: [TodoItem]?
    public init(text: String, date: Date, timeZone: String) {
        originalText = text; originalDate = date; originalTimeZone = timeZone
        interpretationDate = date; interpretationTimeZone = timeZone
    }
}

@MainActor public final class Repository {
    public let container: ModelContainer
    public let context: ModelContext
    public init(inMemory: Bool = false, url: URL? = nil) throws {
        let schema = Schema([StoredTask.self, StoredMetadata.self, InputCapture.self])
        let config: ModelConfiguration
        if let url { config = ModelConfiguration(schema: schema, url: url, cloudKitDatabase: .none) }
        else { config = ModelConfiguration(schema: schema, isStoredInMemoryOnly: inMemory, cloudKitDatabase: .none) }
        container = try ModelContainer(for: schema, configurations: [config])
        context = ModelContext(container); context.autosaveEnabled = false
    }
    public func load() throws -> Workspace {
        let meta = try context.fetch(FetchDescriptor<StoredMetadata>()).first { $0.key == "workspace.v1" }
        var state = try meta.map { try JSONDecoder().decode(Workspace.self, from: $0.payload) } ?? Workspace()
        state.tasks = try context.fetch(FetchDescriptor<StoredTask>()).map { try JSONDecoder().decode(TodoItem.self, from: $0.payload) }
            .sorted { $0.createdAt < $1.createdAt }
        return state
    }
    public func capture(_ text: String, questionID: String?, now: Date = .now,
                        timeZone: String = TimeZone.current.identifier, id: String = UUID().uuidString,
                        queued: Bool = false) throws -> InputCapture {
        if let existing = try context.fetch(FetchDescriptor<InputCapture>()).first(where: { $0.id == id }) {
            guard existing.text == text else { throw UserFacingError("同一段输入发生冲突，未重复保存，请检查原文。") }
            return existing
        }
        let record = InputCapture(id: id, text: text, questionID: questionID, createdAt: now)
        if queued { record.status = "queued" }
        context.insert(record)
        do {
            var origin = CaptureContext(text: text, date: now, timeZone: timeZone)
            if let questionID {
                let workspace = try load()
                origin.question = workspace.questions.first { $0.id == questionID }
                origin.relatedTasks = workspace.tasks.filter { origin.question?.taskIDs.contains($0.id) == true }
            }
            try writeCaptureContext(origin, for: record)
            try context.save(); return record
        }
        catch { context.rollback(); throw error }
    }
    public func captureContext(for capture: InputCapture) throws -> CaptureContext {
        let key = "capture.context.\(capture.id)"
        let metadata = try context.fetch(FetchDescriptor<StoredMetadata>()).first { $0.key == key }
        if let metadata { return try JSONDecoder().decode(CaptureContext.self, from: metadata.payload) }
        // Older captures recorded their date but not timezone. Preserve the date;
        // the current timezone is the only available fallback for those records.
        return CaptureContext(text: capture.text, date: capture.createdAt, timeZone: TimeZone.current.identifier)
    }
    private func writeCaptureContext(_ value: CaptureContext, for capture: InputCapture) throws {
        let key = "capture.context.\(capture.id)"
        let data = try JSONEncoder().encode(value)
        if let stored = try context.fetch(FetchDescriptor<StoredMetadata>()).first(where: { $0.key == key }) { stored.payload = data }
        else { context.insert(StoredMetadata(key: key, payload: data)) }
    }
    public func pending() throws -> [InputCapture] {
        try context.fetch(FetchDescriptor<InputCapture>(sortBy: [SortDescriptor(\.createdAt)]))
            .filter { $0.status == "pending" || $0.status == "failed" || $0.status == "queued" }
    }
    public func fail(_ capture: InputCapture, message: String) throws {
        capture.status = "failed"; capture.issue = message
        do { try context.save() } catch { context.rollback(); throw error }
    }
    public func update(_ capture: InputCapture, text: String, now: Date = .now,
                       timeZone: String = TimeZone.current.identifier, detachQuestion: Bool = false) throws {
        do {
            var origin = try captureContext(for: capture)
            origin.interpretationDate = now; origin.interpretationTimeZone = timeZone
            try writeCaptureContext(origin, for: capture)
            capture.text = text; capture.status = "pending"; capture.issue = ""
            if detachQuestion { capture.questionID = nil }
            try context.save()
        } catch { context.rollback(); throw error }
    }
    public func dismiss(_ capture: InputCapture) throws {
        capture.status = "dismissed"
        do { try context.save() } catch { context.rollback(); throw error }
    }
    public func save(_ workspace: Workspace, capture: InputCapture? = nil) throws {
        do {
            let existing = try context.fetch(FetchDescriptor<StoredTask>())
            let indexed = Dictionary(uniqueKeysWithValues: existing.map { ($0.id, $0) })
            let ids = Set(workspace.tasks.map(\.id))
            for old in existing where !ids.contains(old.id) { context.delete(old) }
            let encoder = JSONEncoder()
            for task in workspace.tasks {
                let payload = try encoder.encode(task)
                if let record = indexed[task.id] { record.payload = payload }
                else { context.insert(StoredTask(id: task.id, payload: payload)) }
            }
            var metadata = workspace; metadata.tasks = []
            let payload = try encoder.encode(metadata)
            if let record = try context.fetch(FetchDescriptor<StoredMetadata>()).first(where: { $0.key == "workspace.v1" }) {
                record.payload = payload
            } else { context.insert(StoredMetadata(key: "workspace.v1", payload: payload)) }
            capture?.status = "applied"; capture?.issue = ""
            try context.save()
        } catch { context.rollback(); throw error }
    }
}
