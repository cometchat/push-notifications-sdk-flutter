import AVFAudio
import CallKit
import Foundation
import UIKit

/// What the manager needs from the rest of the package when the user acts on
/// the native call screen.
protocol CallKitActions: AnyObject {
    func nativeAnswer(sessionId: String) -> Bool
    func nativeEnd(sessionId: String)
    func nativeSetMuted(sessionId: String, muted: Bool)
    func nativeSetHeld(sessionId: String, held: Bool)
    func audioSessionDidActivate(_ session: AVAudioSession)
    func audioSessionDidDeactivate(_ session: AVAudioSession)
    func providerDidReset()
}

/// The only place that touches CallKit, and the one `CXProvider` for both
/// directions: `reportCall(with:endedAt:)` only matches a UUID the same
/// provider reported, so the caller side shares it.
///
/// The audio session is CallKit's. This configures it on Answer and never
/// calls `setActive`; CallKit activates it and says so in `didActivate`, which
/// is forwarded to the Calls SDK.
final class CallKitManager: NSObject, IncomingCallUi, NativeCallSurface {

    private let provider: CXProvider
    private let callController = CXCallController()
    private let lock = NSLock()

    /// A CometChat session and the CallKit call reported for it, both ways.
    private var sessionIdsByUUID: [UUID: String] = [:]
    private var uuidsBySessionId: [String: UUID] = [:]
    /// Sessions reported with `reportOutgoingCall`.
    private var outgoingSessionIds: Set<String> = []
    /// Outgoing calls whose connecting state has been reported, by whichever
    /// of the start confirmation and the connect got there first.
    private var startedOutgoingSessionIds: Set<String> = []

    weak var actions: CallKitActions?

    init(options: VoipConfig.CallKitOptions) {
        provider = CXProvider(configuration: CallKitManager.configuration(for: options))
        super.init()
        provider.setDelegate(self, queue: .main)
    }

    func apply(options: VoipConfig.CallKitOptions) {
        provider.configuration = CallKitManager.configuration(for: options)
    }

    private static func configuration(for options: VoipConfig.CallKitOptions) -> CXProviderConfiguration {
        let config = CXProviderConfiguration()
        config.supportsVideo = options.supportsVideo
        // The Calls SDK holds one session at a time, so a second call must be
        // End & Accept, never Hold & Accept.
        config.maximumCallGroups = 1
        config.maximumCallsPerCallGroup = 1
        // A CometChat call is addressed by uid: not a number, not an email.
        config.supportedHandleTypes = [.generic]
        config.includesCallsInRecents = options.includesCallsInRecents
        if let ringtone = options.ringtoneSound { config.ringtoneSound = ringtone }
        if let iconName = options.iconTemplateImageName, let image = UIImage(named: iconName) {
            config.iconTemplateImageData = image.pngData()
        }
        return config
    }

    // MARK: - IncomingCallUi

    func reportIncomingCall(_ call: IncomingCall, completion: @escaping (ReportError?) -> Void) {
        let uuid = UUID()
        associate(uuid: uuid, sessionId: call.sessionId)

        let update = CXCallUpdate()
        // The handle is what the user calls back; the name is what they read.
        update.remoteHandle = CXHandle(type: .generic, value: call.callerUid ?? call.callerName)
        update.localizedCallerName = call.callerName
        update.hasVideo = call.isVideo
        update.supportsGrouping = false
        update.supportsUngrouping = false
        // Hold is how CallKit handles a cellular interruption; the sync makes it mute and pause.
        update.supportsHolding = true
        update.supportsDTMF = false

        provider.reportNewIncomingCall(with: uuid, update: update) { [weak self] error in
            if let error = error {
                VoipLog.w("reportNewIncomingCall failed for \(call.sessionId): \(error.localizedDescription)")
                self?.forget(uuid: uuid)
                completion(CallKitManager.reportError(from: error))
            } else {
                completion(nil)
            }
        }
    }

    func reportAndEndImmediately(callerName: String, hasVideo: Bool, reason: CallEndReason, completion: @escaping () -> Void) {
        let uuid = UUID()
        let update = CXCallUpdate()
        update.remoteHandle = CXHandle(type: .generic, value: callerName)
        update.localizedCallerName = callerName
        update.hasVideo = hasVideo
        update.supportsGrouping = false
        update.supportsUngrouping = false
        update.supportsHolding = false
        update.supportsDTMF = false
        provider.reportNewIncomingCall(with: uuid, update: update) { [weak self] error in
            // Even a refused report satisfies the contract: it was made.
            if error == nil {
                self?.provider.reportCall(with: uuid, endedAt: Date(), reason: reason.cxReason)
            }
            completion()
        }
    }

    func reportAgain(sessionId: String, then: @escaping () -> Void) -> Bool {
        guard let uuid = uuid(for: sessionId) else { return false }
        // A placeholder under a new UUID would be a second incoming call: on a
        // locked phone iOS puts it up full screen, then shows it ending.
        provider.reportNewIncomingCall(with: uuid, update: CXCallUpdate()) { _ in
            // Refused as callUUIDAlreadyExists: the report was made, which is
            // what PushKit asks for.
            DispatchQueue.main.async(execute: then)
        }
        return true
    }

