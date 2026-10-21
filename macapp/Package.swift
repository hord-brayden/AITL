// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "AITLBridge",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(
            name: "AITLBridge",
            path: "Sources/AITLBridge",
            linkerSettings: [
                .linkedFramework("AppKit"),
                .linkedFramework("ServiceManagement"),
                .linkedFramework("UserNotifications"),
            ]
        )
    ]
)
