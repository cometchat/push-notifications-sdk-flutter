import AVFoundation
import UIKit

/// The microphone, and the camera for video, asked for on Answer. After the
/// answer is delivered, never blocking the join: a denial joins muted. On a
/// lock-screen answer the prompt cannot show until unlock, so it waits for the
/// app to become active.
enum CallPermissions {

    static var microphoneDenied: Bool {
        let status = AVCaptureDevice.authorizationStatus(for: .audio)
        return status == .denied || status == .restricted
    }

    /// The wire names of what answering needs and iOS has not granted.
    ///
    /// `notDetermined` counts as missing — nothing has been asked yet — and so
    /// does a denial, which the app can send the user to Settings for.
    static func missing(video: Bool) -> [String] {
        var names: [String] = []
        if AVCaptureDevice.authorizationStatus(for: .audio) != .authorized { names.append("microphone") }
        if video, AVCaptureDevice.authorizationStatus(for: .video) != .authorized { names.append("camera") }
        return names
    }

    /// Asks for whatever [missing] reports, then says whether all of it is
    /// granted. A denial already recorded cannot be asked for again, so it
    /// comes straight back as false.
    static func request(video: Bool, completion: @escaping (Bool) -> Void) {
        let pending = (video ? [AVMediaType.audio, .video] : [.audio])
            .filter { AVCaptureDevice.authorizationStatus(for: $0) == .notDetermined }
        guard !pending.isEmpty else {
            completion(missing(video: video).isEmpty)
            return
        }
        request(pending) {
            DispatchQueue.main.async { completion(missing(video: video).isEmpty) }
        }
    }

    static func requestIfNeeded(video: Bool) {
        let pending = (video ? [AVMediaType.audio, .video] : [.audio])
            .filter { AVCaptureDevice.authorizationStatus(for: $0) == .notDetermined }
        guard !pending.isEmpty else { return }
        if UIApplication.shared.applicationState == .active {
            request(pending)
        } else {
            let observer = Observer()
            observer.token = NotificationCenter.default.addObserver(forName: UIApplication.didBecomeActiveNotification, object: nil, queue: .main) { _ in
                if let token = observer.token { NotificationCenter.default.removeObserver(token) }
                observer.token = nil
                request(pending)
            }
        }
    }

    /// Holds the observer's token, so the observer can remove itself.
    private final class Observer {
        var token: NSObjectProtocol?
    }

    /// One prompt after another, then [done].
    private static func request(_ types: [AVMediaType], done: (() -> Void)? = nil) {
        guard let first = types.first else {
            done?()
            return
        }
        AVCaptureDevice.requestAccess(for: first) { _ in
            DispatchQueue.main.async { request(Array(types.dropFirst()), done: done) }
        }
    }
}
