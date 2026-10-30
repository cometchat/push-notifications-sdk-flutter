import Foundation

/// Every VoIP push lands here: parsed, gated, then rung — and on every path
/// that does not ring, still reported to CallKit and ended at once. iOS
/// terminates an app that acknowledges a VoIP push without a report, and
/// eventually stops delivering its VoIP pushes. There is no early return that
/// skips the report; `completion` is only ever called from inside one.
final class RingingCallHandler {

    let controller: RingController
    let store: CallStore
    let clock: RingClock

    init(controller: RingController, store: CallStore, clock: RingClock) {
        self.controller = controller
        self.store = store
        self.clock = clock
    }

    func handle(payload: [AnyHashable: Any], completion: @escaping () -> Void) {
        let nowMs = clock.nowMs
        switch CallPushPayload.parse(pushDictionary: payload) {
        case .ignored(let reason):
            VoipLog.d("ignored VoIP payload: \(reason)")
            controller.ui.reportAndEndImmediately(callerName: "Unknown caller", hasVideo: false, reason: .failed, completion: completion)

        case .call(let parsed):
            let call = parsed.toIncomingCall(
                receivedAtMs: nowMs,
                defaultRingTimeoutMs: VoipConfig.restore()?.defaultRingTimeoutMs ?? RingConstants.defaultRingTimeoutMs
            )
            if parsed.action.isTerminal {
                handleTerminal(parsed, call: call, completion: completion)
            } else if parsed.action == .initiated {
                handleInitiated(call, nowMs: nowMs, completion: completion)
            } else {
                // An action this build does not know neither rings nor silences a call.
                VoipLog.w("unknown call action '\(parsed.rawAction)' for \(call.sessionId)")
                controller.ui.reportAndEndImmediately(callerName: call.callerName, hasVideo: call.isVideo, reason: .filtered, completion: completion)
            }
        }
    }

    private func handleInitiated(_ call: IncomingCall, nowMs: Int64, completion: @escaping () -> Void) {
        switch RingGate.decide(call, store: store, nowMs: nowMs) {
        case .ring:
            VoipLog.i("ringing \(call.sessionId)")
            controller.startRinging(call, completion: completion)

        case .drop(let reason, let endAs, let markTerminal):
            VoipLog.i("not ringing \(call.sessionId): \(reason)")
            if markTerminal { store.markTerminal(sessionId: call.sessionId, reason: reason) }
            controller.ui.reportAndEndImmediately(callerName: call.callerName, hasVideo: call.isVideo, reason: endAs, completion: completion)
            if endAs == .timedOut { controller.hooks?.onCallEnded(call, reason: .timedOut) }
        }
    }

