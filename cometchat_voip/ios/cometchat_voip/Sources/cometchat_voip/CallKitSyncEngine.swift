import Foundation

/// The native call surface, as the sync sees it.
protocol NativeCallSurface: AnyObject {
    func setMuted(sessionId: String, muted: Bool)
    func updateHasVideo(sessionId: String, hasVideo: Bool)
    func reportConnected(sessionId: String)
    func endCall(sessionId: String, reason: CallEndReason)
    func isShowing(sessionId: String) -> Bool
}

/// The Calls SDK session, as the sync drives it.
protocol SessionControl: AnyObject {
    func muteAudio()
    func unmuteAudio()
    func pauseVideo()
    func resumeVideo()
    func leaveSession()
    var isJoined: Bool { get }
}

/// CallKit and the Calls SDK session, kept in agreement both ways.
///
/// A change is mirrored only in the direction it did not come from, and every
/// mirror compares with the last known state first, so an echo never
/// ping-pongs between the two.
final class CallKitSyncEngine {

    struct State: Equatable {
        var sessionId: String
        var joined = false
        var muted = false
        var videoPaused: Bool
        var held = false
        /// What the session looked like before a cellular hold, restored after.
        var preHoldMuted = false
        var preHoldVideoPaused = false
    }

    private let native: NativeCallSurface
    private let session: SessionControl
    /// Tells the app, once per session.
    private let onEnded: (String, CallEndReason) -> Void
    private let lock = NSLock()
    private(set) var state: State?

    /// A call that ended — from the native screen, or remotely — after it was
    /// answered and before its join completed. Neither CallKit's End nor a
    /// remote end can cancel a join in flight, and a join reported without a
    /// session id has no call to attach to, so without this marker the join
    /// completed with no call tracked: no CallKit call, no screen, and audio
    /// and video still flowing. The join is left the moment it completes.
    /// One slot, like `state`.
    private var pendingLeave: (sessionId: String, since: Date)?
    /// A marker older than this is dropped: a join that has not completed
    /// within the answer-to-joined window is not coming, and a stale marker
    /// must never claim an unrelated later join.
    private let pendingLeaveTtl = TimeInterval(RingConstants.answerToJoinedCapMs) / 1000
    private let now: () -> Date

    init(native: NativeCallSurface, session: SessionControl, now: @escaping () -> Date = Date.init,
         onEnded: @escaping (String, CallEndReason) -> Void) {
        self.native = native
        self.session = session
        self.now = now
        self.onEnded = onEnded
    }

    /// Starts following an answered or outgoing call.
    func track(sessionId: String, videoPaused: Bool) {
        lock.lock(); defer { lock.unlock() }
        state = State(sessionId: sessionId, videoPaused: videoPaused)
    }

    func stopTracking(sessionId: String) {
        lock.lock(); defer { lock.unlock() }
        if state?.sessionId == sessionId { state = nil }
    }

    // MARK: - CallKit → session

    func nativeSetMuted(sessionId: String, muted: Bool) {
        guard var s = current(sessionId), s.muted != muted else { return }
        s.muted = muted
        set(s)
        if muted { session.muteAudio() } else { session.unmuteAudio() }
    }

    /// A cellular call. The Calls SDK holds one session, so hold is mute and
    /// pause on it, and unhold restores what was there before.
    func nativeSetHeld(sessionId: String, held: Bool) {
        guard var s = current(sessionId), s.held != held else { return }
        s.held = held
        if held {
            s.preHoldMuted = s.muted
            s.preHoldVideoPaused = s.videoPaused
            if !s.muted { s.muted = true; session.muteAudio() }
            if !s.videoPaused { s.videoPaused = true; session.pauseVideo() }
        } else {
            if !s.preHoldMuted, s.muted { s.muted = false; session.unmuteAudio() }
            if !s.preHoldVideoPaused, s.videoPaused { s.videoPaused = false; session.resumeVideo() }
        }
        set(s)
    }

    /// The user hung up on the native screen.
    ///
    /// An answered call still joining has no session to leave yet: the leave
    /// waits for the join (`sessionJoined` / `leaveIfEndedWhileJoining`),
    /// while CallKit and the app end the call now.
    func nativeEnd(sessionId: String) {
        guard let s = current(sessionId) else { return }
        lock.lock()
        if state?.sessionId == sessionId { state = nil }
        let joined = s.joined || session.isJoined
        if !joined { pendingLeave = (sessionId, now()) }
        lock.unlock()
        if joined { session.leaveSession() }
        onEnded(sessionId, .remoteEnded)
    }

    /// The tracked call ended for the app — a remote end, a decline
    /// elsewhere, a failure — without the sync leaving its session. A call
    /// that had not joined yet may still be joining: its join is left once it
    /// completes (`pendingLeaveSessionId`). A joined call is untouched.
    func callEnded(sessionId: String) {
        lock.lock(); defer { lock.unlock() }
        guard let s = state, s.sessionId == sessionId else { return }
        state = nil
        if !s.joined && !session.isJoined { pendingLeave = (sessionId, now()) }
    }

