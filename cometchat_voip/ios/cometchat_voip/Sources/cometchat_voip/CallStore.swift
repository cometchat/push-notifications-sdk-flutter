import Foundation

/// The one active call, the ledger of sessions already over, whose device this
/// is, and a decline still to be sent.
///
/// Backed by `UserDefaults` because the process that reports a call to CallKit
/// is often one PushKit woke in the background, and the one that answers or
/// declines it can be a relaunch. Every mutation is idempotent per session and
/// returns what it changed.
final class CallStore {

    enum State: String {
        case ringing
        case answered
    }

    struct ActiveCall: Equatable {
        let call: IncomingCall
        let state: State
        /// When the user answered, for an answered call. What tells a call
        /// still joining from one whose process died mid-call: the store
        /// outlives the process, and nothing is left to report that call's end.
        let answeredAt: Date?
    }

    /// A decline that could not be sent before the process was suspended.
    struct PendingDecline: Equatable {
        let sessionId: String
        let status: String
        let queuedAtMs: Int64
    }

    private let defaults: UserDefaults
    private let lock = NSRecursiveLock()
    private var cache: ActiveCall?
    private var cacheLoaded = false

    private let keyCall = "callStore.call"
    private let keyState = "callStore.state"
    private let keyAnsweredAt = "callStore.answeredAt"
    private let keyTerminal = "callStore.terminal"
    private let keyTerminalOrder = "callStore.terminal.order"
    private let keyUid = "callStore.uid"
    private let keyAnsweredSession = "callStore.answeredSession"
    private let keyPendingDecline = "callStore.pendingDecline"
    private let keyHeldCall = "callStore.held.call"
    private let keyHeldAnsweredAt = "callStore.held.answeredAt"

    init(defaults: UserDefaults) {
        self.defaults = defaults
    }

    /// The active call, or nil when nothing rings or is in progress.
    func get() -> ActiveCall? {
        lock.lock(); defer { lock.unlock() }
        if !cacheLoaded {
            cache = load()
            cacheLoaded = true
        }
        return cache
    }

    func isRinging(sessionId: String) -> Bool {
        guard let active = get() else { return false }
        return active.state == .ringing && active.call.sessionId == sessionId
    }

    func isAnswered(sessionId: String) -> Bool {
        guard let active = get() else { return false }
        return active.state == .answered && active.call.sessionId == sessionId
    }

    /// Whether `sessionId` is an incoming call this device knows about —
    /// ringing, answered, or the answered one held while a newer call rings.
    func isActive(sessionId: String) -> Bool {
        get()?.call.sessionId == sessionId || held?.call.sessionId == sessionId
    }

    /// Starts ringing `call`. False — do not ring — for a duplicate of a session
    /// already ringing or answered, or one already over.
    ///
    /// A different ringing session is replaced. A different *answered* one is
    /// not lost: it moves to the held slot while `call` rings, and takes the
    /// active slot back when `call` ends without being answered here (`clear`).
    /// The single slot used to be overwritten, so a second call made the
    /// package forget the live one (native iOS: "the single slot was
    /// overwritten by the ringing call").
    @discardableResult
    func setRinging(_ call: IncomingCall) -> Bool {
        lock.lock(); defer { lock.unlock() }
        if let current = get(), current.call.sessionId == call.sessionId { return false }
        if wasTerminal(sessionId: call.sessionId) { return false }
        if let current = get(), current.state == .answered {
            writeHeld(current)
        }
        write(ActiveCall(call: call, state: .ringing, answeredAt: nil))
        return true
    }

    /// The answered call kept while another one rings, or nil.
    var held: ActiveCall? {
        lock.lock(); defer { lock.unlock() }
        guard let map = defaults.dictionary(forKey: keyHeldCall) as? [String: String],
              let call = IncomingCall.fromMap(map) else { return nil }
        let answeredAt = defaults.object(forKey: keyHeldAnsweredAt) as? Double
        return ActiveCall(call: call, state: .answered, answeredAt: answeredAt.map { Date(timeIntervalSince1970: $0) })
    }

    /// Forgets the held call when it is `sessionId`: its session ended.
    func dropHeld(_ sessionId: String) {
        lock.lock(); defer { lock.unlock() }
        if held?.call.sessionId == sessionId { removeHeld() }
    }

    /// Drops the held call when it is `sessionId`, recording `reason` so a
    /// late push for it is refused — for a held call found to be over without
    /// its session ever reporting an end. Returns what was dropped.
    @discardableResult
    func clearHeld(sessionId: String, reason: String) -> ActiveCall? {
        lock.lock(); defer { lock.unlock() }
        guard let held = held, held.call.sessionId == sessionId else { return nil }
        removeHeld()
        recordTerminal(sessionId: sessionId, reason: reason)
        return held
    }

    /// Marks the ringing call answered, at `now`. Nil when nothing matched —
    /// which is how the answer path learns CallKit offers a call this process
    /// never saw. Answering twice keeps the first `answeredAt`.
    @discardableResult
    func markAnswered(sessionId: String?, now: Date = Date()) -> ActiveCall? {
        lock.lock(); defer { lock.unlock() }
        guard let current = get() else { return nil }
        if let sessionId = sessionId, current.call.sessionId != sessionId { return nil }
        if current.state == .answered { return current }
        let answered = ActiveCall(call: current.call, state: .answered, answeredAt: now)
        write(answered)
        // The user took this call over the held one (CallKit's End & Accept, or
        // the app left it): that one is not coming back.
        removeHeld()
        defaults.set(current.call.sessionId, forKey: keyAnsweredSession)
        return answered
    }

