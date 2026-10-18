// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "WindowNest",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "WindowNest", targets: ["WindowNest"]),
        .library(name: "WindowNestCore", targets: ["WindowNestCore"]),
    ],
    targets: [
        .target(name: "WindowNestCore"),
        .executableTarget(name: "WindowNest", dependencies: ["WindowNestCore"]),
        .testTarget(name: "WindowNestCoreTests", dependencies: ["WindowNestCore"]),
    ]
)
