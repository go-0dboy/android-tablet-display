// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "USBDisplayApp",
    platforms: [
        .macOS(.v13)
    ],
    products: [
        .executable(name: "USBDisplayApp", targets: ["USBDisplayApp"]),
        // Standalone diagnostic: does the private virtual-display API work on
        // this machine? Run it before filing a bug.
        .executable(name: "vdprobe", targets: ["VirtualDisplayProbe"]),
        // Draws a machine-readable clock, for measuring end-to-end latency.
        .executable(name: "latencyclock", targets: ["LatencyClock"]),
        // Posts gestures and reports whether applications reacted.
        .executable(name: "gesturelab", targets: ["GestureLab"]),
        .library(name: "USBDisplayCore", targets: ["USBDisplayCore"])
    ],
    targets: [
        // Objective-C bridge to the private CGVirtualDisplay API.
        .target(
            name: "VirtualDisplay",
            path: "Sources/VirtualDisplay",
            publicHeadersPath: ".",
            cSettings: [
                .headerSearchPath(".")
            ]
        ),
        // Pure logic: wire protocol, device selection, display geometry,
        // gesture recognition, display presets. No AppKit, no sockets, so it
        // is testable on any machine including CI.
        .target(
            name: "USBDisplayCore",
            path: "Sources/USBDisplayCore"
        ),
        .executableTarget(
            name: "USBDisplayApp",
            dependencies: ["VirtualDisplay", "USBDisplayCore"],
            path: "Sources/USBDisplayApp",
            resources: [
                .copy("Resources")
            ],
            linkerSettings: [
                .linkedFramework("ScreenCaptureKit"),
                .linkedFramework("VideoToolbox"),
                .linkedFramework("CoreMedia"),
                .linkedFramework("CoreVideo"),
                .linkedFramework("CoreGraphics"),
                .linkedFramework("AppKit")
            ]
        ),
        .executableTarget(
            name: "VirtualDisplayProbe",
            dependencies: ["VirtualDisplay", "USBDisplayCore"],
            path: "Sources/VirtualDisplayProbe",
            linkerSettings: [
                .linkedFramework("CoreGraphics"),
                .linkedFramework("AppKit")
            ]
        ),
        .executableTarget(
            name: "LatencyClock",
            path: "Sources/LatencyClock",
            linkerSettings: [
                .linkedFramework("AppKit"),
                .linkedFramework("CoreGraphics")
            ]
        ),
        .executableTarget(
            name: "GestureLab",
            dependencies: ["USBDisplayCore"],
            path: "Sources/GestureLab",
            linkerSettings: [
                .linkedFramework("AppKit"),
                .linkedFramework("CoreGraphics")
            ]
        ),
        .testTarget(
            name: "USBDisplayCoreTests",
            dependencies: ["USBDisplayCore"],
            path: "Tests/USBDisplayCoreTests"
        )
    ]
)
