import AVFAudio
import Foundation
import UIKit

/// Everything the ringer is made of, wired together once per process.
///
/// A singleton because PushKit and CallKit are: one registry and one provider
/// per app, however many Flutter engines register the plugin. It starts when
/// the plugin first registers, inside `didFinishLaunching`, so a push that
/// launched a killed app is reported to CallKit before any Dart runs.
///
/// **The provider is ours, the Calls SDK is Dart's.** This package names no
/// native SDK, so everything the ring needs from the Calls SDK — connect while
/// ringing, the decline, handing the call to `IncomingCallListener` — goes
/// through `DartCallsSdk`. Two consequences worth knowing:
///
///  - The session and media events that used to arrive from the native SDK's
///    listeners now come from Dart, pushed in through `sessionStateChanged`
///    and friends. An app that does not report them leaves CallKit's mute and
///    hold out of step with the call.
///  - `CometChatAudioSession.activate` is out of reach, so `didActivate`
///    configures the shared `AVAudioSession` here instead and then hands the
///    session over through Dart. `callKitAudio` is a request: Dart checks for
///    the Calls SDK's `notifyCallKitAudioActivated` before enabling it, and
///    leaves it off without it, because the flag with no handoff makes WebRTC
///    wait for a signal nothing can send and the call is silent.
final class VoipCore: NSObject {

    static let shared = VoipCore()

    let sdk: CallsSdkPort = DartCallsSdk.shared
    let store = CallStore(defaults: VoipConfig.defaults)
    let events = EventHub()
    let ui: CallKitManager
    let controller: RingController
    let ringing: RingingCallHandler
    let verifier: WakeVerifier
    let declines: DeclineQueue
    private(set) var sync: CallKitSyncEngine!

    private let scheduler: RingScheduler = MainQueueRingScheduler()
    private let clock: RingClock = SystemRingClock()
    private let pushKit = PushKitRegistry()
    private var started = false

    /// Sessions `answered` was sent for — at most once each.
    private var presented: Set<String> = []
    /// Answered calls that have not joined yet, each on a deadline.
    private var answerToJoinedCap: [String: RingScheduledWork] = [:]

    /// The outgoing call this package put on CallKit itself, until its callee
    /// has a name. See `reportUnreportedOutgoingCall`.
    private var unnamedOutgoingSessionId: String?
    private let outgoingLock = NSLock()

    private(set) var voipToken: String?
    private var voipTokenWaiters: [(String?) -> Void] = []

    /// The audio session CallKit handed over in `didActivate`, or nil while it
    /// owns it. Kept so the handoff can be re-asserted once the session joins.
    private var activatedAudioSession: AVAudioSession?

    /// Lock-screen one-way-audio instrumentation. Which of CallKit's audio
    /// activation and the Calls SDK's join lands first decides whether the
    /// outbound track is ever captured, and the order is timing-dependent, so
    /// one passing device run proves little without these. Read by
    /// `getDiagnostics`.
    private(set) var answeredAtMs: Int64?
    private(set) var audioActivatedAtMs: Int64?
    private(set) var joinedAtMs: Int64?
    private(set) var audioReassertedAfterJoin = false
    private static func nowMs() -> Int64 { Int64(Date().timeIntervalSince1970 * 1000) }

    /// What `callKitAudio` asked for, and whether the handoff that makes it
    /// safe is actually available. Reported by `getDiagnostics`, because the
    /// failure — a connected, silent call — has no other symptom.
    private(set) var callKitAudioRequested = false
    private(set) var callKitAudioHandoffAvailable: Bool?

    private static let listenerId = "cometchat_voip"

