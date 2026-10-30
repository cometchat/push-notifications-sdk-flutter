import Foundation
import XCTest
@testable import cometchat_voip

/// Test doubles for the ring machinery, mirroring the native SDK's
/// `CallWaitingTests` fixtures: a CallKit that records, hooks that record and
/// can be told what the Calls SDK has joined, and a scheduler that never fires.
enum TestCalls {

    /// A fresh, empty `UserDefaults` suite per test.
    static func scratchDefaults(_ name: String) -> UserDefaults {
        let suite = "cometchat_voip.tests.\(name).\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        return defaults
    }

    /// A one-to-one audio call that started ringing now and rings for 45 s.
    static func make(_ sessionId: String, initiatedAtMs: Int64 = TestRingClock.start) -> IncomingCall {
        IncomingCall(
            sessionId: sessionId,
            callerUid: "alice",
            callerName: "Alice Demo",
            callerAvatarUrl: nil,
            callType: IncomingCall.typeAudio,
            receiverType: IncomingCall.receiverTypeUser,
            receiverUid: "bob",
            conversationId: nil,
            initiatedAtMs: initiatedAtMs,
            ringTimeoutMs: RingConstants.defaultRingTimeoutMs
        )
    }
}

/// A clock that stands still unless the test moves it.
final class TestRingClock: RingClock {
    static let start: Int64 = 1_700_000_000_000
    var nowMs: Int64 = TestRingClock.start
}

/// Work scheduled here never runs by itself; the test fires it.
final class TestRingScheduler: RingScheduler {

    final class Work: RingScheduledWork {
        let delay: TimeInterval
        let block: () -> Void
        private(set) var cancelled = false
        init(delay: TimeInterval, block: @escaping () -> Void) {
            self.delay = delay
            self.block = block
        }
        func cancel() { cancelled = true }
    }

    private(set) var scheduled: [Work] = []

    func schedule(after delay: TimeInterval, _ work: @escaping () -> Void) -> RingScheduledWork {
        let item = Work(delay: delay, block: work)
        scheduled.append(item)
        return item
    }
}

/// CallKit, remembering what was reported and ended.
final class FakeCallKit: IncomingCallUi {

    private(set) var reportedSessionIds: [String] = []
    private(set) var endedReasons: [(String, CallEndReason)] = []
    private var showing: Set<String> = []

    /// What the next report answers with; nil accepts.
    var nextReportError: ReportError?

    func reportIncomingCall(_ call: IncomingCall, completion: @escaping (ReportError?) -> Void) {
        reportedSessionIds.append(call.sessionId)
        if let error = nextReportError {
            nextReportError = nil
            completion(error)
            return
        }
        showing.insert(call.sessionId)
        completion(nil)
    }

    func reportAndEndImmediately(callerName: String, hasVideo: Bool, reason: CallEndReason, completion: @escaping () -> Void) {
        completion()
    }

    func reportAgain(sessionId: String, then: @escaping () -> Void) -> Bool {
        guard showing.contains(sessionId) else { return false }
        then()
        return true
    }

    func endCall(sessionId: String, reason: CallEndReason) {
        guard showing.remove(sessionId) != nil else { return }
        endedReasons.append((sessionId, reason))
    }

    func isShowing(sessionId: String) -> Bool { showing.contains(sessionId) }

    /// Stands for a call this device PLACED: on CallKit without ever having
    /// been reported as incoming.
    func showOutgoing(sessionId: String) { showing.insert(sessionId) }
}

/// The hooks, recording every call and told by the test what the Calls SDK
/// has joined — `joinedSessionId` is what a join without a prepare reports
/// through the sync engine, `joinedSessions` what `isSessionJoined` sees.
final class RecordingHooks: RingHooks {

    var joinedSessionId: String?
    var joinedSessions: Set<String> = []

    private(set) var started: [String] = []
    private(set) var stopped: [(String, CallEndReason)] = []
    private(set) var answered: [String] = []
    private(set) var declined: [(String, String)] = []
    private(set) var ended: [(String, CallEndReason)] = []

    func onRingStarted(_ call: IncomingCall) { started.append(call.sessionId) }
    func onRingStopped(sessionId: String, reason: CallEndReason) { stopped.append((sessionId, reason)) }
    func onAnswered(_ call: IncomingCall) { answered.append(call.sessionId) }
    func onDeclined(sessionId: String, status: String) { declined.append((sessionId, status)) }
    func onCallEnded(_ call: IncomingCall, reason: CallEndReason) { ended.append((call.sessionId, reason)) }
    func isSessionJoined(sessionId: String) -> Bool { joinedSessions.contains(sessionId) }
    func hasJoined(_ sessionId: String) -> Bool { joinedSessionId == sessionId || joinedSessions.contains(sessionId) }
    func isInAnotherCall(than sessionId: String) -> Bool {
        if let joined = joinedSessionId, joined != sessionId { return true }
        return joinedSessions.contains { $0 != sessionId }
    }
    func onOwnCallEnded(_ call: IncomingCall, action: String) {}
}

/// The native call surface, remembering what the sync asked of it.
final class FakeNativeSurface: NativeCallSurface {

    private(set) var connected: [String] = []
    private(set) var muted: [(String, Bool)] = []
    private(set) var videoFlags: [(String, Bool)] = []
    private(set) var ended: [(String, CallEndReason)] = []
    /// The calls CallKit is showing. A test sets it to stand for a reported call.
    var showing: Set<String> = []

    func setMuted(sessionId: String, muted: Bool) { self.muted.append((sessionId, muted)) }
    func updateHasVideo(sessionId: String, hasVideo: Bool) { videoFlags.append((sessionId, hasVideo)) }
    func reportConnected(sessionId: String) { connected.append(sessionId); showing.insert(sessionId) }

    func endCall(sessionId: String, reason: CallEndReason) {
        ended.append((sessionId, reason))
        showing.remove(sessionId)
    }

    func isShowing(sessionId: String) -> Bool { showing.contains(sessionId) }
}

/// The Calls SDK session, counting what the sync did to it.
final class FakeSession: SessionControl {

    var isJoined = false
    private(set) var leaves = 0
    private(set) var mutes: [Bool] = []
    private(set) var videoPauses: [Bool] = []

    func muteAudio() { mutes.append(true) }
    func unmuteAudio() { mutes.append(false) }
    func pauseVideo() { videoPauses.append(true) }
    func resumeVideo() { videoPauses.append(false) }
    func leaveSession() { leaves += 1; isJoined = false }
}
