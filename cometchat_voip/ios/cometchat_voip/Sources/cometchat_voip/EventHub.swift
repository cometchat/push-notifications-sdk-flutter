import Flutter
import Foundation

/// What the ringer tells Dart: calls answered, calls ended, VoIP token changes.
///
/// Process-wide, because the ringer runs from PushKit and CallKit whether or
/// not any engine is listening, and an app can run several engines. Every
/// listening engine hears each event; with none listening, events are held for
/// the first that does. A call answered on the lock screen of a killed app is
/// always answered before Dart has subscribed.
final class EventHub {

    /// Beyond this the oldest are dropped: a stale answer is worse than none.
    private static let heldLimit = 8

    private var sinks: [ObjectIdentifier: FlutterEventSink] = [:]
    private var held: [[String: Any]] = []

    func answered(_ call: IncomingCall) {
        send(["event": "answered", "call": call.toMap()])
    }

    func ended(_ call: IncomingCall, reason: CallEndReason) {
        send(["event": "ended", "call": call.toMap(), "reason": reason.rawValue])
    }

    /// The native call screen ended an outgoing call. There is no
    /// `IncomingCall` for one, and the incoming store knows nothing about it,
    /// so `ended` cannot carry it: the app is told by session id and withdraws
    /// the call itself. Without this, hanging up an outgoing call from the lock
    /// screen took the CallKit call away and left the app's own outgoing screen
    /// up, with the callee still ringing.
    func outgoingEnded(sessionId: String) {
        send(["event": "outgoingEnded", "sessionId": sessionId])
    }

    func voipToken(_ token: String) {
        send(["event": "voipToken", "token": token])
    }

    /// One per engine.
    func makeStreamHandler() -> FlutterStreamHandler & NSObject {
        StreamHandler(hub: self)
    }

    private func send(_ event: [String: Any]) {
        DispatchQueue.main.async { [self] in
            guard !sinks.isEmpty else {
                // A token is only ever wanted fresh: Dart's `init` asks for
                // it with `getVoipToken`, which is what registers the one
                // PushKit delivered in didFinishLaunching, before any Dart.
                guard event["event"] as? String != "voipToken" else { return }
                held.append(event)
                if held.count > EventHub.heldLimit { held.removeFirst() }
                return
            }
            sinks.values.forEach { $0(event) }
        }
    }

    fileprivate func attach(_ handler: StreamHandler, sink: @escaping FlutterEventSink) {
        DispatchQueue.main.async { [self] in
            sinks[ObjectIdentifier(handler)] = sink
            let backlog = held
            held = []
            backlog.forEach { sink($0) }
        }
    }

    fileprivate func detach(_ handler: StreamHandler) {
        DispatchQueue.main.async { [self] in
            sinks.removeValue(forKey: ObjectIdentifier(handler))
        }
    }

    fileprivate final class StreamHandler: NSObject, FlutterStreamHandler {
        private weak var hub: EventHub?

        init(hub: EventHub) {
            self.hub = hub
        }

        func onListen(withArguments arguments: Any?, eventSink events: @escaping FlutterEventSink) -> FlutterError? {
            hub?.attach(self, sink: events)
            return nil
        }

        func onCancel(withArguments arguments: Any?) -> FlutterError? {
            hub?.detach(self)
            return nil
        }
    }
}
