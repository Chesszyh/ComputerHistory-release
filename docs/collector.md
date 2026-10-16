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

命令行入口每秒采样前台界面和聚焦文本。鼠标与快捷键事件通过系统事件监听取得。快捷键记录修饰键与物理键位名称，Return/Enter 记录为按键事件；它不直接表示消息发送或文档保存成功。选择变化尚未完整连接到监听入口。

AX 节点身份使用 `CFHash` 加同哈希出现序号。哈希碰撞或碰撞节点顺序变化可能影响匹配，不能保证跨帧完全稳定。新采集的差分省略未变化的节点文本；应用、窗口、文档地址、暂停恢复和段边界会建立完整基线。界面内容变化只写入对应的窗口事件，点击与快捷键不重复携带同一帧。差分预算由 `UIElementRenderDifference.defaultLineBudget` 定义。

文本来自聚焦编辑控件的值变化，不是逐键重建。跟踪器按完整 Unicode 字符维护新增编辑区域；落盘前的删除、纠错和替换会更新该区域，不同位置的独立编辑分别保存。含 NUL 的缓冲和明确非编辑控件被排除；终端和部分应用可能缺少有效聚焦元素。应用、窗口号、文档地址或控件身份变化会重建基线，窗口标题变化不会。

键鼠监听只提供附近发生交互的时间信号，不保存普通按键的原始键码。`keyboard.textEvidence` 的 `edited_value` 表示控件变化附近有编辑活动，`uncertain_value_change` 表示无法归因；两者都不证明文本已发送，前者也不证明逐字键入或输入法组合已完成。旧记录缺字段时按未知解读。明确 placeholder 不作为输入；真正编辑了相同短句时仍保留。应用把提示塞进 value、又缺少可区分属性时，只能降低归因强度。

当前公开 AX 读取没有提供通用的输入法组合状态，保持未知。轮询之间出现又消失的文字可能遗漏；已经落盘的拼音不会被原地改写。后续编辑覆盖了已记录区域时，`keyboard.textReplaces` 保存被覆盖事件的 `段ID#事件ID` 来源，派生摘要会标明旧片段已被部分或全部替换。

暂停会丢弃尚未提交的文本缓冲并清除差分基线。恢复后的首次文本采样仅建立基线；界面树仍可能包含暂停期间写入且仍可见的内容。暂停不是内容擦除或历史脱敏功能。

前台应用为系统登录界面（`com.apple.loginwindow`）时，采集器封口此前的事件段，停止读取界面、聚焦文本和记录键鼠操作。前台重新出现其他应用后恢复采集并建立新基线。离开起止时间保存在数据目录的 `away.json`，满一分钟的时段在时间线合并为一条“离开电脑”，更短的切换不单列条目，不为离开时段调用模型；前台应用暂时不可用时不会据此判定已经返回。此规则基于登录界面的应用身份，不以普通窗口的标题或无操作时长判断离开。

`FrontmostApplication.secureInputState()` 返回未知；本实现未检测安全输入模式。域名规则依赖窗口实际提供的 URL（统一资源定位符），读不到地址时不能据此识别敏感网站或隐私浏览。

## 配置

`<数据目录>/config.json` 缺失时自动创建模板。默认值以 [CollectorConfig.swift](../Sources/ComputerHistoryCore/CollectorConfig.swift) 的初始化器和 [ObservationPolicy.swift](../Sources/ComputerHistoryCore/ObservationPolicy.swift) 的 `conservative` 为准。

