// swift-tools-version: 5.9
// The swift-tools-version declares the minimum version of Swift required to
// build this package and the Flutter Swift Package Manager integration.

import PackageDescription

// No Calls SDK dependency. This package links `cometchat_calls_sdk` through
// Dart alone: everything that needs the SDK goes back over DartCallsBridge,
// and CallKit belongs to the Calls SDK. So nothing here declares — or has to
// keep in step with — the native Calls SDK binaries.
let package = Package(
    name: "cometchat_voip",
    platforms: [
        .iOS("15.1")
    ],
    products: [
        .library(name: "cometchat-voip", targets: ["cometchat_voip"])
    ],
    targets: [
        .target(
            name: "cometchat_voip",
            resources: [
                .process("Resources/PrivacyInfo.xcprivacy")
            ],
            linkerSettings: [
                .linkedFramework("PushKit"),
                .linkedFramework("CallKit"),
                .linkedFramework("AVFoundation")
            ]
        ),
        // The ring machinery's unit tests. Flutter's plugin integration builds
        // the library product only, so this target never reaches an app. The
        // sources import `Flutter`, so the tests build against the engine's
        // `Flutter.xcframework` — see Tests/cometchat_voipTests/README.md.
        .testTarget(
            name: "cometchat_voipTests",
            dependencies: ["cometchat_voip"]
        )
    ]
)