    private override init() {
        let config = VoipConfig.restore()
        ui = CallKitManager(options: config?.callKit ?? VoipConfig.CallKitOptions())
        let expiry = RingExpiry(scheduler: scheduler, clock: clock)
        controller = RingController(store: store, ui: ui, expiry: expiry)
        ringing = RingingCallHandler(controller: controller, store: store, clock: clock)
        verifier = WakeVerifier(sdk: sdk, scheduler: scheduler, clock: clock, config: VoipConfig.restore)
        declines = DeclineQueue(sdk: sdk, store: store, scheduler: scheduler, config: VoipConfig.restore)
        super.init()
        sync = CallKitSyncEngine(
            native: ui,
            session: DartSessionControl(snapshot: DartCallsSdk.shared.snapshot)
        ) { [weak self] sessionId, reason in
            self?.controller.sessionEnded(sessionId: sessionId, reason: reason)
        }
        ui.actions = self
        controller.hooks = self
    }

    /// Idempotent. Called by every engine that registers the plugin.
    func start() {
        guard !started else { return }
        started = true

        pushKit.delegate = self
        pushKit.start()
        if let token = pushKit.currentToken { voipTokenDidUpdate(token) }

        // The login, incoming-call and session events used to come from the
        // native SDK's listeners. Dart watches them now and pushes them in.
        DartCallsSdk.shared.loggedInUid { [weak self] uid in
            if let uid = uid { self?.store.uid = uid }
        }

        declines.replayPendingIfAny()
    }

    func configure(_ config: VoipConfig) {
        config.save()
        ui.apply(options: config.callKit)
    }

    // MARK: - Acting for the app

    func answer(sessionId: String) {
        if !ui.requestAnswer(sessionId: sessionId) {
            _ = nativeAnswer(sessionId: sessionId)
        }
    }

    func decline(sessionId: String, busy: Bool = false) {
        if !ui.requestEnd(sessionId: sessionId) {
            controller.decline(sessionId: sessionId, busy: busy)
        }
    }

    func reportOutgoingCall(sessionId: String, calleeName: String, hasVideo: Bool) {
        setCallKitAudio(true)
        outgoingLock.lock()
        let reportedAlready = sync.state?.sessionId == sessionId && ui.isShowing(sessionId: sessionId)
        if reportedAlready, unnamedOutgoingSessionId == sessionId { unnamedOutgoingSessionId = nil }
        outgoingLock.unlock()
        if reportedAlready {
            // Reported when the Calls SDK prepared it: take the app's name and
            // type for it rather than putting a second call on the screen.
            VoipLog.i("reportOutgoingCall \(sessionId): already on CallKit — updating name and type")
            ui.updateCallee(sessionId: sessionId, uid: nil, name: calleeName)
            ui.updateHasVideo(sessionId: sessionId, hasVideo: hasVideo)
            return
        }
        VoipLog.i("reportOutgoingCall \(sessionId) (\(hasVideo ? "video" : "voice")) — reported by the app")
        ui.reportOutgoingCall(sessionId: sessionId, calleeName: calleeName, hasVideo: hasVideo)
        sync.track(sessionId: sessionId, videoPaused: !hasVideo)
    }

    /// Puts an outgoing call nobody reported on CallKit (see
    /// `UnreportedSession`). Runs when the Calls SDK connects a prepared
    /// session — `initiateCall` prepares the caller's — and when it joins one,
    /// which covers a plain `joinSession` that was never prepared.
    ///
    /// The Calls SDK says neither who is called nor whether it is video: the
    /// call is reported under the app's name as a voice call, and renamed when
    /// the other party connects (`remoteParticipantSeen`).
    func reportUnreportedOutgoingCall() {
        outgoingLock.lock()
        guard let sessionId = UnreportedSession.outgoingSessionToReport(
            ownedSessionId: sdk.ownedSessionId,
            trackedSessionId: sync.state?.sessionId,
            isOnCallKit: { [ui] in ui.isShowing(sessionId: $0) },
            store: store
        ) else {
            outgoingLock.unlock()
            return
        }
        unnamedOutgoingSessionId = sessionId
        setCallKitAudio(true)
        ui.reportOutgoingCall(sessionId: sessionId, calleeName: placeholderCalleeName, hasVideo: false)
        sync.track(sessionId: sessionId, videoPaused: true)
        outgoingLock.unlock()
        VoipLog.d("\(sessionId) is an outgoing call nobody reported — reported it to CallKit")
    }

