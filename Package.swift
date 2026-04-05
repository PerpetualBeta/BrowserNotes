// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "BrowserNotes",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(
            name: "BrowserNotes",
            path: "Sources",
            linkerSettings: [
                .unsafeFlags(["-framework", "AppKit"]),
                .unsafeFlags(["-framework", "ApplicationServices"]),
                .unsafeFlags(["-framework", "ServiceManagement"]),
            ]
        )
    ]
)
