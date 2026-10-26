# 开发与测试

使用 macOS 和 Swift 6。核心逻辑位于 `Sources/ComputerHistoryCore`；命令行和菜单栏是独立可执行目标。Swift Package Manager 清单见 `Package.swift`。

```bash
swift test
bash scripts/build.sh -c release
python3 scripts/test-process-control.py .build/debug/computer-history
python3 scripts/test-process-control.py .build/release/computer-history
```

进程测试须以普通用户运行，权限拒绝场景不支持 root。测试拥有自己的临时目录和子进程，不应修改真实运行服务。常规测试不访问个人历史；只有显式设置 `COMPUTER_HISTORY_SAMPLES` 才启用三项私有样本兼容性测试，其断言针对维护者的数据集，不适用于任意小样本。

修复生命周期问题时增加跨状态回归：暂停和恢复、应用切换、同窗重启、配置不完整、删除失败与进程身份变化。纯渲染和解析改动使用合成输入即可。模型相关测试应使用本地模拟接口，不能依赖真实密钥或产生付费请求。

文档只描述可由实现和测试支撑的行为；权限与应用兼容性请注明验证环境。注释说明非显然的原因，提交说明最终行为。不要提交真实活动数据、凭据、构建产物或个人机器配置。

提交变更时附问题复现、最终行为与实际执行的验证。涉及公开 API 或配置行为变化时同步更新相关文档。

`scripts/build.sh` 构建后会在本机存在 `local-codesign` 时使用持久签名身份签署 CLI 和菜单栏；没有本机签名工具的环境保留 Swift 的默认签名。运行签名工具前应完成其本机证书初始化。正式发布的签名身份与公证沿用发布环境配置。

## 文本证据与菜单性能验证

模型取材、逐次用量、缓存计费、失败与空输出、预算拦截及分批续跑使用本地模拟服务验证：