    /// A remote participant of the call connected or joined: names the call
    /// reported without one.
    func remoteParticipantSeen(uid: String?, name: String?) {
        guard let uid = uid?.nonBlank, uid != store.uid, let name = name?.nonBlank else { return }
        outgoingLock.lock()
        guard let sessionId = unnamedOutgoingSessionId, sync.state?.sessionId == sessionId else {
            outgoingLock.unlock()
            return
        }
        unnamedOutgoingSessionId = nil
        outgoingLock.unlock()
        VoipLog.i("outgoing \(sessionId): naming the callee \(uid)")
        ui.updateCallee(sessionId: sessionId, uid: uid, name: name)
    }

    /// What an auto-reported outgoing call is called until the other party
    /// connects. The Calls SDK names no callee, so this is the app's own name.
    private var placeholderCalleeName: String {
        (Bundle.main.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String)?.nonBlank
            ?? (Bundle.main.object(forInfoDictionaryKey: "CFBundleName") as? String)?.nonBlank
            ?? "Call"
    }

    func reportCallEnded(sessionId: String, reason: CallEndReason = .remoteEnded) {
        if sync.state?.sessionId == sessionId {
            sync.sessionEnded(sessionId: sessionId, reason: reason)
        } else {
            controller.sessionEnded(sessionId: sessionId, reason: reason)
        }
    }

    /// The app answered or declined a ringing call in its own UI and told
    /// CometChat itself: stop the ring, send nothing. An answered call runs
    /// outside CallKit from here, so the Calls SDK keeps managing its audio.
    func dismissRinging(sessionId: String, answered: Bool) {
        guard store.isRinging(sessionId: sessionId) else { return }
        if answered {
            store.markAnswered(sessionId: sessionId)
        } else {
            store.clear(sessionId: sessionId, reason: "declined_in_app")
        }
        // `.answered` keeps the session prepared while ringing for the app's
        // join; `.declined` releases it. Neither leaves a missed call.
        controller.stopRinging(sessionId: sessionId, reason: answered ? .answered : .declined)
    }

    /// The PushKit token, waiting briefly for one when iOS has not issued it yet.
    func waitForVoipToken(_ completion: @escaping (String?) -> Void) {
        if let token = voipToken {
            completion(token)
            return
        }
        var settled = false
        let settle: (String?) -> Void = { token in
            guard !settled else { return }
            settled = true
            completion(token)
        }
        voipTokenWaiters.append(settle)
        DispatchQueue.main.asyncAfter(deadline: .now() + .milliseconds(RingConstants.voipTokenWaitMs)) { [weak self] in
            settle(self?.voipToken)
        }
    }

    /// Lets CallKit own the audio session — only while a CallKit call is live.
    /// With it on, WebRTC starts audio only when CallKit activates the
    /// session, so leaving it on would silence a call the app makes without
    /// reporting it.
    private func setCallKitAudio(_ enabled: Bool) {
        // The flag itself lives in the Calls SDK and Dart sets it; this only
        // records what was asked for, so `getDiagnostics` can say whether the
        // handoff that makes it safe is actually available.
        callKitAudioRequested = enabled
        VoipLog.d("callKitAudio requested: \(enabled)")
    }

    /// What Dart found out about the handoff before any call rang.
    ///
    /// `audioSessionDidActivate` learns the same thing, but only once a call
    /// has already connected — too late to stop the silence it causes. Dart
    /// asks the Calls SDK up front and reports it here, so `getDiagnostics`
    /// can answer before the first call.
    func callKitAudioHandoffChanged(_ available: Bool) {
        callKitAudioHandoffAvailable = available
        VoipLog.d("callKitAudio handoff available: \(available)")
    }

