import XCTest
@testable import cometchat_voip

/// The caller side and the join race, both ported from the native iOS SDK.
///
/// An outgoing call is on CallKit from the moment it is placed, so a session
/// the Calls SDK owns that CallKit has not heard of is one nobody reported
/// (`UnreportedSession`), and a call hung up while its join is still in flight
/// has to be left the moment the join lands (`CallKitSyncEngine`).
final class OutgoingCallTests: XCTestCase {

    // MARK: - Which session is an unreported outgoing call

    private func store(_ name: String) -> CallStore {
        CallStore(defaults: TestCalls.scratchDefaults(name))
    }

    func testASessionCallKitHasNotHeardOfIsReportedAsOutgoing() {
        XCTAssertEqual(
            UnreportedSession.outgoingSessionToReport(
                ownedSessionId: "s1",
                trackedSessionId: nil,
                isOnCallKit: { _ in false },
                store: store(#function)
            ),
            "s1"
        )
    }

    func testATrackedSessionIsNotReportedAgain() {
        XCTAssertNil(UnreportedSession.outgoingSessionToReport(
            ownedSessionId: "s1",
            trackedSessionId: "s1",
            isOnCallKit: { _ in false },
            store: store(#function)
        ))
    }

    /// The app's own `reportOutgoingCall` got there first.
    func testASessionAlreadyOnCallKitIsNotReported() {
        XCTAssertNil(UnreportedSession.outgoingSessionToReport(
            ownedSessionId: "s1",
            trackedSessionId: nil,
            isOnCallKit: { $0 == "s1" },
            store: store(#function)
        ))
    }

    /// The session verify-on-wake prepares while an incoming call rings is not
    /// an outgoing call, and reporting it would put a second call on screen.
    func testARingingIncomingCallIsNotReportedAsOutgoing() {
        let store = store(#function)
        XCTAssertTrue(store.setRinging(TestCalls.make("s1")))
        XCTAssertNil(UnreportedSession.outgoingSessionToReport(
            ownedSessionId: "s1",
            trackedSessionId: nil,
            isOnCallKit: { _ in false },
            store: store
        ))
    }

    /// A decline leaves the prepared session open until `endCall` has
    /// announced the status from inside it; that session is not outgoing.
    func testASessionThatIsOverIsNotReported() {
        let store = store(#function)
        store.markTerminal(sessionId: "s1", reason: "declined")
        XCTAssertNil(UnreportedSession.outgoingSessionToReport(
            ownedSessionId: "s1",
            trackedSessionId: nil,
            isOnCallKit: { _ in false },
            store: store
        ))
    }

    func testNoSessionIsNothingToReport() {
        let store = store(#function)
        for owned in [nil, "", "   "] as [String?] {
            XCTAssertNil(UnreportedSession.outgoingSessionToReport(
                ownedSessionId: owned,
                trackedSessionId: nil,
                isOnCallKit: { _ in false },
                store: store
            ))
        }
    }

    // MARK: - A call ended while it was joining

    private struct Sync {
        let engine: CallKitSyncEngine
        let native: FakeNativeSurface
        let session: FakeSession
        let ended: () -> [(String, CallEndReason)]
    }

    private func makeSync(now: @escaping () -> Date = Date.init) -> Sync {
        let native = FakeNativeSurface()
        let session = FakeSession()
        var ended: [(String, CallEndReason)] = []
        let engine = CallKitSyncEngine(native: native, session: session, now: now) { sessionId, reason in
            ended.append((sessionId, reason))
        }
        return Sync(engine: engine, native: native, session: session, ended: { ended })
    }

    /// The user hangs up on the native screen while the answered call is still
    /// joining. There is no session to leave yet, so the leave waits for the
    /// join — without which the join completed with no call tracked: no CallKit
    /// call, no screen, and audio still flowing.
    func testHangingUpBeforeTheJoinLeavesTheSessionWhenItLands() {
        let s = makeSync()
        s.engine.track(sessionId: "s1", videoPaused: false)
        s.native.showing.insert("s1")

        s.engine.nativeEnd(sessionId: "s1")
        XCTAssertEqual(s.session.leaves, 0, "nothing has joined yet")
        XCTAssertEqual(s.ended().map(\.0), ["s1"])
        XCTAssertEqual(s.engine.pendingLeaveSessionId, "s1")

        s.engine.sessionJoined(sessionId: "s1")
        XCTAssertEqual(s.session.leaves, 1)
        XCTAssertTrue(s.native.connected.isEmpty, "an ended call is never reported connected")
        XCTAssertEqual(s.native.ended.map(\.0), ["s1"])
        XCTAssertNil(s.engine.pendingLeaveSessionId)
    }

    /// The same for an end that came from the far side rather than the screen.
    func testARemoteEndBeforeTheJoinLeavesTheSessionWhenItLands() {
        let s = makeSync()
        s.engine.track(sessionId: "s1", videoPaused: false)

        s.engine.callEnded(sessionId: "s1")
        XCTAssertEqual(s.engine.pendingLeaveSessionId, "s1")

        XCTAssertEqual(s.engine.leaveIfEndedWhileJoining(ownedSessionId: "s1"), "s1")
        XCTAssertEqual(s.session.leaves, 1)
    }

    /// A join without a prepare names no session: it counts as the ended
    /// call's only while nothing else is tracked.
    func testAnUnnamedJoinIsTheEndedCallsWhileNothingElseIsTracked() {
        let s = makeSync()
        s.engine.track(sessionId: "s1", videoPaused: false)
        s.engine.callEnded(sessionId: "s1")

        XCTAssertEqual(s.engine.leaveIfEndedWhileJoining(ownedSessionId: nil), "s1")
        XCTAssertEqual(s.session.leaves, 1)
    }

    func testAnUnnamedJoinIsNotTheEndedCallsWhileAnotherIsTracked() {
        let s = makeSync()
        s.engine.track(sessionId: "s1", videoPaused: false)
        s.engine.callEnded(sessionId: "s1")
        s.engine.track(sessionId: "s2", videoPaused: false)

        XCTAssertNil(s.engine.leaveIfEndedWhileJoining(ownedSessionId: nil))
        XCTAssertEqual(s.session.leaves, 0)
    }

    /// The answer-to-joined window closing on a join that never came: the
    /// marker is dropped once, and its owner releases what the SDK still holds.
    func testTheJoinWindowClosingDropsTheMarkerOnce() {
        let s = makeSync()
        s.engine.track(sessionId: "s1", videoPaused: false)
        s.engine.callEnded(sessionId: "s1")

        XCTAssertTrue(s.engine.joinWindowExpired(sessionId: "s1"))
        XCTAssertFalse(s.engine.joinWindowExpired(sessionId: "s1"))
    }

    /// A marker older than the answer-to-joined window must never claim an
    /// unrelated later join.
    func testAStaleMarkerDoesNotClaimALaterJoin() {
        var now = Date()
        let s = makeSync(now: { now })
        s.engine.track(sessionId: "s1", videoPaused: false)
        s.engine.callEnded(sessionId: "s1")

        now = now.addingTimeInterval(TimeInterval(RingConstants.answerToJoinedCapMs) / 1000 + 1)
        XCTAssertNil(s.engine.pendingLeaveSessionId)
        XCTAssertNil(s.engine.leaveIfEndedWhileJoining(ownedSessionId: "s1"))
        XCTAssertEqual(s.session.leaves, 0)
    }

    /// A joined call is left at once; there is nothing to wait for.
    func testHangingUpAJoinedCallLeavesItAtOnce() {
        let s = makeSync()
        s.engine.track(sessionId: "s1", videoPaused: false)
        s.session.isJoined = true
        s.engine.sessionJoined(sessionId: "s1")

        s.engine.nativeEnd(sessionId: "s1")
        XCTAssertEqual(s.session.leaves, 1)
        XCTAssertNil(s.engine.pendingLeaveSessionId)
    }

    // MARK: - The mute CallKit replays

    /// CallKit applies a mute to every call it shows, so a call answered while
    /// another was live arrives muted on the native screen. A session joins
    /// unmuted, and the screen is set to match.
    func testAJoinClearsTheMuteCallKitReplayed() {
        let s = makeSync()
        s.engine.track(sessionId: "s1", videoPaused: false)
        s.engine.nativeSetMuted(sessionId: "s1", muted: true)
        XCTAssertEqual(s.session.mutes, [true])

        s.engine.sessionJoined(sessionId: "s1")
        XCTAssertEqual(s.native.connected, ["s1"])
        XCTAssertEqual(s.native.muted.map(\.1), [false], "the native screen is told the call is live and unmuted")
        XCTAssertEqual(s.engine.state?.muted, false)
    }
}

/// A terminal push about a call this device placed must never be reported as a
/// second call. An outgoing call is on CallKit from the moment it is placed, so
/// a placeholder under a fresh uuid lands as call waiting over a live call, and
/// iOS shows an incoming-call screen for a call that is already over.
final class OwnCallTerminalPushTests: XCTestCase {

    private func make() -> (RingingCallHandler, FakeCallKit, CallStore, RecordingHooks) {
        let store = CallStore(defaults: TestCalls.scratchDefaults("ownTerminal"))
        let ui = FakeCallKit()
        let clock = TestRingClock()
        let controller = RingController(
            store: store,
            ui: ui,
            expiry: RingExpiry(scheduler: TestRingScheduler(), clock: clock)
        )
        let hooks = RecordingHooks()
        controller.hooks = hooks
        return (RingingCallHandler(controller: controller, store: store, clock: clock), ui, store, hooks)
    }

    /// `rejected` carries the callee as `sender` and this user as `receiver`.
    private func declinePush(sessionId: String, callee: String, me: String) -> [AnyHashable: Any] {
        [
            "type": "call",
            "callAction": "rejected",
            "sessionId": sessionId,
            "callType": "audio",
            "sender": callee,
            "senderName": "Alice Demo",
            "receiver": me,
            "receiverType": "user",
        ]
    }

    func testTheCalleesDeclineIsReportedAgainstTheCallersOwnCall() {
        let (handler, ui, store, _) = make()
        store.uid = "bob"
        ui.showOutgoing(sessionId: "s1")

        let done = expectation(description: "push acknowledged")
        handler.handle(payload: declinePush(sessionId: "s1", callee: "alice", me: "bob")) { done.fulfill() }
        wait(for: [done], timeout: 1)

        XCTAssertTrue(ui.reportedSessionIds.isEmpty, "no second call may be reported over the live one")
        XCTAssertEqual(ui.endedReasons.map(\.0), ["s1"], "the caller's own call is ended")
        XCTAssertFalse(ui.isShowing(sessionId: "s1"))
    }

    /// The same push for a call this device never placed has nothing on CallKit
    /// to report against, so the placeholder the VoIP contract asks for stands.
    func testADeclineForACallNotOnCallKitStillReportsAPlaceholder() {
        let (handler, ui, store, _) = make()
        store.uid = "bob"

        let done = expectation(description: "push acknowledged")
        handler.handle(payload: declinePush(sessionId: "s1", callee: "alice", me: "bob")) { done.fulfill() }
        wait(for: [done], timeout: 1)

        XCTAssertTrue(ui.endedReasons.isEmpty, "there was no call to end")
    }

    /// A terminal push the backend fans out to the caller's own devices, with
    /// this user as `sender`, takes the same path.
    func testTheCallersOwnCancelIsReportedAgainstItsOwnCall() {
        let (handler, ui, store, _) = make()
        store.uid = "bob"
        ui.showOutgoing(sessionId: "s1")

        var payload = declinePush(sessionId: "s1", callee: "bob", me: "alice")
        payload["callAction"] = "cancelled"
        let done = expectation(description: "push acknowledged")
        handler.handle(payload: payload) { done.fulfill() }
        wait(for: [done], timeout: 1)

        XCTAssertTrue(ui.reportedSessionIds.isEmpty, "no second call may be reported over the live one")
        XCTAssertEqual(ui.endedReasons.map(\.0), ["s1"])
    }
}