    /// The session whose join is to be left the moment it completes, if any.
    var pendingLeaveSessionId: String? {
        lock.lock(); defer { lock.unlock() }
        return livePendingLeave()?.sessionId
    }

    // MARK: - Session → CallKit

    /// A session joins unmuted, while CallKit can still hold a mute from
    /// before: it applies a mute to every call it shows, so a call answered
    /// under call waiting arrives muted on the native screen. The native
    /// screen is set to the session's state here so the two agree from the
    /// start.
    ///
    /// A call ended while it was joining (`pendingLeaveSessionId`) is left
    /// instead: CallKit and the app already ended it, so nothing is reported
    /// connected and the end is not repeated.
    func sessionJoined(sessionId: String) {
        if takePendingLeave(matching: { $0 == sessionId }) != nil {
            leaveJoinedAfterEnd(sessionId)
            return
        }
        guard var s = current(sessionId), !s.joined else { return }
        s.joined = true
        s.muted = false
        set(s)
        native.reportConnected(sessionId: sessionId)
        native.setMuted(sessionId: sessionId, muted: false)
    }

    func sessionAudioMuted(sessionId: String, muted: Bool) {
        guard var s = current(sessionId), s.muted != muted else { return }
        s.muted = muted
        set(s)
        native.setMuted(sessionId: sessionId, muted: muted)
    }

    func sessionVideoPaused(sessionId: String, paused: Bool) {
        guard var s = current(sessionId), s.videoPaused != paused else { return }
        s.videoPaused = paused
        set(s)
        native.updateHasVideo(sessionId: sessionId, hasVideo: !paused)
    }

    /// The session left, closed or timed out.
    func sessionEnded(sessionId: String, reason: CallEndReason) {
        guard current(sessionId) != nil else { return }
        clear(sessionId)
        native.endCall(sessionId: sessionId, reason: reason)
        onEnded(sessionId, reason)
    }

    /// The Calls SDK joined while no tracked call names the session — the
    /// join of a call that ended while it was joining. `ownedSessionId` is the
    /// session the Calls SDK holds: nil for a session joined without a
    /// prepare, which then counts as the ended call's only while nothing else
    /// is tracked. Returns the session left, or nil when the join is not the
    /// ended call's.
    @discardableResult
    func leaveIfEndedWhileJoining(ownedSessionId: String?) -> String? {
        // `takePendingLeave` holds `lock`, so `state` is read directly.
        guard let sessionId = takePendingLeave(matching: { pending in
            if let owned = ownedSessionId { return owned == pending }
            return self.state == nil
        }) else { return nil }
        leaveJoinedAfterEnd(sessionId)
        return sessionId
    }

    /// The answer-to-joined window closed for `sessionId`. True when the call
    /// had ended while joining and the join never completed: the marker is
    /// dropped, and the caller releases whatever the Calls SDK still holds for
    /// it. False when there was nothing pending for that session.
    @discardableResult
    func joinWindowExpired(sessionId: String) -> Bool {
        lock.lock(); defer { lock.unlock() }
        guard pendingLeave?.sessionId == sessionId else { return false }
        pendingLeave = nil
        return true
    }

    private func leaveJoinedAfterEnd(_ sessionId: String) {
        VoipLog.i("\(sessionId) joined after the call ended — leaving the session")
        session.leaveSession()
        if native.isShowing(sessionId: sessionId) {
            native.endCall(sessionId: sessionId, reason: .remoteEnded)
        }
    }

    /// CallKit reset: every call it showed is gone.
    func providerDidReset() {
        lock.lock(); let s = state; state = nil; lock.unlock()
        guard let s = s else { return }
        if session.isJoined { session.leaveSession() }
        onEnded(s.sessionId, .failed)
    }

    private func current(_ sessionId: String) -> State? {
        lock.lock(); defer { lock.unlock() }
        guard let s = state, s.sessionId == sessionId else { return nil }
        return s
    }

    private func set(_ s: State) {
        lock.lock(); defer { lock.unlock() }
        if state?.sessionId == s.sessionId { state = s }
    }

    /// Called with `lock` held. Drops an expired marker.
    private func livePendingLeave() -> (sessionId: String, since: Date)? {
        guard let p = pendingLeave else { return nil }
        guard now().timeIntervalSince(p.since) < pendingLeaveTtl else {
            pendingLeave = nil
            return nil
        }
        return p
    }

    private func takePendingLeave(matching: (String) -> Bool) -> String? {
        lock.lock(); defer { lock.unlock() }
        guard let p = livePendingLeave(), matching(p.sessionId) else { return nil }
        pendingLeave = nil
        return p.sessionId
    }

    private func clear(_ sessionId: String) {
        lock.lock(); defer { lock.unlock() }
        if state?.sessionId == sessionId { state = nil }
    }
}
