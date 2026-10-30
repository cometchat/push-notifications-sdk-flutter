import Foundation
import os.log

/// The package's logger. Never given a token, an auth value or a payload: the
/// first two are live credentials, and the Calls SDK already logs auth headers.
enum VoipLog {
    private static let log = OSLog(subsystem: "com.cometchat.voip", category: "calls")

    static func d(_ message: @autoclosure () -> String) { os_log("%{public}@", log: log, type: .debug, message()) }
    static func i(_ message: @autoclosure () -> String) { os_log("%{public}@", log: log, type: .info, message()) }
    static func w(_ message: @autoclosure () -> String) { os_log("%{public}@", log: log, type: .default, message()) }
    static func e(_ message: @autoclosure () -> String) { os_log("%{public}@", log: log, type: .error, message()) }
}
