import Foundation
import UIKit

/// Delivers a decline even if the app is suspended the instant after the tap.
///
/// The user declines on the lock screen, CallKit hands the app a
/// `CXEndCallAction`, the app fulfils it — and iOS is then free to suspend the
/// process with the request still on the wire. A background task is held from
/// before the request until its reply, and a decline that still did not go out
/// is persisted and replayed on the next launch.
final class DeclineQueue {

    private let sdk: CallsSdkPort
    private let store: CallStore
    private let scheduler: RingScheduler
    private let config: () -> VoipConfig?

    private let lock = NSLock()
    private var inFlight: Set<String> = []

    init(sdk: CallsSdkPort, store: CallStore, scheduler: RingScheduler, config: @escaping () -> VoipConfig?) {
        self.sdk = sdk
        self.store = store
        self.scheduler = scheduler
        self.config = config
    }

    /// Persisted first, so dying before the request goes out loses nothing.
    func enqueue(sessionId: String, status: String) {
        lock.lock()
        let already = !inFlight.insert(sessionId).inserted
        lock.unlock()
        guard !already else { return }
        store.setPendingDecline(sessionId: sessionId, status: status)
        deliver(sessionId: sessionId, status: status)
    }

    /// Sends a decline an earlier process could not.
    func replayPendingIfAny() {
        guard let pending = store.pendingDecline else { return }
        // Older than two ring windows is not worth sending: the caller's own
        // timeout ended it long ago.
        let ageMs = Int64(Date().timeIntervalSince1970 * 1000) - pending.queuedAtMs
        guard ageMs < RingConstants.defaultRingTimeoutMs * 2 else {
            store.clearPendingDecline(sessionId: pending.sessionId)
            return
        }
        lock.lock(); inFlight.insert(pending.sessionId); lock.unlock()
        VoipLog.i("replaying the decline for \(pending.sessionId)")
        deliver(sessionId: pending.sessionId, status: pending.status)
    }

    private func deliver(sessionId: String, status: String) {
        var finished = false
        var task: UIBackgroundTaskIdentifier = .invalid
        let finish: (String, Bool) -> Void = { [weak self] outcome, delivered in
            guard !finished else { return }
            finished = true
            VoipLog.i("decline \(sessionId): \(outcome)")
            if delivered { self?.store.clearPendingDecline(sessionId: sessionId) }
            self?.forget(sessionId)
            if task != .invalid {
                UIApplication.shared.endBackgroundTask(task)
                task = .invalid
            }
        }

        // Taken before anything asynchronous: the window it protects opens the
        // moment the CallKit action is fulfilled, which may already have happened.
        task = UIApplication.shared.beginBackgroundTask(withName: "cometchat-voip-decline") {
            finish("the background task expired — kept for replay", false)
        }
        // A backstop: a background task never ended is worse than a decline
        // never confirmed.
        _ = scheduler.schedule(after: TimeInterval(RingConstants.declineBudgetMs) / 1000) {
            finish("no reply from endCall — kept for replay", false)
        }

        guard let config = config() else {
            finish("no configuration — kept for replay", false)
            return
        }
        sdk.ensureInitialised(config: config) { [weak self] ok in
            guard let self = self else { return }
            guard ok else { finish("the Calls SDK could not start — kept for replay", false); return }
            guard self.sdk.isLoggedIn else { finish("not logged in — kept for replay", false); return }
            self.sdk.endCall(sessionId: sessionId, status: status) { delivered in
                DispatchQueue.main.async {
                    finish(delivered ? "\(status) delivered" : "endCall failed — kept for replay", delivered)
                }
            }
        }
    }

    private func forget(_ sessionId: String) {
        lock.lock(); inFlight.remove(sessionId); lock.unlock()
    }
}