    func endCall(sessionId: String, reason: CallEndReason) {
        guard let uuid = uuid(for: sessionId) else { return }
        forget(uuid: uuid)
        provider.reportCall(with: uuid, endedAt: Date(), reason: reason.cxReason)
    }

    func isShowing(sessionId: String) -> Bool {
        uuid(for: sessionId) != nil
    }

    // MARK: - Acting for the app

    /// Answers through CallKit, so its screen moves to the call and it
    /// activates the audio session. False when CallKit shows no such call.
    func requestAnswer(sessionId: String) -> Bool {
        guard let uuid = uuid(for: sessionId) else { return false }
        callController.request(CXTransaction(action: CXAnswerCallAction(call: uuid))) { error in
            if let error = error { VoipLog.w("answer request failed: \(error.localizedDescription)") }
        }
        return true
    }

    /// Ends through CallKit, which then asks the provider to — the same path
    /// as the user's own End or Decline. False when CallKit shows no such call.
    func requestEnd(sessionId: String) -> Bool {
        guard let uuid = uuid(for: sessionId) else { return false }
        callController.request(CXTransaction(action: CXEndCallAction(call: uuid))) { error in
            if let error = error { VoipLog.w("end request failed: \(error.localizedDescription)") }
        }
        return true
    }

    /// An outgoing call, so it survives a cellular interruption, appears in
    /// Recents and can be ended from the lock screen — from the moment the
    /// call is placed, as the native iOS SDK reports it, so a call nobody
    /// answers can still be hung up from the lock screen and still leaves a
    /// Recents entry. Skipped when CallKit already shows this session.
    func reportOutgoingCall(sessionId: String, calleeName: String, hasVideo: Bool) {
        guard uuid(for: sessionId) == nil else {
            VoipLog.d("\(sessionId) is already reported — not reporting an outgoing call on top")
            return
        }
        let uuid = UUID()
        associate(uuid: uuid, sessionId: sessionId)
        lock.lock(); outgoingSessionIds.insert(sessionId); lock.unlock()

        VoipLog.i("CallKit: starting outgoing call \(sessionId)")
        let action = CXStartCallAction(
            call: uuid,
            handle: CXHandle(type: .generic, value: calleeName)
        )
        action.isVideo = hasVideo
        callController.request(CXTransaction(action: action)) { [weak self] error in
            if let error = error {
                VoipLog.w("could not report the outgoing call \(sessionId): \(error.localizedDescription)")
                self?.forget(uuid: uuid)
                return
            }
            self?.outgoingCallStarted(sessionId: sessionId, uuid: uuid)
        }
    }

    /// CallKit confirmed the start: the call is connecting. A no-op when the
    /// connect beat the confirmation here and reported it already.
    private func outgoingCallStarted(sessionId: String, uuid: UUID) {
        lock.lock()
        let reportedAlready = startedOutgoingSessionIds.contains(sessionId)
        startedOutgoingSessionIds.insert(sessionId)
        lock.unlock()
        guard !reportedAlready else { return }
        VoipLog.i("CallKit: outgoing call \(sessionId) started")
        provider.reportOutgoingCall(with: uuid, startedConnectingAt: Date())
    }

    /// Names the other party of an outgoing call this package reported on its
    /// own, once the Calls SDK has said who it is. The handle is the uid, which
    /// is what a call back from Recents dials.
    func updateCallee(sessionId: String, uid: String?, name: String) {
        guard let uuid = uuid(for: sessionId) else { return }
        let update = CXCallUpdate()
        update.remoteHandle = CXHandle(type: .generic, value: uid ?? name)
        update.localizedCallerName = name
        provider.reportCall(with: uuid, updated: update)
    }

    // MARK: - NativeCallSurface

    /// The session joined: CallKit's timer starts now.
    ///
    /// A call reported at the moment it joined — a plain `joinSession` nobody
    /// reported — connects before CallKit has confirmed its start. The
    /// connecting state is then reported here, together with the connect,
    /// rather than waiting for that confirmation to carry it: the connect
    /// happens once per session, so a confirmation that never arrives left the
    /// call on "Connecting" for the rest of the call. Found on a device.
    ///
    /// Reporting both in order is what iOS asks for, and the connecting report
    /// is skipped once either side has made it.
    func reportConnected(sessionId: String) {
        guard let uuid = uuid(for: sessionId) else { return }
        lock.lock()
        let outgoing = outgoingSessionIds.contains(sessionId)
        let started = startedOutgoingSessionIds.contains(sessionId)
        if outgoing { startedOutgoingSessionIds.insert(sessionId) }
        lock.unlock()
        guard outgoing else { return }
        if !started {
            VoipLog.i("CallKit: outgoing call \(sessionId) connected before CallKit confirmed its start — reporting the connecting state with it")
            provider.reportOutgoingCall(with: uuid, startedConnectingAt: Date())
        }
        VoipLog.i("CallKit: outgoing call \(sessionId) connected")
        provider.reportOutgoingCall(with: uuid, connectedAt: Date())
    }

