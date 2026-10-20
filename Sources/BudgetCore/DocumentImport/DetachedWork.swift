import Foundation

/// Work run off the caller's actor in a detached task that still follows the caller's
/// cancellation: a detached task doesn't inherit it, so cancelling the awaiting task (Cancel,
/// Discard) cancels the detached one too, and the work stops with `CancellationError` (as
/// `ImportPipeline` does).
public enum DetachedWork {
    public static func run<T: Sendable>(priority: TaskPriority? = nil,
                                        _ body: @escaping @Sendable () async throws -> T) async throws -> T {
        let task = Task.detached(priority: priority, operation: body)
        return try await withTaskCancellationHandler {
            try await task.value
        } onCancel: {
            task.cancel()
        }
    }
}
