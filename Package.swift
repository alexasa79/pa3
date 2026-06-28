// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "pa3",
    platforms: [
        .macOS(.v14)
    ],
    products: [
        .executable(name: "pa3", targets: ["PA3"])
    ],
    targets: [
        .executableTarget(
            name: "PA3",
            linkerSettings: [
                .linkedFramework("AppKit"),
                .linkedFramework("SwiftUI"),
                .linkedFramework("AVFoundation"),
                .linkedFramework("CoreAudio"),
                .linkedFramework("AudioToolbox"),
                .linkedFramework("Carbon")
            ]
        )
    ]
)