    fileprivate var trackedSessionId: String? { sync.state?.sessionId }
}

// MARK: - PushKit

extension VoipCore: PushKitRegistryDelegate {

    func voipTokenDidUpdate(_ token: Data) {
        // Never logged: it is a live credential for the device.
        let hex = token.map { String(format: "%02x", $0) }.joined()
        voipToken = hex
        let waiters = voipTokenWaiters
        voipTokenWaiters = []
        waiters.forEach { $0(hex) }
        events.voipToken(hex)
    }

    func voipTokenDidInvalidate() {
        voipToken = nil
    }

    func didReceiveVoIPPush(_ payload: [AnyHashable: Any], completion: @escaping () -> Void) {
        ringing.handle(payload: payload, completion: completion)
    }
}

// MARK: - RingHooks

extension VoipCore: RingHooks {

    func onRingStarted(_ call: IncomingCall) {
        sdk.injectIncomingCall(call)
        verifier.start(call)
    }

    func onRingStopped(sessionId: String, reason: CallEndReason) {
        verifier.cancel(sessionId: sessionId)
        // Release the session prepared while ringing — never one the join took over.
        if reason != .answered, sdk.ownedSessionId == sessionId, !sdk.isSessionJoined {
            sdk.leaveSession()
        }
    }

    func onAnswered(_ call: IncomingCall) {
        answeredAtMs = VoipCore.nowMs()
        audioActivatedAtMs = nil
        joinedAtMs = nil
        audioReassertedAfterJoin = false
        sync.track(sessionId: call.sessionId, videoPaused: !call.isVideo)
        if !presented.contains(call.sessionId) {
            presented.insert(call.sessionId)
            events.answered(call)
        }
        if VoipConfig.restore()?.requestCallPermissions ?? true {
            CallPermissions.requestIfNeeded(video: call.isVideo)
        }
        // An answer that never joins ends as failed, rather than leaving a
        // silent live call in CallKit.
        answerToJoinedCap[call.sessionId]?.cancel()
        answerToJoinedCap[call.sessionId] = scheduler.schedule(after: TimeInterval(RingConstants.answerToJoinedCapMs) / 1000) { [weak self] in
            guard let self = self, self.answerToJoinedCap.removeValue(forKey: call.sessionId) != nil else { return }
            // Ended while joining, and the join never completed: CallKit and
            // the app already ended the call; only what the Calls SDK still
            // holds for it is left to release.
            if self.sync.joinWindowExpired(sessionId: call.sessionId) {
                VoipLog.w("\(call.sessionId) ended while joining and never joined within \(RingConstants.answerToJoinedCapMs) ms — releasing its session")
                if self.sdk.isSessionActive, self.sdk.ownedSessionId == nil || self.sdk.ownedSessionId == call.sessionId {
                    self.sdk.leaveSession()
                }
                return
            }
            guard !self.hasJoined(call.sessionId) else { return }
            VoipLog.e("\(call.sessionId) was answered but never joined — ending it")
            self.sync.stopTracking(sessionId: call.sessionId)
            // A join still in flight would otherwise connect after CallKit has
            // ended the call, leaving the far side in a call this device shows
            // as over.
            if self.sdk.isSessionActive { self.sdk.leaveSession() }
            self.controller.sessionEnded(sessionId: call.sessionId, reason: .failed)
        }
    }

    func onDeclined(sessionId: String, status: String) {
        declines.enqueue(sessionId: sessionId, status: status)
    }

    func onCallEnded(_ call: IncomingCall, reason: CallEndReason) {
        // A call that ends while its join is still in flight has its join left
        // once it completes; the answer-to-joined cap stays armed to clean up
        // should it never complete.
        sync.callEnded(sessionId: call.sessionId)
        cancelAnswerToJoinedCap(unlessLeavePending: call.sessionId)
        presented.remove(call.sessionId)
        outgoingLock.lock()
        if unnamedOutgoingSessionId == call.sessionId { unnamedOutgoingSessionId = nil }
        outgoingLock.unlock()
        if trackedSessionId == nil { setCallKitAudio(false) }
        sdk.injectIncomingCallEnded(call, reason: reason)
        events.ended(call, reason: reason)
    }

