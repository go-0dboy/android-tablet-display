// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "USBDisplayApp",
    platforms: [
        .macOS(.v13)
    ],
    products: [
        .executable(name: "USBDisplayApp", targets: ["USBDisplayApp"])
    ],
    targets: [
        // Objective-C module for CGVirtualDisplay private API
        .target(
            name: "VirtualDisplay",
            path: "Sources/VirtualDisplay",
            publicHeadersPath: ".",
            cSettings: [
                .headerSearchPath(".")
            ]
        ),
        .executableTarget(
            name: "USBDisplayApp",
            dependencies: ["VirtualDisplay"],
            path: "Sources/USBDisplayApp",
            resources: [
                .copy("Resources")
            ],
            swiftSettings: [
                .unsafeFlags(["-parse-as-library"])
            ],
            linkerSettings: [
                .linkedFramework("ScreenCaptureKit"),
                .linkedFramework("VideoToolbox"),
                .linkedFramework("CoreMedia"),
                .linkedFramework("CoreVideo"),
                .linkedFramework("CoreGraphics"),
                .linkedFramework("AppKit")
            ]
        )
    ]
)
