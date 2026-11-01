// swift-tools-version:5.10
import PackageDescription

let package = Package(
    name: "MagGlow",
    platforms: [.macOS(.v14)],
    targets: [
        .target(name: "CSMC", linkerSettings: [.linkedFramework("IOKit")]),
        .target(name: "MagGlowShared"),
        .executableTarget(
            name: "MagGlowHelper",
            dependencies: ["CSMC", "MagGlowShared"],
            linkerSettings: [.linkedFramework("IOKit")]
        ),
        .executableTarget(
            name: "MagGlow",
            dependencies: ["MagGlowShared"],
            linkerSettings: [.linkedFramework("IOKit")]
        ),
    ]
)
