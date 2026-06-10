// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "AIMonitor",
    platforms: [
        .macOS(.v14)
    ],
    products: [
        .executable(name: "AIMonitor", targets: ["AIMonitorApp"]),
        .library(name: "AIMonitorCore", targets: ["AIMonitorCore"])
    ],
    targets: [
        .target(
            name: "AIMonitorCore",
            linkerSettings: [
                .linkedLibrary("sqlite3")
            ]
        ),
        .executableTarget(
            name: "AIMonitorApp",
            dependencies: ["AIMonitorCore"],
            resources: [
                .process("Resources")
            ]
        ),
        .testTarget(
            name: "AIMonitorCoreTests",
            dependencies: ["AIMonitorCore"]
        )
    ]
)
