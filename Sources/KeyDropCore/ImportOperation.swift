import Foundation

/// Shares cancellation between synchronous import stages and their network requests.
public final class ImportOperation: @unchecked Sendable {
    public enum Stage: Equatable, Sendable {
        case fetchingSubscription, parsing, verifying, choosingModels, writing
    }

    @TaskLocal static var current: ImportOperation?

    private let lock = NSLock()
    private var cancelled = false
    private var writing = false
    private var handlers: [UUID: () -> Void] = [:]
    private let onStage: (Stage) -> Void

    public init(onStage: @escaping (Stage) -> Void = { _ in }) {
        self.onStage = onStage
    }

    public var isCancelled: Bool {
        lock.lock(); defer { lock.unlock() }
        return cancelled
    }

    /// Returns false once configuration writes have started.
    @discardableResult
    public func cancel() -> Bool {
        lock.lock()
        guard !writing, !cancelled else { lock.unlock(); return false }
        cancelled = true
        let pending = Array(handlers.values)
        handlers.removeAll()
        lock.unlock()
        for handler in pending { handler() }
        return true
    }

    func advance(to stage: Stage) throws {
        lock.lock()
        guard !cancelled else { lock.unlock(); throw CancellationError() }
        if stage == .writing { writing = true }
        lock.unlock()
        onStage(stage)
    }

    func checkCancellation() throws {
        if isCancelled { throw CancellationError() }
    }

    // A nil registration means the request must not start.
    func register(_ handler: @escaping () -> Void) -> UUID? {
        lock.lock(); defer { lock.unlock() }
        guard !cancelled else { return nil }
        let id = UUID()
        handlers[id] = handler
        return id
    }

    func unregister(_ id: UUID) {
        lock.lock(); defer { lock.unlock() }
        handlers.removeValue(forKey: id)
    }
}
