# 开发与测试

使用 macOS 和 Swift 6。核心逻辑位于 `Sources/ComputerHistoryCore`；命令行和菜单栏是独立可执行目标。Swift Package Manager 清单见 `Package.swift`。

```bash
swift test
swift build -c release
python3 scripts/test-process-control.py .build/debug/computer-history
python3 scripts/test-process-control.py .build/release/computer-history
```

进程测试须以普通用户运行，权限拒绝场景不支持 root。测试拥有自己的临时目录和子进程，不应修改真实运行服务。常规测试不访问个人历史；只有显式设置 `COMPUTER_HISTORY_SAMPLES` 才启用三项私有样本兼容性测试，其断言针对维护者的数据集，不适用于任意小样本。

修复生命周期问题时增加跨状态回归：暂停和恢复、应用切换、同窗重启、配置不完整、删除失败与进程身份变化。纯渲染和解析改动使用合成输入即可。模型相关测试应使用本地模拟接口，不能依赖真实密钥或产生付费请求。

文档只描述可由实现和测试支撑的行为；权限与应用兼容性请注明验证环境。注释说明非显然的原因，提交说明最终行为。不要提交真实活动数据、凭据、构建产物或个人机器配置。

提交变更时附问题复现、最终行为与实际执行的验证。涉及公开 API 或配置行为变化时同步更新相关文档。

## 文本证据与菜单性能验证

模型取材、逐次用量、缓存计费、失败与空输出、预算拦截及分批续跑使用本地模拟服务验证：

```bash
python3 scripts/test-text-summary.py .build/debug/computer-history
python3 scripts/test-text-summary.py .build/release/computer-history
```

大数据基准为显式入口，创建并回收约 1.5 GiB 的合成事件；比较完整状态读取与托盘首次、重复加载的耗时，并断言事件读取字节和记忆解析次数。

```bash
COMPUTER_HISTORY_TRAY_BENCHMARK=1 swift test -c release --filter TraySnapshotLoaderTests.testLargeHistoryBenchmark
```

交互验收可用独立合成目录，`--out` 指定的目录必须尚不存在：

```bash
python3 scripts/make-tray-fixture.py --out /tmp/computer-history-tray-fixture --large
.build/release/computer-history-menubar --out /tmp/computer-history-tray-fixture
```

不带 `--large` 生成小数据组。对同一数据重复打开/收起、滚动、展开概要与详情，跨越多个刷新周期；将响应耗时、堆对象数、物理内存峰值和稳态分别记录。一次 `leaks` 或 RSS 读数不能证明长期无泄漏。关闭测试实例后可删除其合成目录。

历史列表的自动分页可在 macOS 图形会话中用真实 SwiftUI 和滚动控件验证。此测试创建临时合成时间线和不显示的窗口，断言首屏及连续触底加载，不启动采集或调用模型：

```bash
bash scripts/test-menubar-panel.sh
bash scripts/test-menubar-panel.sh scripts/test-menubar-usage.swift
bash scripts/test-menubar-panel.sh scripts/test-menubar-settings.swift
```

用量与设置面板用例使用临时合成记录，验证分组及请求详情标题整行点击、详情返回后的展开与滚动位置、提示词保存和恢复默认，以及原生模型／采集表单的编辑、保存和校验；不启动真实采集器、写入密钥或访问模型服务。

## CI 与版本发布

公开仓库的 CI 在 `main` 推送、合并请求和手动触发时运行，使用 Apple Silicon macOS 执行 Debug／Release 单元测试、进程集成、模拟模型和菜单测试。私有样本与大数据基准保持显式启用，不属于常规 CI。

发布前更新 `VERSION`，等待相应提交的 CI 任务通过。CI 附件包含 `scripts/package-release.sh` 从公开源码构建的 Apple Silicon 压缩包。将版本标签指向该提交，创建 Release 并上传同一次 CI 的压缩包；用户下载和启动说明由 `docs/distribution.md` 维护。
