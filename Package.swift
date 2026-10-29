// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "MiniShot",
    platforms: [.macOS(.v14)],
    targets: [
        // 长截图的对齐与拼接算法，不依赖界面，方便单元测试
        .target(name: "MiniShotCore", path: "Sources/MiniShotCore"),
        .executableTarget(name: "MiniShot", dependencies: ["MiniShotCore"], path: "Sources/MiniShot"),
        .testTarget(name: "MiniShotCoreTests", dependencies: ["MiniShotCore"], path: "Tests/MiniShotCoreTests"),
    ]
)
