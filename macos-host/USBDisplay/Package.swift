// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "USBDisplay",
    platforms: [
        .macOS(.v13)
    ],
    products: [
        .executable(name: "USBDisplay", targets: ["USBDisplay"])
    ],
    targets: [
        // Objective-C module for CGVirtualDisplay private API
        .target(
            name: "VirtualDisplay",
            path: "USBDisplay/VirtualDisplay",
            publicHeadersPath: ".",
            cSettings: [
                .headerSearchPath(".")
            ]
        ),
        .executableTarget(
            name: "USBDisplay",
            dependencies: ["VirtualDisplay"],
            path: "USBDisplay",
            exclude: ["VirtualDisplay", "VirtualDisplay.swift"],
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
