import Foundation
import VoiceTodoCore

/// Bounds the whole request, including protocol retries. A task group would
/// still await a child that ignores cancellation; this race releases the caller
/// immediately and discards late results. Only the caller may commit tasks.
enum AIRequestDeadline {
    static let defaultSeconds: TimeInterval = 8

    static func run<Value: Sendable>(seconds: TimeInterval = defaultSeconds,
                                    operation: @escaping @Sendable () async throws -> Value) async throws -> Value {
        let race = DeadlineRace<Value>()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                guard race.install(continuation) else { return }
                let request = Task {
                    do {
                        try Task.checkCancellation()
                        race.finish(.success(try await operation()))
                    } catch { race.finish(.failure(error)) }
                }
                let timer = Task {
                    do {
                        try await Task.sleep(for: .seconds(max(0, seconds)))
                        race.finish(.failure(AIServiceError(.temporary, "AI 响应超时，请稍后重试。")))
                    } catch { /* The request or cancellation won the race. */ }
                }
                race.attach([request, timer])
            }
        } onCancel: { race.finish(.failure(CancellationError())) }
    }
}

private final class DeadlineRace<Value: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var result: Result<Value, Error>?
    private var continuation: CheckedContinuation<Value, Error>?
    private var tasks: [Task<Void, Never>] = []

    func install(_ continuation: CheckedContinuation<Value, Error>) -> Bool {
        let completed = lock.withLock { () -> Result<Value, Error>? in
            if let result { return result }
            self.continuation = continuation
            return nil
        }
        if let completed { continuation.resume(with: completed); return false }
        return true
    }
    func attach(_ tasks: [Task<Void, Never>]) {
        let finished = lock.withLock {
            if result != nil { return true }
            self.tasks = tasks
            return false
        }
        if finished { tasks.forEach { $0.cancel() } }
    }
    func finish(_ result: Result<Value, Error>) {
        let pending = lock.withLock { () -> (CheckedContinuation<Value, Error>?, [Task<Void, Never>]) in
            guard self.result == nil else { return (nil, []) }
            self.result = result
            let pending = (continuation, tasks)
            continuation = nil; tasks = []
            return pending
        }
        pending.1.forEach { $0.cancel() }
        pending.0?.resume(with: result)
    }
}
