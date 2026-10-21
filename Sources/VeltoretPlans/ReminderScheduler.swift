import Foundation
import VeltoretKit

/// In-process reminder alarms: one timer aimed at the earliest reminder. Veltoret keeps running in the menu bar
/// when its window is closed, so this covers reminders while the user is logged in; reminders that came due while
/// it wasn't running are handled by `PlansRepository.restore()` at the next start (and on wake / clock changes).
/// The timer uses wall-clock deadlines and re-checks at least every 30 minutes, so sleep and clock changes can't
/// push a reminder far off.
public final class ReminderScheduler: ReminderAlarms, @unchecked Sendable {
    static let maxWaitMs: Int64 = 30 * 60 * 1000

    private let fire: (Int64) async throws -> Void
    private let now: () -> Int64
    private var pending: [Int64: Int64] = [:]
    private let lock = NSLock()
    private let queue = DispatchQueue(label: "veltoret.reminders")
    private let timer: DispatchSourceTimer
    private var disposed = false

    public init(fire: @escaping (Int64) async throws -> Void, now: @escaping () -> Int64 = nowMillis) {
        self.fire = fire
        self.now = now
        timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(wallDeadline: .distantFuture)
        timer.setEventHandler { [weak self] in self?.tick() }
        timer.resume()
    }

    /// Ids waiting for their time (for Settings / debugging).
    public var pendingIds: Set<Int64> {
        lock.lock(); defer { lock.unlock() }
        return Set(pending.keys)
    }

    public func schedule(_ reminder: ReminderEntity) {
        lock.lock(); pending[reminder.id] = reminder.at; lock.unlock()
        arm()
    }

    public func cancel(_ id: Int64) {
        lock.lock(); pending[id] = nil; lock.unlock()
        arm()
    }

    private func arm() {
        lock.lock(); defer { lock.unlock() }
        if disposed { return }
        guard let earliest = pending.values.min() else {
            timer.schedule(wallDeadline: .distantFuture)
            return
        }
        let wait = min(max(earliest - now(), 0), Self.maxWaitMs)
        timer.schedule(wallDeadline: .now() + .milliseconds(Int(wait)))
    }

    private func tick() {
        lock.lock()
        let now = now()
        let due = pending.filter { $0.value <= now }.sorted { $0.value < $1.value }.map(\.key)
        for id in due { pending[id] = nil }
        lock.unlock()
        arm()
        for id in due {
            let fire = self.fire
            Task.detached {
                // A failed fire is retried by the next restore while it isn't stale.
                do { try await fire(id) } catch { Log.error(error, "Firing reminder \(id)") }
            }
        }
    }

    public func dispose() {
        lock.lock(); defer { lock.unlock() }
        if disposed { return }
        disposed = true
        timer.cancel()
    }

    deinit { dispose() }
}
