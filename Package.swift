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
        .systemLibrary(name: "CSQLite", pkgConfig: "sqlite3"),
        .executableTarget(
            name: "PA3",
            dependencies: ["CSQLite"],
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
