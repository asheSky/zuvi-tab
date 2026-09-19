// swift-tools-version:5.10
import PackageDescription

let package = Package(
    name: "ZuviTab",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(
            name: "ZuviTab",
            path: "Sources/ZuviTab",
            linkerSettings: [
                .linkedFramework("Carbon"),
                .linkedFramework("ScreenCaptureKit"),
                .linkedFramework("ServiceManagement"),
            ]
        )
    ]
)