    /// Reflects a mute made in the app on the native screen.
    func setMuted(sessionId: String, muted: Bool) {
        guard let uuid = uuid(for: sessionId) else { return }
        callController.request(CXTransaction(action: CXSetMutedCallAction(call: uuid, muted: muted))) { error in
            if let error = error { VoipLog.w("mute mirror failed: \(error.localizedDescription)") }
        }
    }

    func updateHasVideo(sessionId: String, hasVideo: Bool) {
        guard let uuid = uuid(for: sessionId) else { return }
        let update = CXCallUpdate()
        update.hasVideo = hasVideo
        provider.reportCall(with: uuid, updated: update)
    }

    // MARK: - Association

    private func associate(uuid: UUID, sessionId: String) {
        lock.lock(); defer { lock.unlock() }
        sessionIdsByUUID[uuid] = sessionId
        uuidsBySessionId[sessionId] = uuid
    }

    private func forget(uuid: UUID) {
        lock.lock(); defer { lock.unlock() }
        if let sessionId = sessionIdsByUUID.removeValue(forKey: uuid) {
            uuidsBySessionId.removeValue(forKey: sessionId)
            outgoingSessionIds.remove(sessionId)
            startedOutgoingSessionIds.remove(sessionId)
        }
    }

    private func sessionId(for uuid: UUID) -> String? {
        lock.lock(); defer { lock.unlock() }
        return sessionIdsByUUID[uuid]
    }

    private func uuid(for sessionId: String) -> UUID? {
        lock.lock(); defer { lock.unlock() }
        return uuidsBySessionId[sessionId]
    }

    static func reportError(from error: Error) -> ReportError {
        let nsError = error as NSError
        guard nsError.domain == CXErrorDomainIncomingCall,
              let code = CXErrorCodeIncomingCallError.Code(rawValue: nsError.code) else {
            return .unknown(error.localizedDescription)
        }
        switch code {
        case .filteredByDoNotDisturb: return .filteredByDoNotDisturb
        case .filteredByBlockList: return .filteredByBlockList
        case .callUUIDAlreadyExists: return .callUUIDAlreadyExists
        case .unentitled: return .unentitled
        // Includes codes newer SDKs add, which this build cannot name.
        default: return .unknown(error.localizedDescription)
        }
    }
}

// MARK: - CXProviderDelegate

extension CallKitManager: CXProviderDelegate {

    func providerDidReset(_ provider: CXProvider) {
        VoipLog.w("CallKit reset")
        lock.lock()
        sessionIdsByUUID.removeAll()
        uuidsBySessionId.removeAll()
        outgoingSessionIds.removeAll()
        startedOutgoingSessionIds.removeAll()
        lock.unlock()
        actions?.providerDidReset()
    }

    /// `fulfill` tells CallKit the app is ready for the call; failing takes it
    /// off the screen, which is right when this process has no record of the
    /// session and so nothing to join.
    func provider(_ provider: CXProvider, perform action: CXAnswerCallAction) {
        guard let sessionId = sessionId(for: action.callUUID) else {
            action.fail()
            return
        }
        // Configure only, never setActive: CallKit activates it (didActivate).
        do {
            try AVAudioSession.sharedInstance().setCategory(.playAndRecord, mode: .voiceChat, options: [.allowBluetooth, .allowBluetoothA2DP])
        } catch {
            VoipLog.w("audio session category failed: \(error.localizedDescription)")
        }
        if actions?.nativeAnswer(sessionId: sessionId) == true {
            action.fulfill()
        } else {
            action.fail()
        }
    }

    /// Declining a ringing call, hanging up an answered one, or ending an
    /// outgoing one. CallKit has already torn its screen down; the action is
    /// always fulfilled so it never keeps a zombie call.
    func provider(_ provider: CXProvider, perform action: CXEndCallAction) {
        if let sessionId = sessionId(for: action.callUUID) {
            forget(uuid: action.callUUID)
            actions?.nativeEnd(sessionId: sessionId)
        }
        action.fulfill()
    }

    func provider(_ provider: CXProvider, perform action: CXStartCallAction) {
        // Requested by reportOutgoingCall; the app is already joining.
        action.fulfill()
    }

    func provider(_ provider: CXProvider, perform action: CXSetMutedCallAction) {
        if let sessionId = sessionId(for: action.callUUID) {
            actions?.nativeSetMuted(sessionId: sessionId, muted: action.isMuted)
        }
        action.fulfill()
    }

    func provider(_ provider: CXProvider, perform action: CXSetHeldCallAction) {
        if let sessionId = sessionId(for: action.callUUID) {
            actions?.nativeSetHeld(sessionId: sessionId, held: action.isOnHold)
        }
        action.fulfill()
    }

    func provider(_ provider: CXProvider, didActivate audioSession: AVAudioSession) {
        actions?.audioSessionDidActivate(audioSession)
    }

    func provider(_ provider: CXProvider, didDeactivate audioSession: AVAudioSession) {
        actions?.audioSessionDidDeactivate(audioSession)
    }
}
