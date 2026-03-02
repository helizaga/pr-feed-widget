// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "PRAgentUI",
    platforms: [
        .macOS(.v14)
    ],
    dependencies: [
        .package(url: "https://github.com/jpsim/Yams.git", from: "5.0.0")
    ],
    targets: [
        .executableTarget(
            name: "PRAgentUI",
            dependencies: ["Yams"],
            path: "Sources/PRAgentUI"
        )
    ]
)
