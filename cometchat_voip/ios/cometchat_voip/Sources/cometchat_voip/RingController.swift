import Foundation

/// The parts of a ring other components own. The controller decides *when*
/// they happen; `VoipCore` does them.
protocol RingHooks: AnyObject {
    /// CallKit accepted the report: prepare the call and hand it to the Calls SDK.
    func onRingStarted(_ call: IncomingCall)
    /// Every exit: answer, decline, timeout, remote end, replacement.
    func onRingStopped(sessionId: String, reason: CallEndReason)
    /// The user answered. The join takes the prepared session over.
    func onAnswered(_ call: IncomingCall)
    /// The user declined. `status` is one of `RingConstants.Status`.
    func onDeclined(sessionId: String, status: String)
    /// The call is over for the app. Never `.answered`.
    func onCallEnded(_ call: IncomingCall, reason: CallEndReason)
    /// Whether the Calls SDK is still joined to `sessionId`.
    func isSessionJoined(sessionId: String) -> Bool
    /// Whether the answered call `sessionId` has joined, by any signal that
    /// says so — a join without a prepare leaves the Calls SDK's session id
    /// nil, which `isSessionJoined` alone reads as not joined.
    func hasJoined(_ sessionId: String) -> Bool
    /// Whether the Calls SDK is joined to a call other than `sessionId`, placed
    /// or answered — what makes a decline `busy`.
    func isInAnotherCall(than sessionId: String) -> Bool
    /// The terminal push for a call this user placed: hand it to the Calls SDK
    /// with the push's action, so the caller hears how its call ended.
    func onOwnCallEnded(_ call: IncomingCall, action: String)
}

/// The one funnel every ring transition goes through: the push, CallKit's
/// actions, the expiry and the Calls SDK all end up here, so the behaviour is
/// the same whichever the user touched. Every operation is idempotent per
/// session: a duplicate push, a double-tapped Decline and an answer racing the
/// timeout are all harmless.
final class RingController {

    let store: CallStore
    let ui: IncomingCallUi
    let expiry: RingExpiry
    weak var hooks: RingHooks?

    init(store: CallStore, ui: IncomingCallUi, expiry: RingExpiry) {
        self.store = store
        self.ui = ui
        self.expiry = expiry
    }

    /// A call reached the device: ring it, unless it is already known or over.
    ///
    /// `completion` always runs, and always after a report to CallKit — never
    /// before and never instead. On the VoIP path it is PushKit's
    /// acknowledgement, and iOS terminates an app that acknowledges without
    /// reporting, then stops delivering its VoIP pushes.
    func startRinging(_ call: IncomingCall, completion: @escaping () -> Void) {
        dropAnsweredCallsNoLongerInASession()
        let previous = store.get()

        guard store.setRinging(call) else {
            VoipLog.d("\(call.sessionId) is a duplicate or already over; reporting and ending")
            ui.reportAndEndImmediately(callerName: call.callerName, hasVideo: call.isVideo, reason: .filtered, completion: completion)
            return
        }

        if let previous = previous, previous.call.sessionId != call.sessionId,
           previous.state == .ringing {
            // One ring at a time: a replaced *ringing* call must not stay
            // answerable in the system UI for a call this package has
            // forgotten. An answered call is the user's live call and stays on
            // CallKit — the store holds it while this one rings. Ending it here
            // ended the live call and took its audio (native iOS hit and fixed
            // the same).
            stopRinging(sessionId: previous.call.sessionId, reason: .remoteEnded)
        }

        ui.reportIncomingCall(call) { [weak self] error in
            guard let self = self else { completion(); return }
            if let error = error {
                self.handleReportFailure(call, error: error)
                completion()
                return
            }
            // PushKit's acknowledgement first. Then, with the ring up, the
            // expiry and the hooks.
            completion()
            let remaining = self.expiry.arm(call) { [weak self] sessionId in self?.timeout(sessionId: sessionId) }
            if remaining <= 0 {
                self.timeout(sessionId: call.sessionId)
                return
            }
            self.hooks?.onRingStarted(call)
        }
    }

