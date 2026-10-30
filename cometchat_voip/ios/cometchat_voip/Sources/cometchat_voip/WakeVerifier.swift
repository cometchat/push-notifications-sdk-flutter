import Foundation

/// Connects to the call while the phone rings.
///
/// Two jobs. Speed: answering then only adds media. And truth: a connect that
/// succeeds proves the call is alive and fires `onParticipantConnected` on the
/// caller, so they know it is ringing.
///
/// Dismissing a live call is far worse than ringing a dead one a little
/// longer, so nothing here ends the ring on an inconclusive result — a failed
/// connect, an unreachable server or a timeout all leave it ringing to its
/// deadline, where the expiry ends it.
final class WakeVerifier {

    private let sdk: CallsSdkPort
    private let scheduler: RingScheduler
    private let clock: RingClock
    private let config: () -> VoipConfig?

    private let lock = NSLock()
    /// Sessions being verified, so a duplicate push cannot start a second attempt.
    private var inFlight: [String: Attempt] = [:]

    private final class Attempt {
        let call: IncomingCall
        var attempts = 0
        var budget: RingScheduledWork?
        let startedAtMs: Int64
        init(call: IncomingCall, startedAtMs: Int64) {
            self.call = call
            self.startedAtMs = startedAtMs
        }
    }

    /// How long the last wake took, in milliseconds: bringing the Calls SDK up
    /// — through Dart now — and the connect that followed. Nil until a push has
    /// woken this process.
    ///
    /// The one pair of numbers that tells a slow ring from a ring that never
    /// started, which is why `lastWakeTiming` exposes it.
    private(set) var sdkReadyMs: Int64?
    private(set) var connectMs: Int64?

    init(sdk: CallsSdkPort, scheduler: RingScheduler, clock: RingClock, config: @escaping () -> VoipConfig?) {
        self.sdk = sdk
        self.scheduler = scheduler
        self.clock = clock
        self.config = config
    }

    func start(_ call: IncomingCall) {
        lock.lock()
        guard inFlight[call.sessionId] == nil else { lock.unlock(); return }
        let attempt = Attempt(call: call, startedAtMs: clock.nowMs)
        inFlight[call.sessionId] = attempt
        lock.unlock()

        guard let config = config(), clock.nowMs < call.expiresAtMs else {
            finish(call.sessionId)
            return
        }
        sdk.ensureInitialised(config: config) { [weak self] ok in
            guard let self = self else { return }
            guard ok else {
                VoipLog.w("Calls SDK unavailable — \(call.sessionId) rings on to its deadline")
                self.finish(call.sessionId)
                return
            }
            self.attemptConnect(attempt)
        }
    }

    /// Answered, declined or ended: stop. The ring's exit releases the session.
    func cancel(sessionId: String) {
        finish(sessionId)
    }

    private func attemptConnect(_ attempt: Attempt) {
        let call = attempt.call
        guard isCurrent(attempt) else { return }
        if clock.nowMs >= call.expiresAtMs { finish(call.sessionId); return }

        // Another call already holds the SDK's one session. Connecting would
        // disturb it, and the user is plainly reachable.
        if sdk.isSessionActive, let owned = sdk.ownedSessionId, owned != call.sessionId {
            VoipLog.d("session \(owned) is active — not preparing \(call.sessionId)")
            finish(call.sessionId)
            return
        }

        attempt.attempts += 1
        if attempt.attempts == 1 {
            // Everything before the first connect is Dart and the SDK coming up.
            sdkReadyMs = clock.nowMs - attempt.startedAtMs
        }
        let connectStartedMs = clock.nowMs
        var settled = false
        let settle: (ConnectResult?) -> Void = { [weak self] result in
            guard let self = self, !settled else { return }
            settled = true
            attempt.budget?.cancel()
            attempt.budget = nil
            self.connectMs = self.clock.nowMs - connectStartedMs
            self.handle(result, attempt: attempt)
        }
        // No callback inside the budget means unreachable, not dead.
        attempt.budget = scheduler.schedule(after: TimeInterval(RingConstants.verifyBudgetMs) / 1000) { settle(nil) }
        sdk.connect(call) { result in
            DispatchQueue.main.async { settle(result) }
        }
    }

    private func handle(_ result: ConnectResult?, attempt: Attempt) {
        let call = attempt.call
        guard isCurrent(attempt) else { return }
        switch result {
        case .connected?:
            VoipLog.i("\(call.sessionId) is alive and prepared")
            finish(call.sessionId)

        case .failed(let code, _, let retryable)?:
            if retryable, attempt.attempts <= RingConstants.verifyMaxRetries {
                // A cold process: the login is still being restored.
                _ = scheduler.schedule(after: TimeInterval(RingConstants.verifyRetryIntervalMs) / 1000) { [weak self] in
                    self?.attemptConnect(attempt)
                }
                return
            }
            VoipLog.d("connect failed for \(call.sessionId): \(code) — ringing on")
            finish(call.sessionId)

        case nil:
            VoipLog.w("connect for \(call.sessionId) did not answer — ringing on")
            finish(call.sessionId)
        }
    }

    private func isCurrent(_ attempt: Attempt) -> Bool {
        lock.lock(); defer { lock.unlock() }
        return inFlight[attempt.call.sessionId] === attempt
    }

    private func finish(_ sessionId: String) {
        lock.lock()
        let attempt = inFlight.removeValue(forKey: sessionId)
        lock.unlock()
        attempt?.budget?.cancel()
    }
}
