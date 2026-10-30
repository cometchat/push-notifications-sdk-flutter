import Flutter
import Foundation

/// Carries notification taps and quick replies to Dart.
///
/// Anything that arrives before Dart is listening is buffered, not dropped. A
/// tap that launched the app from a cold start always lands in that window: iOS
/// delivers it during startup, well before the Dart side has attached.
final class ResponseStreamHandler: NSObject, FlutterStreamHandler {

    private var sink: FlutterEventSink?
    private var pending: [[String: Any?]] = []

    /// Sends [event] to Dart, buffering it while nothing is listening.
    func send(_ event: [String: Any?]) {
        DispatchQueue.main.async {
            guard let sink = self.sink else {
                self.pending.append(event)
                return
            }
            sink(event)
        }
    }

    func onListen(
        withArguments arguments: Any?,
        eventSink events: @escaping FlutterEventSink
    ) -> FlutterError? {
        sink = events
        let buffered = pending
        pending = []
        buffered.forEach { events($0) }
        return nil
    }

    func onCancel(withArguments arguments: Any?) -> FlutterError? {
        sink = nil
        return nil
    }
}