```bash
python3 scripts/test-text-summary.py .build/debug/computer-history
python3 scripts/test-text-summary.py .build/release/computer-history
python3 scripts/test-narrative-activities.py .build/debug/computer-history
python3 scripts/test-narrative-activities.py .build/release/computer-history
python3 scripts/test-reports.py .build/debug/computer-history
python3 scripts/test-reports.py .build/release/computer-history
python3 scripts/test-model-fallback.py .build/debug/computer-history
python3 scripts/test-model-fallback.py .build/release/computer-history
python3 scripts/test-scheduling.py .build/debug/computer-history
python3 scripts/test-scheduling.py .build/release/computer-history
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

历史列表的自动分页可在 macOS 图形会话中用真实 SwiftUI 和滚动控件验证。此测试创建临时合成时间线和独立的可见测试窗口，断言首屏及连续触底加载，不启动采集或调用模型：

```bash
bash scripts/test-menubar-panel.sh
bash scripts/test-menubar-panel.sh scripts/test-menubar-usage.swift
bash scripts/test-menubar-panel.sh scripts/test-menubar-settings.swift
bash scripts/test-menubar-panel.sh scripts/test-collector-input.swift
```

模型列表与服务端推理强度元数据使用本地模型列表接口验证，不调用生成接口或读取真实密钥：

```bash
python3 scripts/test-menubar-catalog.py
```

用量与设置面板用例使用临时合成记录，验证分组及请求详情标题整行点击、详情返回后的展开与滚动位置、提示词保存和恢复默认，以及原生模型／采集表单的编辑、保存和校验、总结删除与回收站恢复；不启动真实采集器、写入密钥或访问模型服务。

`test-collector-input.swift` 在独立合成窗口验证系统键鼠监听、鼠标目标与键盘焦点不同的点击、组合点击、Shift 字符和 Command 快捷键。需测试程序的辅助功能权限；缺少权限退出 77，计为跳过。测试结束恢复前台应用与鼠标位置。

## CI 与版本发布

Agent Skill 查询测试只使用临时合成历史，覆盖摘要、时间线、报告、压缩事件、过滤与只读边界，不需要 Swift 构建或外部服务：

```bash
python3 scripts/test-agent-skill.py
```

CI 在 `main`、`master` 推送与合并请求及手动触发时运行：私有开发使用 `master`，公开产品使用 `main`。Debug、Release 和原生菜单检查在独立的 Apple Silicon macOS 任务中并行执行；每个配置中的集成测试并发运行，日志分别保留为 CI 附件。私有样本与大数据基准保持显式启用，不属于常规 CI。

本机可使用相同的并发集成入口，`--jobs 1` 可用于逐项排障：

```bash
python3 scripts/test-integration.py .build/release/computer-history --logs .build/integration-release
python3 scripts/test-build-tools.py
python3 scripts/test-install.py
```

原生菜单测试共用 `scripts/build-menubar-tests.py` 构建的程序，按编译器、源码、核心模块及对象文件内容复用；输入变化时重新编译。各用例在独立进程中顺序运行，避免剪贴板和原生窗口状态互相影响。CI 手动触发的 `native_case` 可只检查一个面板；这种局部检查不能用于发布。

发布前更新 `VERSION` 与双语 CHANGELOG，等待相应提交的完整 CI 通过。Release 任务直接打包已测试的程序，不再重新构建。正式发布任务仅在公开仓库的 `main` 上执行；私有仓库或其他分支手动触发会跳过任务。随后在公开仓库手动运行 **Publish verified release** 工作流，填写该次完整 CI 的 `run_id`；工作流检出受测提交，验证同次 CI 的 Apple Silicon 压缩包，创建注释标签和 GitHub Release。此入口不重新运行构建或测试。普通推送只运行 CI，不创建 Release。用户下载和启动说明由 `docs/distribution.md` 维护。

也可从公开仓库检出的受测提交执行本机检查；加上 `--publish` 才会创建标签和 Release：

```bash
python3 scripts/publish-release.py --run-id <完整CI编号> --output .build/release-publication
```

发布入口核对仓库、提交、三个完整 CI 任务、包内文件、架构、系统依赖、最低系统版本、签名和命令行启动；已存在的 Release 不覆盖。私有源码到公开仓库的允许清单导出仍在私有工作区完成，公开工作流不读取私有开发仓库。

报告面板交互使用独立合成材料，检查复制、TXT 导出、备份开关与返回，不访问模型或 GitHub；测试结束恢复剪贴板：

```bash
bash scripts/test-menubar-panel.sh scripts/test-menubar-reports.swift
```

`test-reports.py` 使用本地模拟模型和临时 Git 远端，验证日报／周报、分批续跑、失败保留、导出范围及私有备份的启停、失败和远端提交确认。

`test-model-fallback.py` 使用本地模拟接口验证按次降级、独立鉴权、超时和失败提示状态；`test-scheduling.py` 验证新段不等待定时周期，且日报请求阻塞时实时总结仍能完成。合成测试通过 `COMPUTER_HISTORY_NOTIFICATIONS=0` 禁用真实系统通知。

辅助功能连接与正文识别的单元回归包含应用重启、启动尚未完成、工具栏误判和 OCR 开关。可在图形会话中额外启动独立 Chrome 配置及合成网页，连续重启两次验证正文，不关闭现有浏览器实例：

```bash
bash scripts/test-menubar-panel.sh scripts/test-accessibility-relaunch.swift --chrome-executable "/Applications/Google Chrome.app/Contents/MacOS/Google Chrome"
```

该测试需要为测试程序提供辅助功能权限，不开启真实采集或调用模型。ActivityWatch 常规测试使用模拟接口，验证本机数据桶选择、过期数据、取消请求、屏蔽规则、区间去重和总结来源标注，不访问正在运行的 ActivityWatch 服务。

`test-narrative-activities.py` 使用合成多任务记忆和本地模拟模型，检查共享来源的活动拆分、主任务与步骤归组、穿插归属与续接、原文保留、失败不覆盖、来源修订及固定十分钟模式。

`TimelineLayoutTests` 使用同刻、零长度、包含、相交链、相接区间及固定种子的随机区间验证时间点唯一、严格顺序、不重叠和活动完整归属；`InteractionEvidenceTests` 验证动态界面与不确定控件变化不被当作明确交互，不依赖个人项目名或私有历史。

原生面板回归同时检查未变化的刷新不重复发布内容版本、模型健康和备份状态；对照逐次创建与复用日期格式化器的输出，并打印同一组合成时间的耗时。耗时只用于定位该操作的成本，不作为整机 CPU 或长期稳定性的保证。

`VERSION` 可使用三段版本，或带 `-alpha.N`、`-beta.N`、`-rc.N` 的候选版本。发布入口根据版本自动设置预发布，候选版不会标为最新正式版。已有本机运行实例时，测试使用独立的 `--scratch-path .build/verification`，避免测试构建替换运行程序；对应程序位置可用同一 scratch 路径的 `swift build --show-bin-path` 查询。
