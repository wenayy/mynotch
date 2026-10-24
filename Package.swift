// swift-tools-version: 5.10
import PackageDescription

let package = Package(
    name: "MyNotch",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(
            name: "MyNotch",
            path: "Sources/MyNotch",
            linkerSettings: [
                .linkedFramework("IOKit"),
                .linkedFramework("Carbon"),
                .linkedFramework("CoreAudio"),
                .linkedFramework("EventKit"),
                .linkedFramework("AVFoundation"),
                .linkedFramework("QuickLookThumbnailing"),
                .linkedFramework("ServiceManagement"),
                .linkedFramework("CoreLocation"),
            ]
        )
    ]
)