    func isSessionJoined(sessionId: String) -> Bool {
        sdk.isSessionJoined && sdk.ownedSessionId == sessionId
    }

    /// Cancels `sessionId`'s answer-to-joined cap — unless the call ended
    /// while joining, when the cap is what clears that state if the join never
    /// completes.
    private func cancelAnswerToJoinedCap(unlessLeavePending sessionId: String) {
        guard sync.pendingLeaveSessionId != sessionId else { return }
        answerToJoinedCap.removeValue(forKey: sessionId)?.cancel()
    }

    /// Joined to a call other than `sessionId`. The session id can be nil for
    /// a joined call (a `joinSession` without a prepare, see `hasJoined`), and
    /// a nil id is never the declining call's.
    func isInAnotherCall(than sessionId: String) -> Bool {
        if let state = sync.state, state.joined, state.sessionId != sessionId { return true }
        return sdk.isSessionJoined && sdk.ownedSessionId != sessionId
    }

    func onOwnCallEnded(_ call: IncomingCall, action: String) {
        sdk.injectOwnCallEnded(call, action: action)
    }

    /// Whether the answered call `sessionId` has joined, by any of the signals
    /// that say so. The Calls SDK alone is not enough (5.1.3-team): a
    /// `joinSession` without a prepare leaves its session id nil, and
    /// `isSessionJoined()` goes false once the call view is released — either
    /// made a live call look un-joined, and the 20 s cap then ended it. The
    /// same signals decide whether an answered call the store still holds is
    /// in a session at all, before the next call rings over it.
    func hasJoined(_ sessionId: String) -> Bool {
        if let state = sync.state, state.sessionId == sessionId, state.joined { return true }
        guard sdk.isSessionJoined else { return false }
        return sdk.ownedSessionId == nil || sdk.ownedSessionId == sessionId
    }
}

// MARK: - CallKitActions

extension VoipCore: CallKitActions {

    func nativeAnswer(sessionId: String) -> Bool {
        // Before CallKit activates the audio session, so WebRTC waits for it.
        setCallKitAudio(true)
        guard controller.answer(sessionId: sessionId) != nil else {
            if trackedSessionId == nil { setCallKitAudio(false) }
            return false
        }
        return true
    }

    func nativeEnd(sessionId: String) {
        if store.isRinging(sessionId: sessionId) {
            controller.decline(sessionId: sessionId)
            return
        }
        // Answered or outgoing: leave the session and tell the app. A call
        // still joining is left when its join completes, and keeps its
        // answer-to-joined cap until then.
        let incoming = store.isActive(sessionId: sessionId)
        sync.nativeEnd(sessionId: sessionId)
        cancelAnswerToJoinedCap(unlessLeavePending: sessionId)
        controller.sessionEnded(sessionId: sessionId, reason: .remoteEnded)
        // An answered incoming call is told through `onCallEnded`; an outgoing
        // one is in no store, so this is the only way the app hears that the
        // native screen ended it — and a call the callee has not answered has
        // to be withdrawn, or they go on ringing.
        if !incoming { events.outgoingEnded(sessionId: sessionId) }
    }

    func nativeSetMuted(sessionId: String, muted: Bool) {
        // While another call rings over the live one, CallKit's mute actions on
        // the live call are not the user's: native iOS found a stale CallKit
        // mute applied to the live call for real when the next call rang.
        if let ringing = store.get(), ringing.state == .ringing, ringing.call.sessionId != sessionId {
            VoipLog.d("ignoring a CallKit mute on \(sessionId) while \(ringing.call.sessionId) rings")
            return
        }
        sync.nativeSetMuted(sessionId: sessionId, muted: muted)
    }

