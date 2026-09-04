// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "LPW4EXUpdater",
    platforms: [.macOS(.v12)],
    products: [
        .executable(name: "lpw4ex-updater", targets: ["LPW4EXUpdater"]),
        .executable(name: "lpw4ex-updater-gui", targets: ["LPW4EXUpdaterGUI"])
    ],
    targets: [
        .target(
            name: "LPUSBBridge",
            path: "Sources/LPUSBBridge",
            publicHeadersPath: "include",
            linkerSettings: [
                .linkedFramework("IOKit"),
                .linkedFramework("CoreFoundation")
            ]
        ),
        .executableTarget(
            name: "LPW4EXUpdater",
            dependencies: ["LPUSBBridge"]
        ),
        .executableTarget(
            name: "LPW4EXUpdaterGUI",
            path: "Sources/LPW4EXUpdaterGUI"
        )
    ]
)
