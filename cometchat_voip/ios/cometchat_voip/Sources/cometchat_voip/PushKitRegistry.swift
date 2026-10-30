import Foundation
import PushKit

protocol PushKitRegistryDelegate: AnyObject {
    func voipTokenDidUpdate(_ token: Data)
    func voipTokenDidInvalidate()
    /// Must report a call to CallKit before calling `completion`.
    func didReceiveVoIPPush(_ payload: [AnyHashable: Any], completion: @escaping () -> Void)
}

/// The package's `PKPushRegistry`, created when the plugin registers — which
/// is inside `didFinishLaunching`, where Apple requires it to exist. On the main
/// queue: the CallKit report that has to follow each push is a main-thread API.
final class PushKitRegistry: NSObject, PKPushRegistryDelegate {

    private let registry = PKPushRegistry(queue: .main)
    weak var delegate: PushKitRegistryDelegate?

    func start() {
        registry.delegate = self
        registry.desiredPushTypes = [.voIP]
    }

    var currentToken: Data? { registry.pushToken(for: .voIP) }

    func pushRegistry(_ registry: PKPushRegistry, didUpdate pushCredentials: PKPushCredentials, for type: PKPushType) {
        guard type == .voIP else { return }
        delegate?.voipTokenDidUpdate(pushCredentials.token)
    }

    func pushRegistry(_ registry: PKPushRegistry, didInvalidatePushTokenFor type: PKPushType) {
        guard type == .voIP else { return }
        delegate?.voipTokenDidInvalidate()
    }

    func pushRegistry(_ registry: PKPushRegistry, didReceiveIncomingPushWith payload: PKPushPayload, for type: PKPushType, completion: @escaping () -> Void) {
        guard type == .voIP, let delegate = delegate else { completion(); return }
        delegate.didReceiveVoIPPush(payload.dictionaryPayload, completion: completion)
    }
}