    func nativeSetHeld(sessionId: String, held: Bool) {
        sync.nativeSetHeld(sessionId: sessionId, held: held)
    }

    /// The only way WebRTC learns the session is live. Never setActive here.
    func audioSessionDidActivate(_ session: AVAudioSession) {
        activatedAudioSession = session
        if audioActivatedAtMs == nil { audioActivatedAtMs = VoipCore.nowMs() }
        // Category and mode right, never `setActive` — CallKit owns that.
        do {
            try session.setCategory(
                .playAndRecord,
                mode: .voiceChat,
                options: [.allowBluetooth, .allowBluetoothA2DP]
            )
        } catch {
            VoipLog.w("could not configure the audio session CallKit activated: \(error)")
        }

        // The handoff a CXProvider owner owes WebRTC. `CometChatAudioSession`
        // is the native SDK's, which this package does not link, so it goes
        // through Dart. A Calls SDK without the binding answers false, and the
        // CallKit audio mode must then stay off — WebRTC would wait for a
        // signal that can never come and the call would be silent.
        DartCallsSdk.shared.callKitAudioActivated { [weak self] took in
            self?.callKitAudioHandoffAvailable = took
            if !took {
                VoipLog.w(
                    "the Calls SDK could not take the audio session; WebRTC is "
                        + "managing its own. callKitAudio stays off."
                )
            }
        }
    }

    func audioSessionDidDeactivate(_ session: AVAudioSession) {
        activatedAudioSession = nil
        DartCallsSdk.shared.callKitAudioDeactivated()
    }

    /// Re-asserts the audio handoff once the session has actually joined.
    ///
    /// CallKit activates the audio session the moment the call is answered,
    /// and on a LOCK-SCREEN answer that routinely lands before the join has
    /// published a local audio track. In manual-audio mode the audio unit is
    /// enabled exactly once, at that activation, so a track that appears
    /// afterwards is never captured: the callee hears the caller and the
    /// caller hears silence. Re-asserting here closes that window.
    ///
    /// A no-op until CallKit has activated the session, which is the ordinary
    /// ordering — then the activation already did the work and this never
    /// runs. Safe twice: WebRTC refcounts the activation.
    func reassertAudioAfterJoin() {
        if joinedAtMs == nil { joinedAtMs = VoipCore.nowMs() }
        guard activatedAudioSession != nil else {
            // The join won the race: `didActivate` has not run yet and will
            // hand the session over itself.
            VoipLog.d("session joined before CallKit activated the audio session — nothing to re-assert")
            return
        }
        audioReassertedAfterJoin = true
        let gap = (joinedAtMs ?? 0) - (audioActivatedAtMs ?? 0)
        VoipLog.d("session joined \(gap) ms AFTER CallKit activated the audio session — re-asserting the handoff")
        DartCallsSdk.shared.callKitAudioActivated { [weak self] took in
            self?.callKitAudioHandoffAvailable = took
        }
    }

    func providerDidReset() {
        sync.providerDidReset()
        // The ringing call and, under call waiting, the answered call it rings
        // on top of.
        for active in [store.get(), store.held].compactMap({ $0 }) {
            controller.remoteEnded(sessionId: active.call.sessionId, reason: .failed, ledgerReason: "provider_reset")
        }
        outgoingLock.lock(); unnamedOutgoingSessionId = nil; outgoingLock.unlock()
        setCallKitAudio(false)
    }
}

// MARK: - What Dart pushes in

/// The Calls SDK's own events, forwarded from Dart.
///
/// These used to arrive from the native SDK's listeners. The package names no
/// native SDK now, so Dart watches `CometChatCalls` and calls these — which is
/// why `reportCallConnected` / `reportCallEnded` are not optional: without them
/// CallKit and the call drift apart.
extension VoipCore {

