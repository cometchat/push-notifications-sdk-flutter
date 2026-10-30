import XCTest
@testable import cometchat_voip

/// Call waiting: a call rings while another is in progress. CallKit offers
/// Decline, which leaves the call in progress alone and tells the caller
/// `busy`, and End & Accept, which ends the call in progress and answers the
/// new one. Mirrors the native SDK's `CallWaitingTests`.
final class CallWaitingTests: XCTestCase {

    private var defaults: UserDefaults!
    private var store: CallStore!
    private var ui: FakeCallKit!
    private var hooks: RecordingHooks!
    private var controller: RingController!

    override func setUp() {
        super.setUp()
        defaults = TestCalls.scratchDefaults("CallWaitingTests")
        store = CallStore(defaults: defaults)
        ui = FakeCallKit()
        hooks = RecordingHooks()
        controller = RingController(store: store, ui: ui,
                                    expiry: RingExpiry(scheduler: TestRingScheduler(), clock: TestRingClock()))
        controller.hooks = hooks
    }

    private func ring(_ sessionId: String) {
        controller.startRinging(TestCalls.make(sessionId), completion: {})
    }

    /// `s1` answered and joined, then `s2` rings on top of it.
    private func inACallWhileAnotherRings() {
        ring("s1")
        controller.answer(sessionId: "s1")
        hooks.joinedSessionId = "s1"
        hooks.joinedSessions = ["s1"]
        ring("s2")
    }

    private func endedSessions() -> [String] { ui.endedReasons.map { $0.0 } }

    // MARK: - Ringing on top of a call

    func testACallRingingOnTopLeavesTheCallInProgressOnCallKit() {
        inACallWhileAnotherRings()
        XCTAssertTrue(ui.isShowing(sessionId: "s1"), "ending it would take the call's audio away")
        XCTAssertFalse(endedSessions().contains("s1"))
        XCTAssertTrue(ui.isShowing(sessionId: "s2"))
        XCTAssertEqual(store.get()?.call.sessionId, "s2")
        XCTAssertEqual(store.get()?.state, .ringing)
        XCTAssertEqual(store.held?.call.sessionId, "s1")
        XCTAssertTrue(hooks.ended.isEmpty)
    }

    func testARingingCallIsStillReplacedByANewerOne() {
        ring("s1")
        ring("s2")
        XCTAssertEqual(endedSessions(), ["s1"])
        XCTAssertNil(store.held)
    }

    func testDecliningSaysBusyAndGivesTheCallInProgressItsSlotBack() {
        inACallWhileAnotherRings()
        controller.decline(sessionId: "s2")
        XCTAssertEqual(hooks.declined.map { $0.0 }, ["s2"])
        XCTAssertEqual(hooks.declined.last?.1, RingConstants.Status.busy)
        XCTAssertEqual(endedSessions(), ["s2"])
        XCTAssertTrue(ui.isShowing(sessionId: "s1"))
        XCTAssertEqual(store.get()?.call.sessionId, "s1", "the call in progress takes the active slot back")
        XCTAssertEqual(store.get()?.state, .answered)
        XCTAssertNil(store.held)
    }

    // MARK: - An answered call that is no longer in a session

    /// `s1` was answered a minute ago by a process that has since ended: no
    /// session, no end event.
    private func answeredByAnEndedProcess() {
        ring("s1")
        store.markAnswered(sessionId: "s1", now: Date().addingTimeInterval(-60))
    }

    func testAnAnsweredCallNoLongerInASessionIsDroppedWhenAnotherRings() {
        answeredByAnEndedProcess()
        ring("s2")
        XCTAssertTrue(store.isRinging(sessionId: "s2"))
        XCTAssertNil(store.held)
        XCTAssertFalse(store.isAnswered(sessionId: "s1"))
        XCTAssertNil(store.answeredSessionOtherThan("s2"))
        XCTAssertEqual(store.terminalReason(sessionId: "s1"), "no_session")
    }

    func testTheDroppedCallDoesNotComeBackWhenTheNextCallEnds() {
        answeredByAnEndedProcess()
        ring("s2")
        controller.answer(sessionId: "s2")
        hooks.joinedSessionId = "s2"
        hooks.joinedSessions = ["s2"]
        controller.sessionEnded(sessionId: "s2", reason: .remoteEnded)
        XCTAssertNil(store.get())
        XCTAssertNil(store.held)
    }

    func testACallAnsweredMomentsAgoIsStillHeldWhileItJoins() {
        ring("s1")
        controller.answer(sessionId: "s1")
        ring("s2")
        XCTAssertEqual(store.held?.call.sessionId, "s1")
        XCTAssertFalse(endedSessions().contains("s1"))
    }

    func testAHeldCallThatIsNoLongerInASessionIsDroppedWhenAThirdRings() {
        ring("s1")
        store.markAnswered(sessionId: "s1", now: Date().addingTimeInterval(-60))
        hooks.joinedSessionId = "s1"
        hooks.joinedSessions = ["s1"]
        ring("s2")
        XCTAssertEqual(store.held?.call.sessionId, "s1")
        hooks.joinedSessionId = nil
        hooks.joinedSessions = []
        ring("s3")
        XCTAssertTrue(store.isRinging(sessionId: "s3"))
        XCTAssertNil(store.held)
        XCTAssertEqual(store.terminalReason(sessionId: "s1"), "no_session")
    }

    func testAnAnsweredCallJoinedWithoutAPrepareIsNotDropped() {
        // A call answered over a live one is joined without a prepare, so the
        // Calls SDK reports no session id for it; the sync engine's view is
        // what says it joined.
        ring("s1")
        store.markAnswered(sessionId: "s1", now: Date().addingTimeInterval(-60))
        hooks.joinedSessionId = "s1"
        hooks.joinedSessions = []
        ring("s2")
        XCTAssertEqual(store.held?.call.sessionId, "s1")
        XCTAssertNil(store.terminalReason(sessionId: "s1"))
    }

    // MARK: - Persistence

    func testTheHeldCallAndWhenItWasAnsweredSurviveARelaunch() {
        let answeredAt = Date().addingTimeInterval(-5)
        ring("s1")
        store.markAnswered(sessionId: "s1", now: answeredAt)
        ring("s2")

        let relaunched = CallStore(defaults: defaults)
        XCTAssertEqual(relaunched.get()?.call.sessionId, "s2")
        XCTAssertEqual(relaunched.held?.call.sessionId, "s1")
        XCTAssertEqual(relaunched.held?.answeredAt?.timeIntervalSince1970 ?? 0,
                       answeredAt.timeIntervalSince1970, accuracy: 0.001)
    }

    func testAnAnsweredCallFromBeforeAnsweredAtWasRecordedIsDropped() {
        // Written by an older build: answered, with no `answeredAt`. Nothing
        // says it is still joining, so it is over.
        ring("s1")
        controller.answer(sessionId: "s1")
        defaults.removeObject(forKey: "callStore.answeredAt")
        let relaunched = CallStore(defaults: defaults)
        XCTAssertNil(relaunched.get()?.answeredAt)
        controller = RingController(store: relaunched, ui: ui,
                                    expiry: RingExpiry(scheduler: TestRingScheduler(), clock: TestRingClock()))
        controller.hooks = hooks
        ring("s2")
        XCTAssertTrue(relaunched.isRinging(sessionId: "s2"))
        XCTAssertNil(relaunched.held)
    }
}
