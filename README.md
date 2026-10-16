# ComputerHistory

macOS 本地活动记录工具。通过 Accessibility（辅助功能，简称 AX）读取前台应用的界面文本，记录窗口变化、点击、快捷键和可归因的文本变化，按时间段保存。支持 DeepSeek 和兼容接口的自托管模型生成记忆摘要，并在菜单栏查看时间线、逐次请求和费用。

本项目为独立实现，与 OpenAI、ChatGPT 或 DeepSeek 无隶属关系，不承诺与其他产品完整兼容。

## 使用前了解

- 普通文本框、窗口标题、页面内容和访问地址可能以明文保存。默认屏蔽名单不能保证排除所有敏感内容。
- `collect` 不调用模型；`memorize`、`narrative` 以及 `supervise` 的生成任务会向已配置的模型服务发送活动内容。`--no-model` 可禁止模型请求。
- 暂停记录只阻止新的采集；恢复后当前界面仍可能被完整读取。已有记录不会因暂停而删除。

详见 [隐私与安全边界](docs/privacy.md)。

## 构建和验证

预编译程序及启动方法见[下载与运行](docs/distribution.md)；源码验证结果见 [CI](https://github.com/Chesszyh/ComputerHistory-release/actions/workflows/ci.yml)。

需要 macOS 13 或更高版本、Swift 6 工具链。进程集成测试和菜单栏启动脚本另需 Python 3。Swift 包不依赖第三方包。

在源码目录执行：

```bash
swift build -c release
swift test
python3 scripts/test-process-control.py .build/release/computer-history
```

常规测试使用合成数据，不需要模型密钥。三项私有兼容性样本测试默认跳过；集成测试使用临时目录、暂停真实桌面采集，并以本地模拟接口验证不联网的生成路径。

## 开始记录

先检查权限，再进行一次短时采集。检查命令仅报告辅助功能状态，不代表输入监控、所有应用读取或事件监听已验证成功。

```bash
./.build/release/computer-history --check
./.build/release/computer-history collect --seconds 15
./.build/release/computer-history --status
```

在“系统设置 → 隐私与安全性”中检查辅助功能和输入监控权限；具体需授权的程序受启动方式及系统权限归属影响。查看数据目录中的 `collector.log` 确认是否存在读取或监听错误。

默认数据目录为 `~/.computer-history`。CLI（命令行接口）支持 `--out <目录>`；同一实例的启动、状态、停止及生成命令应使用同一个目录。

```bash
# 后台采集并定期生成本地事实摘要，禁止模型请求
./.build/release/computer-history supervise --daemon --no-model

# 请求停止采集器；监督进程在检测到正常停止后退出
./.build/release/computer-history --stop

# 启动菜单栏界面，读取默认数据目录
./scripts/menubar.sh
```

菜单栏的登录启动设置只登记菜单栏程序，不负责启动采集器。可用 `./scripts/menubar.sh --stop` 停止身份可验证的菜单栏实例；旧版未登记身份的实例需从界面退出后再启动新版。修改 `config.json` 后需停止并重新启动采集；菜单栏运行开关则由进程定期读取。

## 记忆与时间线

历史活动滚动到底部时自动加载更早记录。系统登录界面期间停止内容采集，返回后将这段时间展示为一条“离开电脑”；具体判定和存储见[采集行为](docs/collector.md#采集行为与局限)。

```bash
# 不联网：为已封口的段生成事实摘要
./.build/release/computer-history memorize --no-model --limit 6

# 不联网：生成已结束的六小时时段汇总
./.build/release/computer-history memorize --no-model --granularity 6h

# 检查已有十分钟记忆的自引用、未来引用和成环
./.build/release/computer-history verify
```

模型接入使用 `DEEPSEEK_API_KEY`，可用 `DEEPSEEK_MODEL` 与 `DEEPSEEK_BASE_URL` 覆盖模型和地址。默认值见 [DeepSeekClient.swift](Sources/ComputerHistoryCore/DeepSeekClient.swift) 的 `defaultModel` / `defaultBaseURL`；请按服务账户的实际可用模型设置。

自托管模型在数据目录创建 `model.json`，格式见[模型与用量配置](docs/collector.md#模型与用量配置)。可将模型部署在另一台电脑，本机只发送整理后的材料。配置文件优先于模型环境变量；`requiresAPIKey: false` 的服务不接收 DeepSeek 密钥。

不带 `--no-model` 的生成任务会发送活动材料；`supervise` 定期执行生成入口。模型失败时保留带失败标记的事实摘要，后续周期会重试。菜单栏的“总结用量与费用”可查看每次请求的实际输入、输出、token 用量和费用估算。可用 `comparison` 将同一输入并行交给第二个模型；正式时间线只使用主模型结果，对照结果在请求详情中查看。旧版本没有保存的用量不会补算。

用量页支持今天、昨天、本周（周一起）和本月筛选，并可选择任务类型及正式／对照请求。合计随筛选范围变化，请求按日期和任务分组展开。详情先显示模型输出，原始来源、系统提示词和原始输入默认折叠。

## 文档

- [采集、配置和存储](docs/collector.md)
- [隐私、外发和数据删除边界](docs/privacy.md)
- [开发与测试](CONTRIBUTING.md)
- [安全问题反馈](SECURITY.md)
- [来源与第三方内容](docs/provenance.md)

## 许可证

本项目使用 [MIT License](LICENSE)。