    /// The login changed. The ring gates read the uid from disk, so it has to
    /// be written down before the next push.
    func loggedInUidChanged(_ uid: String?) {
        if uid == nil, let active = store.get() {
            // Logged out with a call still ringing: it is for a user who is gone.
            controller.remoteEnded(
                sessionId: active.call.sessionId,
                reason: .failed,
                ledgerReason: "logout"
            )
        }
        store.uid = uid
        DartCallsSdk.shared.snapshot.isLoggedIn = uid != nil
    }

    /// The session Dart sees. Drives the sync in both directions: a join
    /// starts CallKit's timer, and the session going away ends the CallKit call.
    func sessionStateChanged(active: Bool, joined: Bool, sessionId: String?) {
        DartCallsSdk.shared.snapshot.update(
            active: active,
            joined: joined,
            sessionId: sessionId
        )
        // The join of a call that already ended — the user hung up, or it
        // ended remotely, while it was joining. Left here, before anything can
        // report it to CallKit as a new call, and before the fallback below
        // names it: an ended call is no longer tracked, so a join reported
        // without an id would otherwise find nothing and be ignored.
        if joined, let left = sync.leaveIfEndedWhileJoining(ownedSessionId: sessionId) {
            answerToJoinedCap.removeValue(forKey: left)?.cancel()
            return
        }
        // A session the Calls SDK owns that CallKit has not heard of is an
        // outgoing call nobody reported — the prepare of an `initiateCall`, or
        // a plain `joinSession`. `UnreportedSession` leaves incoming calls and
        // calls already on CallKit alone.
        if active { reportUnreportedOutgoingCall() }
        guard let sessionId = sessionId ?? trackedSessionId else { return }
        if joined {
            // Joined: the answer-to-joined cap has done its job. Cancelled here,
            // at the join, rather than re-checked 20 s later against Calls SDK
            // state that can read un-joined for a live call.
            answerToJoinedCap.removeValue(forKey: sessionId)?.cancel()
            sync.sessionJoined(sessionId: sessionId)
            // The join may have finished AFTER CallKit activated the audio
            // session — the usual case on a lock-screen answer, and the one
            // that leaves the caller in silence.
            reassertAudioAfterJoin()
        } else if !active {
            guard let s = sync.state, s.sessionId == sessionId else { return }
            // An ANSWERED call that has not joined yet: a leave reported
            // without an id, or arriving late from the call before, falls back
            // to the tracked call — which, on "End & accept", is the one just
            // answered and still joining. A join that never comes is the
            // answer-to-joined cap's to end.
            //
            // An OUTGOING call that has not joined is a different story: its
            // prepared session closing is the call being over — the callee
            // declined, or nobody answered — and the CallKit call reported for
            // it has to go, or it outlives the call. The native iOS SDK draws
            // the line in the same place.
            if !s.joined, store.isAnswered(sessionId: sessionId) { return }
            sync.sessionEnded(sessionId: sessionId, reason: .remoteEnded)
        }
    }

    /// The app muted or unmuted in its own UI: show it on the CallKit call.
    func sessionAudioMutedChanged(_ muted: Bool) {
        guard let sessionId = trackedSessionId else { return }
        sync.sessionAudioMuted(sessionId: sessionId, muted: muted)
    }

    /// The app paused or resumed video in its own UI.
    func sessionVideoPausedChanged(_ paused: Bool) {
        guard let sessionId = trackedSessionId else { return }
        sync.sessionVideoPaused(sessionId: sessionId, paused: paused)
    }

    /// The Calls SDK reported a ringing call ending — a caller's cancel often
    /// reaches this device this way before the push does, if the push comes at
    /// all. Acts only while the call still rings: once answered it is the app's.
    func incomingCallEndedBySdk(sessionId: String, reason: String) {
        DispatchQueue.main.async { [self] in
            guard store.isRinging(sessionId: sessionId) else { return }
            controller.remoteEnded(
                sessionId: sessionId,
                reason: CallEndReason(rawValue: reason) ?? .remoteEnded,
                ledgerReason: "sdk_\(reason)"
            )
        }
    }
}