    private func handleTerminal(_ parsed: CallPushPayload, call: IncomingCall, completion: @escaping () -> Void) {
        let reason = parsed.action.endReason
        let ledger = parsed.rawAction.lowercased()

        // The backend fans terminal events out to the caller's own devices too:
        // someone who rang and hung up must not be told they missed a call.
        //
        // But the push is how the caller learns how its call ended: a callee
        // that declines before its ringer is in the room can only leave
        // locally, so the caller's prepared session never closes, and without
        // this the caller rings to its timeout. Handed to the Calls SDK with
        // the push's own action, so the caller's IncomingCallListener hears it
        // (the UI Kit's outgoing call screen listens). Not `onCallEnded`: that
        // means a call that rang on this device.
        if let myUid = store.uid, call.callerUid == myUid {
            store.markTerminal(sessionId: call.sessionId, reason: ledger)
            reportOverOwnCall(call, reason: reason, ledger: ledger, completion: completion)
            if RingConstants.callerEndActions.contains(ledger) {
                controller.hooks?.onOwnCallEnded(call, action: ledger)
            }
            return
        }

        // The callee declined (or was busy for) a call this user placed: the
        // push carries the callee as `sender` and this user as `receiver`, so
        // the check above never matches it. Same handling: over, reported and
        // ended at once for PushKit, and the Calls SDK tells the caller's UI.
        if let myUid = store.uid, call.isPeerCall, call.receiverUid == myUid,
           call.callerUid != myUid, RingConstants.declinedByCallee.contains(ledger) {
            VoipLog.i("\(call.sessionId): the callee says \(ledger) — telling this caller")
            store.markTerminal(sessionId: call.sessionId, reason: ledger)
            reportOverOwnCall(call, reason: reason, ledger: ledger, completion: completion)
            controller.hooks?.onOwnCallEnded(call, action: ledger)
            return
        }

        // Answered here: the call is the app's now, and the joined session —
        // not a push — says when it is over.
        if store.isAnswered(sessionId: call.sessionId) {
            controller.ui.reportAndEndImmediately(callerName: call.callerName, hasVideo: call.isVideo, reason: .filtered, completion: completion)
            return
        }

        // `ongoing`: someone answered. Another participant of a group call —
        // keep ringing.
        if parsed.action == .ongoing, !concernsThisUser(call) {
            controller.ui.reportAndEndImmediately(callerName: call.callerName, hasVideo: call.isVideo, reason: .filtered, completion: completion)
            return
        }

        let wasRinging = store.isRinging(sessionId: call.sessionId)
        let wasKnown = store.get()?.call.sessionId == call.sessionId
        // The Calls SDK usually hears a cancel before the push does, and has
        // ended the ring and reported its end already.
        let alreadyOver = !wasKnown && store.wasTerminal(sessionId: call.sessionId)

        // Still ringing: the report PushKit asks for is made against the call
        // CallKit is showing, and only then is that call ended.
        let sessionId = call.sessionId
        if wasRinging, controller.ui.reportAgain(sessionId: sessionId, then: { [controller] in
            controller.remoteEnded(sessionId: sessionId, reason: reason, ledgerReason: ledger)
            completion()
        }) {
            return
        }

        controller.remoteEnded(sessionId: call.sessionId, reason: reason, ledgerReason: ledger)

        // Nothing of the call is showing; this is the throwaway report the VoIP
        // contract requires. A call the ring never saw — its initiated was lost
        // — still leaves its missed call; one already ended here does not
        // leave a second.
        let missedHere = !wasRinging && !alreadyOver && reason.leavesMissedCall
        controller.ui.reportAndEndImmediately(callerName: call.callerName, hasVideo: call.isVideo, reason: missedHere ? reason : .filtered, completion: completion)
        if !wasKnown && missedHere { controller.hooks?.onCallEnded(call, reason: reason) }
    }

    /// Satisfies PushKit for a terminal push about a call this device PLACED,
    /// and ends it.
    ///
    /// An outgoing call is on CallKit from the moment it is placed, so a
    /// placeholder reported under a fresh uuid lands as a SECOND call on top of
    /// a live one and iOS draws its call-waiting screen — an incoming call,
    /// with Decline and End & Accept, for a call that is already over. Found on
    /// a device: the callee declining showed the caller a new incoming call.
    ///
    /// Re-reporting the call CallKit already shows is a report all the same —
    /// iOS refuses it as `callUUIDAlreadyExists` and shows nothing new — and it
    /// is the one the contract asks for. Then that call is ended, which is also
    /// what takes the caller's own outgoing call off the screen: nothing else
    /// reports the end of a call the callee declined.
    ///
    /// Falls back to a placeholder when CallKit shows nothing for the session,
    /// which is every call this device did not place.
    private func reportOverOwnCall(_ call: IncomingCall, reason: CallEndReason, ledger: String,
                                   completion: @escaping () -> Void) {
        let sessionId = call.sessionId
        guard controller.ui.isShowing(sessionId: sessionId) else {
            controller.ui.reportAndEndImmediately(callerName: call.callerName, hasVideo: call.isVideo, reason: .filtered, completion: completion)
            return
        }
        VoipLog.i("\(sessionId) is on CallKit as this device's own call — reporting against it rather than a second call")
        let reported = controller.ui.reportAgain(sessionId: sessionId, then: { [controller] in
            controller.remoteEnded(sessionId: sessionId, reason: reason, ledgerReason: ledger)
            completion()
        })
        if !reported {
            controller.ui.reportAndEndImmediately(callerName: call.callerName, hasVideo: call.isVideo, reason: .filtered, completion: completion)
        }
    }

    /// Without a known uid, yes: acting is safer than ignoring, because a missed
    /// dismissal leaves a phone ringing for a call that is over.
    private func concernsThisUser(_ call: IncomingCall) -> Bool {
        guard let myUid = store.uid else { return true }
        return call.receiverUid == nil || call.receiverUid == myUid
    }
}
