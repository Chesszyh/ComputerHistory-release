// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "ComputerHistory",
    platforms: [.macOS(.v13)],
    targets: [
        // 采集层：Accessibility 树差分、输入事件、segment 落盘。
        // 拆成 library + 可执行文件，便于对编解码与差分逻辑做单元测试。
        .target(name: "ComputerHistoryCore"),
        .executableTarget(name: "computer-history", dependencies: ["ComputerHistoryCore"]),
        // 托盘应用：展示活动时间线、当前状态与运行状态。
        .executableTarget(name: "computer-history-menubar",
                          dependencies: ["ComputerHistoryCore"]),
        .testTarget(
            name: "ComputerHistoryCoreTests",
            dependencies: ["ComputerHistoryCore"],
            resources: [.process("Fixtures")]
        ),
    ]
)