    /// An answered call is in progress only while the Calls SDK is in its
    /// session, or within the answer-to-joined window while it is still
    /// joining. The store outlives the process, so a call whose process ended
    /// mid-call is still recorded as answered with nothing left to report its
    /// end. Kept, it would make every later call ring as call waiting on top of
    /// it, and come back into the active slot each time that call ended
    /// (native iOS hit and fixed the same, push-notifications-sdk-ios #6).
    func dropAnsweredCallsNoLongerInASession(now: Date = Date()) {
        func over(_ active: CallStore.ActiveCall) -> Bool {
            if hooks?.hasJoined(active.call.sessionId) ?? false { return false }
            guard let answeredAt = active.answeredAt else { return true }
            return now.timeIntervalSince(answeredAt) * 1000 >= Double(RingConstants.answerToJoinedCapMs)
        }
        if let held = store.held, over(held) {
            VoipLog.i("startRinging: \(held.call.sessionId) was answered but is no longer in a session; dropping it")
            store.forgetAnswered(held.call.sessionId)
            store.clearHeld(sessionId: held.call.sessionId, reason: "no_session")
        }
        if let active = store.get(), active.state == .answered, over(active) {
            VoipLog.i("startRinging: \(active.call.sessionId) was answered but is no longer in a session; dropping it")
            store.forgetAnswered(active.call.sessionId)
            store.clear(sessionId: active.call.sessionId, reason: "no_session")
        }
    }

    /// CallKit refused the report: nothing rings, so the store must not say otherwise.
    private func handleReportFailure(_ call: IncomingCall, error: ReportError) {
        switch error {
        case .filteredByDoNotDisturb, .filteredByBlockList:
            VoipLog.d("CallKit filtered \(call.sessionId)")
            store.clear(sessionId: call.sessionId, reason: "filtered")
        case .callUUIDAlreadyExists:
            store.clear(sessionId: call.sessionId, reason: "duplicate")
        case .unentitled:
            VoipLog.e("CallKit refused \(call.sessionId): the app is not entitled to VoIP calls — see checkRingReadiness()")
            store.clear(sessionId: call.sessionId, reason: "failed")
        case .unknown(let message):
            VoipLog.e("CallKit refused \(call.sessionId): \(message)")
            store.clear(sessionId: call.sessionId, reason: "failed")
        }
    }

    /// The user answered. Nil when nothing was ringing — and then the CallKit
    /// call is ended rather than left connected to nothing.
    @discardableResult
    func answer(sessionId: String?) -> CallStore.ActiveCall? {
        guard let answered = store.markAnswered(sessionId: sessionId) else {
            VoipLog.w("answer: no active call for \(sessionId ?? "-")")
            if let sessionId = sessionId ?? store.get()?.call.sessionId {
                ui.endCall(sessionId: sessionId, reason: .failed)
                expiry.cancel(sessionId: sessionId)
                hooks?.onRingStopped(sessionId: sessionId, reason: .failed)
            }
            return nil
        }
        expiry.cancel(sessionId: answered.call.sessionId)
        hooks?.onRingStopped(sessionId: answered.call.sessionId, reason: .answered)
        hooks?.onAnswered(answered.call)
        return answered
    }

    /// The user declined. `busy` only while the Calls SDK is still joined to a
    /// different answered call; a stale marker is dropped so it cannot mislead
    /// the next decline either.
    /// Declines `sessionId`. It is sent as `busy` rather than `rejected` when
    /// the user is on another call, placed or answered (`callStillLive`), or
    /// when the app passes `busy`.
    func decline(sessionId: String?, busy: Bool = false) {
        guard let target = (sessionId ?? store.get()?.call.sessionId)?.nonBlank else { return }
        if store.wasTerminal(sessionId: target) {
            // A double-tapped Decline, or one racing the timeout.
            ui.endCall(sessionId: target, reason: .declined)
            return
        }
        // A group call is declined here only: the ring stops and the session
        // prepared while ringing is left, but nothing is sent, so the call
        // carries on for everyone else. Both native SDKs do this; an endCall on
        // a group session can end it for every member.
        if let ringing = store.get(), ringing.call.sessionId == target, !ringing.call.isPeerCall {
            ui.endCall(sessionId: target, reason: .declined)
            expiry.cancel(sessionId: target)
            let cleared = store.clear(sessionId: target, reason: "declined")
            hooks?.onRingStopped(sessionId: target, reason: .declined)
            if let cleared = cleared { hooks?.onCallEnded(cleared.call, reason: .declined) }
            return
        }
        let status = (busy || callStillLive(declining: target)) ? RingConstants.Status.busy : RingConstants.Status.rejected
        ui.endCall(sessionId: target, reason: .declined)
        expiry.cancel(sessionId: target)
        let cleared = store.clear(sessionId: target, reason: "declined")
        hooks?.onRingStopped(sessionId: target, reason: .declined)
        hooks?.onDeclined(sessionId: target, status: status)
        if let cleared = cleared { hooks?.onCallEnded(cleared.call, reason: .declined) }
    }

