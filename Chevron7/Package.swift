// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Chevron7",
    platforms: [.macOS("27.0")],
    products: [
        .executable(name: "Chevron7", targets: ["Chevron7App"]),
        .library(name: "Chevron7Kit", targets: ["Chevron7Kit"])
    ],
    dependencies: [
        .package(url: "https://github.com/sparkle-project/Sparkle", exact: "2.10.0")
    ],
    targets: [
        .target(
            name: "Chevron7Identity",
            dependencies: []
        ),
        .target(
            name: "Chevron7WebBridge",
            dependencies: ["Chevron7Identity"]
        ),
        .target(
            name: "Chevron7Kit",
            dependencies: ["Chevron7WebBridge", "Chevron7Identity"]
        ),
        .executableTarget(
            name: "Chevron7App",
            dependencies: [
                "Chevron7Kit",
                "Chevron7Identity",
                .product(name: "Sparkle", package: "Sparkle")
            ]
        ),
        .executableTarget(
            name: "pkcs11-helper",
            dependencies: ["Chevron7Kit"]
        ),
        .executableTarget(
            name: "vision-train",
            dependencies: ["Chevron7Kit"]
        ),
        .executableTarget(
            name: "vision-eval",
            dependencies: ["Chevron7Kit"]
        ),
        .executableTarget(
            name: "avm-probe",
            dependencies: ["Chevron7Kit"]
        ),
        .executableTarget(
            name: "ezzk-probe",
            dependencies: ["Chevron7Kit"]
        ),
        .executableTarget(
            name: "Chevron7WebExtensionHandler",
            dependencies: ["Chevron7WebBridge"]
        ),
        .executableTarget(
            name: "chevron7-webbridge-agent",
            dependencies: ["Chevron7WebBridge", "Chevron7Identity"]
        ),
        .executableTarget(
            name: "webbridge-probe",
            dependencies: ["Chevron7WebBridge"]
        ),
        // Shared by both test targets: the guard that keeps tests out of the user's real data.
        .target(
            name: "Chevron7TestSupport",
            dependencies: ["Chevron7Identity"],
            path: "Tests/Chevron7TestSupport"
        ),
        .testTarget(
            name: "Chevron7KitTests",
            dependencies: ["Chevron7Kit", "Chevron7Identity", "Chevron7WebBridge", "Chevron7TestSupport"]
        ),
        .testTarget(
            name: "Chevron7AppTests",
            dependencies: ["Chevron7App", "Chevron7TestSupport"]
        )
    ]
)
