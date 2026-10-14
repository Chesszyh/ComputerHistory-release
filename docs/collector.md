# 采集、配置和存储

本文描述本项目的实现行为；不把历史样本观察当作其他产品的正式接口契约。

## 模块与数据流

| 模块 | 职责 |
|---|---|
| `FrontmostApplication`、`AXTreeReader`、`InputTap` | 读取前台应用、辅助功能树、键鼠事件 |
| `CollectionSession`、`TextInputTracker` | 编排采样、应用策略、归属文本变化 |
| `UIElementRenderTree`、`UIElementRenderDifference` | 渲染界面树和差分，超预算时回退整树 |
| `SegmentWriter`、`SegmentPruner` | 保存事件、封口元数据、清理旧段 |
| `CollectorProcessLease`、`CollectorSupervisor` | 实例锁、进程身份校验、崩溃重启 |
| `MemoryGenerator`、`NarrativeGenerator` | 生成记忆和时间线叙述；可选调用模型 |

事件类型与编码以 [EventStreamModels.swift](../Sources/ComputerHistoryCore/EventStreamModels.swift) 的 `EventStreamEventKind`、`EventStreamRecord` 和 `EventStreamJSON` 为准。类型可以被解析，不代表采集入口会产生所有事件类型。

## 采集行为与局限

命令行入口每秒采样前台界面和聚焦文本。鼠标与快捷键事件通过系统事件监听取得。当前快捷键记录修饰键，但 `keyEquivalent` 为空；选择变化与提交的核心接口并未全部连接到监听入口。

AX 节点身份使用 `CFHash` 加同哈希出现序号。哈希碰撞或碰撞节点顺序变化可能影响匹配，不能保证跨帧完全稳定。差分预算由 `UIElementRenderDifference.defaultLineBudget` 定义，是本项目参数。

文本来自聚焦元素值的变化，不是逐键重建。含 NUL 的缓冲被排除，但程序化文本更新与用户编辑仍可能难以区分；终端和部分应用可能缺少有效聚焦元素。应用、窗口号、文档地址或控件身份变化会重建基线，窗口标题变化不会。

暂停会丢弃尚未提交的文本缓冲并清除差分基线。恢复后的首次文本采样仅建立基线；界面树仍可能包含暂停期间写入且仍可见的内容。暂停不是内容擦除或历史脱敏功能。

`FrontmostApplication.secureInputState()` 返回未知；本实现未检测安全输入模式。域名规则依赖窗口实际提供的 URL（统一资源定位符），读不到地址时不能据此识别敏感网站或隐私浏览。

## 配置

`<数据目录>/config.json` 缺失时自动创建模板。默认值以 [CollectorConfig.swift](../Sources/ComputerHistoryCore/CollectorConfig.swift) 的初始化器和 [ObservationPolicy.swift](../Sources/ComputerHistoryCore/ObservationPolicy.swift) 的 `conservative` 为准。

| 字段 | 含义 |
|---|---|
| `maxNodesPerSnapshot` | 单帧最大节点数，正整数 |
| `maxLogBytes` | 监督进程日志上限，正整数 |
| `retention.maxTotalBytes` | 可识别段的总量目标；0 禁用容量清理 |
| `retention.maxAgeDays` | 按目录时间戳判断的保留天数；0 禁用年龄清理 |
| `policy.defaultApplicationBehavior` | 应用默认行为：`observe` 或 `do_not_observe` |
| `policy.defaultURLBehavior` | 可识别 URL 的默认行为，取值同上 |
| `policy.allowlist`、`policy.blocklist` | 应用或域名规则，阻止优先 |
| `policy.forcedBlockedDomains` | 最后执行的域名阻止列表 |

规则形如 `{"scope":"app","bundleID":"com.example.Editor"}` 或 `{"scope":"url","urlDomain":"example.com"}`。应用标识精确匹配，域名匹配自身及子域。

缺字段保留默认值；提供非空名单会替换对应默认名单，显式 `"blocklist": []` 会清空默认屏蔽。未知字段、字段类型不符、非法枚举、空规则和带协议或路径的域名规则会被拒绝，并报告字段位置。缺字段兼容不等于容忍错误字段。

文件读取失败、JSON（JavaScript Object Notation）语法损坏、顶层不是对象或字段校验失败时，采集和监督启动失败，保留原文件供修复。配置在启动时读取，不热更新。

`control.json` 保存 `recording`、`summarizing`、`flushRequested`。文件缺失时前两项默认开启；无法读取或解析时暂停两项。记录开关在采样周期读取，总结开关限制新任务排队，已经排队或执行的任务可继续完成。`--no-model` 对监督派生的全部生成任务有效。`--memorize-interval 0` 关闭定时生成，但仍允许手动请求。

## 文件与生命周期

```text
<data-root>/
  config.json
  control.json
  collector.lock
  collector.pid
  collector.log
  segments/<时间戳或时间戳_UUID>/
    events.jsonl
    metadata.json
  memories/*.md
  narrative.json
```

JSONL（逐行 JSON）事件逐条追加。时间段按 UTC（协调世界时）边界对齐；时长由 `SegmentClock.durationSeconds` 定义。轮转在写入新事件时触发，静默期和暂停期间不会仅因时钟到点就封口。事件编号在同一采集会话内连续，重启重新开始。

同一时间窗重启使用新的 UUID（随机唯一标识）目录，避免覆盖旧数据。元数据在封口时写入；崩溃留下的未封口段不会被常规批量记忆生成选中，目前没有自动恢复封口流程。写入失败会记录错误；停止时封口失败使采集器返回 74，监督进程也退出并保留失败结果，不自动重启。`--stop` 只能确认进程已经退出，封口结果需查看日志。存储并非事务日志系统。

`collector.lock` 使用 `flock`（文件独占锁）阻止同目录多个采集器；身份文件记录 PID（进程号）、启动时间和可执行路径。`--stop` 校验身份后发送停止信号。重复采集器返回 73，监督收到该退出码后退出；停止封口失败返回 74，同样结束监督；其他异常退出按重试间隔重新启动。

监督模式支持脱离终端会话运行。macOS 授权结果受签名、启动来源和系统版本影响；重新构建后可能需要重新授权。项目不保证某一种启动来源一定获得权限，也不自动配置采集器登录启动。

## 清理与日志

段清理在启动和事件触发的轮转时执行。保护当前段；独立调用清理器时保护排序最新的一段。不能识别时间戳的目录不删除，也不计入可识别段容量。保护段本身可能超过容量目标。

同窗目录按首条完整事件时间排序，时间相同按目录名定序。缺失、损坏、过大或越界的首行退回段起点；这只提供确定性顺序，不能恢复全部历史创建顺序。

删除失败不会计为成功，也不会扣除其占用。统计不完整时暂停容量清理；能识别的超龄目录仍可能被清理。失败详情写入日志。

监督进程在脱离启动时轮转过大的日志，运行时定期检查并限制日志长度。直接运行 `collect` 没有相同的周期日志上限机制。段保留策略不清理记忆、叙述及其他派生数据，详见[隐私文档](privacy.md)。

## 摘要的含义

十分钟记忆从事件摘要生成，可引用此前记忆；六小时汇总组合相应时段的细粒度记忆；叙述层处理已有记忆。缺少密钥或模型失败时可生成事实版本，后续通常按文件存在跳过；需要重做时显式使用 `--overwrite`。

`verify` 检查能由现存段映射到的十分钟记忆引用，不验证所有数据完整性、模型事实正确性或已经清理的原始段。段内首末事件跨度也不是精确活动时长。