    /// Whether a call other than `declining` is live on this device. Any
    /// joined call counts, one this device placed as much as one it answered;
    /// only counting answered calls sent `rejected` for a decline during a call
    /// this device placed. The answered check runs first, so a stale answered
    /// marker is still dropped.
    private func callStillLive(declining: String) -> Bool {
        if answeredCallStillLive(declining: declining) { return true }
        return hooks?.isInAnotherCall(than: declining) ?? false
    }

    private func answeredCallStillLive(declining: String) -> Bool {
        guard let answered = store.answeredSessionOtherThan(declining) else { return false }
        let live = hooks?.isSessionJoined(sessionId: answered) ?? false
        if !live { store.forgetAnswered(answered) }
        return live
    }

    /// Nobody answered in time.
    func timeout(sessionId: String?) {
        let active = store.get()
        guard let target = sessionId ?? active?.call.sessionId else { return }
        ui.endCall(sessionId: target, reason: .timedOut)
        expiry.cancel(sessionId: target)
        guard let active = active, active.call.sessionId == target else {
            if !store.wasTerminal(sessionId: target) { store.markTerminal(sessionId: target, reason: "timeout") }
            hooks?.onRingStopped(sessionId: target, reason: .timedOut)
            return
        }
        let wasRinging = active.state == .ringing
        let cleared = store.clear(sessionId: target, reason: "timeout")
        hooks?.onRingStopped(sessionId: target, reason: .timedOut)
        if wasRinging, let cleared = cleared {
            // A one-to-one call that rang out ends as `unanswered` on the server
            // too, durably, as on both native SDKs; it used to be told to the
            // local listeners only. Nothing for a group call.
            if cleared.call.isPeerCall {
                hooks?.onDeclined(sessionId: target, status: RingConstants.Status.unanswered)
            }
            hooks?.onCallEnded(cleared.call, reason: .timedOut)
        }
    }

    /// The far side cancelled, the call ended elsewhere, or it was found dead.
    /// When the session is not active this still records it, so a late
    /// initiated cannot ring a call that is over.
    func remoteEnded(sessionId: String, reason: CallEndReason, ledgerReason: String? = nil) {
        ui.endCall(sessionId: sessionId, reason: reason)
        expiry.cancel(sessionId: sessionId)
        if let active = store.get(), active.call.sessionId == sessionId {
            let cleared = store.clear(sessionId: sessionId, reason: ledgerReason ?? reason.rawValue)
            hooks?.onRingStopped(sessionId: sessionId, reason: reason)
            if let cleared = cleared { hooks?.onCallEnded(cleared.call, reason: reason) }
        } else {
            if !store.wasTerminal(sessionId: sessionId) {
                store.markTerminal(sessionId: sessionId, reason: ledgerReason ?? reason.rawValue)
            }
            hooks?.onRingStopped(sessionId: sessionId, reason: reason)
        }
    }

    /// Removes every visible and scheduled trace of a ringing session.
    func stopRinging(sessionId: String, reason: CallEndReason) {
        ui.endCall(sessionId: sessionId, reason: reason)
        expiry.cancel(sessionId: sessionId)
        hooks?.onRingStopped(sessionId: sessionId, reason: reason)
    }

    /// An answered call's session ended: the user hung up, the far side left,
    /// the connection closed.
    func sessionEnded(sessionId: String, reason: CallEndReason) {
        ui.endCall(sessionId: sessionId, reason: reason)
        expiry.cancel(sessionId: sessionId)
        store.forgetAnswered(sessionId)
        // Ended while another call rang over it: it is not coming back.
        store.dropHeld(sessionId)
        if let active = store.get(), active.call.sessionId == sessionId,
           let cleared = store.clear(sessionId: sessionId, reason: reason.rawValue) {
            hooks?.onCallEnded(cleared.call, reason: reason)
        }
    }
}
