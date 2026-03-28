// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "LifeCamWB",
    platforms: [.macOS(.v13)],
    targets: [
        // SwiftUI macOS app — uses CoreMediaIO directly in Swift
        .executableTarget(
            name: "LifeCamWB",
            path: "Sources/LifeCamWB",
            linkerSettings: [
                .linkedFramework("AVFoundation"),
                .linkedFramework("CoreMediaIO"),
                .linkedFramework("CoreFoundation"),
                .linkedFramework("ServiceManagement"),
            ]
        ),
    ]
)