| 字段 | 含义 |
|---|---|
| `maxNodesPerSnapshot` | 单帧最大节点数，正整数 |
| `maxLogBytes` | 监督进程日志上限，正整数 |
| `retention.maxTotalBytes` | 可识别段的总量目标；0 禁用容量清理 |
| `retention.maxAgeDays` | 按目录时间戳判断的保留天数；0 禁用年龄清理 |
| `retention.unsummarizedMaxAgeDays` | 未生成记忆或模型失败的段允许延长保留的天数；仍受容量目标约束 |
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
  model.json             # 可选模型设置，不含密钥
  requests/*.json        # 逐次请求、用量和单价快照
  collector.lock
  collector.pid
  collector.log
  segments/<时间戳或时间戳_UUID>/
    events.jsonl         # 活动段
    events.jsonl.gz      # 已归档段，与上者择一读取
    metadata.json
  memories/*.md
  narrative.json
```

JSONL（逐行 JSON）事件逐条追加。时间段按 UTC（协调世界时）边界对齐；时长由 `SegmentClock.durationSeconds` 定义。轮转在写入新事件时触发，静默期和暂停期间不会仅因时钟到点就封口。事件编号在同一采集会话内连续，重启重新开始。

同一时间窗重启使用新的 UUID（随机唯一标识）目录，避免覆盖旧数据。元数据在封口时写入；新版本额外保存首条事件时间用于排序。采集启动持有实例锁后，为旧的未封口段补写恢复元数据，不改写原始事件；无法解码的半行不计入恢复事件数，恢复错误写入日志。写入失败会记录错误；停止时封口失败使采集器返回 74，监督进程也退出并保留失败结果，不自动重启。`--stop` 只能确认进程已经退出，封口结果需查看日志。存储并非事务日志系统。

`collector.lock` 使用 `flock`（文件独占锁）阻止同目录多个采集器；身份文件记录 PID（进程号）、启动时间和可执行路径。`--stop` 校验身份后发送停止信号。重复采集器返回 73，监督收到该退出码后退出；停止封口失败返回 74，同样结束监督；其他异常退出按重试间隔重新启动。

监督模式支持脱离终端会话运行。macOS 授权结果受签名、启动来源和系统版本影响；重新构建后可能需要重新授权。项目不保证某一种启动来源一定获得权限，也不自动配置采集器登录启动。

## 清理与日志

`memorize` 在生成前用系统 gzip 流式压缩已封口段，成功写出归档后才删除未压缩原文。采集器不在采样线程压缩。生成、排序和统计同时支持已有 JSONL 与压缩段；读取位置以实际目录为准。

段清理在启动和事件触发的轮转时执行。保护当前段；独立调用清理器时保护排序最新的一段。不能识别时间戳的目录不删除，也不计入可识别段容量。保护段本身可能超过容量目标。

同窗目录按首条完整事件时间排序，时间相同按目录名定序。缺失、损坏、过大或越界的首行退回段起点；这只提供确定性顺序，不能恢复全部历史创建顺序。

年龄清理对未总结或模型失败段使用延长保留时间；容量不足时先淘汰已有可用记忆的段，再淘汰其余旧段，并记录未完成总结的淘汰数量。记忆的 `generation` 字段区分 `model`、`factual` 和 `failed`；旧记忆仍可读取。

删除失败不会计为成功，也不会扣除其占用。统计不完整时暂停容量清理；能识别的超龄目录仍可能被清理。失败详情写入日志。

监督进程在脱离启动时轮转过大的日志，运行时定期检查并限制日志长度。直接运行 `collect` 没有相同的周期日志上限机制。段保留策略不清理记忆、叙述及其他派生数据，详见[隐私文档](privacy.md)。

## 摘要的含义

十分钟记忆结合编辑片段、控件变化、按时间排列的界面内容、点击目标和快捷键取材，按任务归并跨应用操作。每份记忆保留有界的时序证据及事件引用；编辑归属只约束对应片段，不扩展为整段免责声明。摘要直接描述材料支持的动作和结果，没有结果材料时省略，不强行生成结束状态。

六小时汇总使用十分钟记忆中的活动正文。叙述层每批最多整理四份记忆，每批落盘后再继续；一次请求失败不撤销已完成批次，增量续跑只处理尚未覆盖的来源。模型输出仍是派生内容。缺少模型时可生成事实版本；模型失败或输出截断会标记失败，后续周期重试。显式 `--overwrite` 可重做已有记忆。

`verify` 检查能由现存段映射到的十分钟记忆引用，不验证所有数据完整性、模型事实正确性或已经清理的原始段。段内首末事件跨度也不是精确活动时长。

## 菜单栏读取

菜单栏在串行后台加载器中读取统计和时间线。已封口段优先使用 `metadata.json` 的事件计数；缺少或无法解析时流式计行并缓存，未封口段只计新增字节，包含尚未以换行结束的非空尾行。截断、替换和删除会使相应计数更新；无法完整读取时界面标注统计下界。

记忆索引按文件大小、修改时间和文件身份复用解析结果；列表快照只持有展示字段，详情按需后台读取。刷新请求会合并，文件读取与跨进程窗口查询不在主线程执行。菜单栏也支持 `--out <目录>`，独立目录使用独立实例锁；默认目录与 CLI 相同。


## 模型与用量配置

生成任务每次启动时读取数据目录中的 `model.json`。文件存在时优先使用其中设置；不存在时使用 README 中的 DeepSeek 环境变量。错误配置不会切换到其他模型服务。

Ollama 服务示例；跨机器使用时将地址改为模型机器的可达地址，模型名须与服务端创建的名称一致：

```json
{
  "baseURL": "http://127.0.0.1:11434/v1",
  "model": "computer-history-qwen3.5-4b",
  "requiresAPIKey": false,
  "reasoningEffort": "none",
  "pricing": {
    "currency": "CNY",
    "inputPerMillion": 0,
    "cachedInputPerMillion": 0,
    "outputPerMillion": 0
  }
}
```

在 Ollama 模型机器上用以下 Modelfile 创建指定上下文的模型，然后执行 `ollama create computer-history-qwen3.5-4b -f Modelfile`：

```text
FROM qwen3.5:4b
PARAMETER num_ctx 16384
PARAMETER num_predict 2400
```

可选 `comparison` 将同一份输入并行发送到另一个无密钥模型服务，仅记录对照请求，不参与正式记忆和时间线。其字段为 `baseURL`、`model`、`reasoningEffort`、`pricing`，含义与主服务相同。对照请求的 `comparisonOf` 指向正式请求标识，在用量面板中标为“对照”；即使对照请求失败，正式结果仍正常写出。CLI 会在退出前等待对照请求结束，避免进程退出丢失结果。

`requiresAPIKey: true` 从 `DEEPSEEK_API_KEY` 读取密钥；密钥不写入配置和请求记录。`reasoningEffort` 默认为本项目约定的非思考请求值 `none`，配置中需显式提供。服务需支持 `/chat/completions`、文本消息和该模型的思考参数。

`pricing` 可省略，此时显示费用未知。单价单位为每百万 token，按输入未缓存、输入缓存命中和输出分别计算；思考 token 是输出的子集，不重复计费。零单价表示模型 API 费用为零，不包含设备运行成本。单价由使用者按服务账户配置；记录保存请求时的单价，调整后不会追溯改变旧请求。面板显示估算费用，服务商折扣、时段价格和账单以实际账户为准。

可选的 `dailyBudget`、`monthlyBudget` 与 `pricing.currency` 同币种；已记录的估算费用达到预算后不再发起新请求。已有请求会执行完毕，用量未知的请求无法计入该估算。

每次请求在外发前先保存 `requests/<随机标识>.json`，返回后补写状态、耗时、正文和服务端用量；文件写入失败时不会继续发起未登记的请求。超时或错误未返回用量时保留未知值。请求状态为“已返回”仅表示接口返回正文；具体生成是否可用还由记忆与叙述解析判断。请求正文和元数据保存在同一文件，菜单栏仅缓存列表字段，详情按需读取。
