// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "TVRemote",
    platforms: [
        .macOS("26.0")
    ],
    products: [
        .executable(name: "TVRemote", targets: ["TVRemote"])
    ],
    targets: [
        .executableTarget(
            name: "TVRemote",
            path: "src/TVRemote",
            exclude: [
                "Info.plist",
                "TVRemote.entitlements"
            ],
            linkerSettings: [
                .linkedFramework("AppKit"),
                .linkedFramework("SwiftUI"),
                .linkedFramework("Security"),
                .linkedFramework("ServiceManagement"),
                .linkedFramework("Network"),
                .linkedFramework("Carbon")
            ]
        )
    ]
)
