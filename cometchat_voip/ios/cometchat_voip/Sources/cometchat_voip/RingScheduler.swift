import Foundation

/// Where delayed work runs.
protocol RingScheduler: AnyObject {
    /// Runs `work` after `delay` seconds and returns a handle that cancels it.
    func schedule(after delay: TimeInterval, _ work: @escaping () -> Void) -> RingScheduledWork
}

protocol RingScheduledWork: AnyObject {
    func cancel()
}

/// The clock.
protocol RingClock: AnyObject {
    var nowMs: Int64 { get }
}

final class SystemRingClock: RingClock {
    var nowMs: Int64 { Int64(Date().timeIntervalSince1970 * 1000) }
}

final class MainQueueRingScheduler: RingScheduler {

    private final class Work: RingScheduledWork {
        let item: DispatchWorkItem
        init(_ item: DispatchWorkItem) { self.item = item }
        func cancel() { item.cancel() }
    }

    func schedule(after delay: TimeInterval, _ work: @escaping () -> Void) -> RingScheduledWork {
        let item = DispatchWorkItem(block: work)
        DispatchQueue.main.asyncAfter(deadline: .now() + max(0, delay), execute: item)
        return Work(item)
    }
}

/// The ring deadline, armed at the call's own deadline (`initiatedAt +
/// ringTimeout`) rather than "now plus the timeout": a push delivered late
/// would otherwise restart the whole window on a call the caller gave up on.
/// CallKit never times a call out by itself.
final class RingExpiry {

    private let scheduler: RingScheduler
    private let clock: RingClock
    private let lock = NSLock()
    private var armed: [String: RingScheduledWork] = [:]

    init(scheduler: RingScheduler, clock: RingClock) {
        self.scheduler = scheduler
        self.clock = clock
    }

    /// Returns the time left to ring, or 0 when the deadline has passed —
    /// in which case nothing is armed and the call should not be ringing.
    @discardableResult
    func arm(_ call: IncomingCall, onExpire: @escaping (String) -> Void) -> Int64 {
        cancel(sessionId: call.sessionId)
        let remaining = call.expiresAtMs - clock.nowMs
        guard remaining > 0 else { return 0 }
        let sessionId = call.sessionId
        let work = scheduler.schedule(after: TimeInterval(remaining + RingConstants.expirySlackMs) / 1000) { [weak self] in
            guard let self = self, self.forget(sessionId: sessionId) else { return }
            onExpire(sessionId)
        }
        lock.lock()
        armed[sessionId] = work
        lock.unlock()
        return remaining
    }

    func cancel(sessionId: String) {
        lock.lock()
        let work = armed.removeValue(forKey: sessionId)
        lock.unlock()
        work?.cancel()
    }

    /// True when the session was still armed — nobody cancelled it first.
    private func forget(sessionId: String) -> Bool {
        lock.lock(); defer { lock.unlock() }
        return armed.removeValue(forKey: sessionId) != nil
    }
}