    /// Clears the active call when it is `sessionId` (or whatever it is, for
    /// nil), recording `reason` so a late duplicate is refused.
    @discardableResult
    func clear(sessionId: String?, reason: String) -> ActiveCall? {
        lock.lock(); defer { lock.unlock() }
        guard let current = get() else { return nil }
        if let sessionId = sessionId, current.call.sessionId != sessionId { return nil }
        defaults.removeObject(forKey: keyCall)
        defaults.removeObject(forKey: keyState)
        defaults.removeObject(forKey: keyAnsweredAt)
        recordTerminal(sessionId: current.call.sessionId, reason: reason)
        cache = nil
        cacheLoaded = true
        // A call that rang over a live one ended: the live one is active again.
        if let held = held, held.call.sessionId != current.call.sessionId {
            write(held)
        }
        removeHeld()
        return current
    }

    /// Remembers `sessionId` is over without it ever having been active.
    func markTerminal(sessionId: String, reason: String) {
        lock.lock(); defer { lock.unlock() }
        if let current = get(), current.call.sessionId == sessionId {
            clear(sessionId: sessionId, reason: reason)
            return
        }
        recordTerminal(sessionId: sessionId, reason: reason)
    }

    func wasTerminal(sessionId: String) -> Bool {
        terminalReason(sessionId: sessionId) != nil
    }

    func terminalReason(sessionId: String) -> String? {
        lock.lock(); defer { lock.unlock() }
        return (defaults.dictionary(forKey: keyTerminal) as? [String: String])?[sessionId]
    }

    /// Who is logged in. The ring gates run on a process PushKit woke, before
    /// any SDK is up, so this has to have been written down earlier.
    var uid: String? {
        get {
            lock.lock(); defer { lock.unlock() }
            return defaults.string(forKey: keyUid)
        }
        set {
            lock.lock(); defer { lock.unlock() }
            if let uid = newValue?.nonBlank {
                defaults.set(uid, forKey: keyUid)
            } else {
                defaults.removeObject(forKey: keyUid)
            }
        }
    }

    /// An answered call other than `sessionId` — what makes a decline `busy`.
    func answeredSessionOtherThan(_ sessionId: String) -> String? {
        lock.lock(); defer { lock.unlock() }
        guard let answered = defaults.string(forKey: keyAnsweredSession), answered != sessionId else { return nil }
        return answered
    }

    func forgetAnswered(_ sessionId: String) {
        lock.lock(); defer { lock.unlock() }
        if defaults.string(forKey: keyAnsweredSession) == sessionId {
            defaults.removeObject(forKey: keyAnsweredSession)
        }
    }

    func setPendingDecline(sessionId: String, status: String) {
        lock.lock(); defer { lock.unlock() }
        defaults.set([
            "sessionId": sessionId,
            "status": status,
            "queuedAtMs": String(Int64(Date().timeIntervalSince1970 * 1000)),
        ], forKey: keyPendingDecline)
    }

    var pendingDecline: PendingDecline? {
        lock.lock(); defer { lock.unlock() }
        guard let map = defaults.dictionary(forKey: keyPendingDecline) as? [String: String],
              let sessionId = map["sessionId"]?.nonBlank,
              let status = map["status"]?.nonBlank else { return nil }
        return PendingDecline(sessionId: sessionId, status: status, queuedAtMs: map["queuedAtMs"].flatMap { Int64($0) } ?? 0)
    }

    func clearPendingDecline(sessionId: String) {
        lock.lock(); defer { lock.unlock() }
        guard pendingDecline?.sessionId == sessionId else { return }
        defaults.removeObject(forKey: keyPendingDecline)
    }

    private func write(_ active: ActiveCall) {
        defaults.set(active.call.toMap(), forKey: keyCall)
        defaults.set(active.state.rawValue, forKey: keyState)
        if let answeredAt = active.answeredAt {
            defaults.set(answeredAt.timeIntervalSince1970, forKey: keyAnsweredAt)
        } else {
            defaults.removeObject(forKey: keyAnsweredAt)
        }
        cache = active
        cacheLoaded = true
    }

    private func writeHeld(_ active: ActiveCall) {
        defaults.set(active.call.toMap(), forKey: keyHeldCall)
        if let answeredAt = active.answeredAt {
            defaults.set(answeredAt.timeIntervalSince1970, forKey: keyHeldAnsweredAt)
        } else {
            defaults.removeObject(forKey: keyHeldAnsweredAt)
        }
    }

    private func removeHeld() {
        defaults.removeObject(forKey: keyHeldCall)
        defaults.removeObject(forKey: keyHeldAnsweredAt)
    }

    /// Anything unreadable reads as "no active call": refusing to ring is the safe failure.
    private func load() -> ActiveCall? {
        guard let stateName = defaults.string(forKey: keyState),
              let state = State(rawValue: stateName),
              let map = defaults.dictionary(forKey: keyCall) as? [String: String],
              let call = IncomingCall.fromMap(map) else { return nil }
        let answeredAt = defaults.object(forKey: keyAnsweredAt) as? Double
        return ActiveCall(call: call, state: state, answeredAt: answeredAt.map { Date(timeIntervalSince1970: $0) })
    }

    /// Session to reason, in insertion order, bounded; re-recording moves one to the back.
    private func recordTerminal(sessionId: String, reason: String) {
        var reasons = (defaults.dictionary(forKey: keyTerminal) as? [String: String]) ?? [:]
        var order = (defaults.stringArray(forKey: keyTerminalOrder) ?? []).filter { $0 != sessionId }
        order.append(sessionId)
        while order.count > RingConstants.terminalLedgerSize {
            reasons.removeValue(forKey: order.removeFirst())
        }
        reasons[sessionId] = reason
        defaults.set(reasons, forKey: keyTerminal)
        defaults.set(order, forKey: keyTerminalOrder)
    }
}
