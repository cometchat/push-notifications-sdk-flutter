// swift-tools-version: 5.9
// The swift-tools-version declares the minimum version of Swift required to
// build this package and the Flutter Swift Package Manager integration.

import PackageDescription

let package = Package(
    name: "cometchat_push_notifications",
    platforms: [
        .iOS("13.0")
    ],
    products: [
        .library(name: "cometchat-push-notifications", targets: ["cometchat_push_notifications"])
    ],
    dependencies: [],
    targets: [
        .target(
            name: "cometchat_push_notifications",
            dependencies: [],
            resources: [
                .process("Resources/PrivacyInfo.xcprivacy")
            ]
        )
    ]
)
