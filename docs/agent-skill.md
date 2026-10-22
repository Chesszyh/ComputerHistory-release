# 在 Coding Agent 中查询活动历史

`skills/computerhistory-recall` 是可单独分发的 [Agent Skill（代理技能）](https://agentskills.io/specification)：`SKILL.md` 提供按需检索流程，`scripts/query_history.py` 负责确定性的本地只读查询。安装后，可在其他项目中问“我昨天主要做了什么”“之前为什么修改这个文件”“上次处理 Bug 到哪里了”，由当前 Agent 转换条件、检索并结合证据回答。

需要 Python 3.9 或更高版本、系统时区数据库和已有的 ComputerHistory 数据；不需要 pip 包、模型密钥、MCP Server（模型上下文协议服务）、向量数据库或常驻服务。

## 安装

分发时保留整个 `computerhistory-recall/` 目录及其内部相对路径。仓库中的 `skills/` 是分发位置，各客户端的发现目录可能不同。

### 从本地检出安装

以下命令供使用者自行执行。在 ComputerHistory 源码根目录运行，支持 `gh skill` 的 GitHub CLI 会复制 Skill 和脚本：

```bash
# Codex：用户范围，可用于任意项目
gh skill install . computerhistory-recall --from-local --agent codex --scope user

# Antigravity App：使用官方文档中的全局发现位置
gh skill install . computerhistory-recall --from-local --dir "$HOME/.gemini/config/skills"

# Gemini CLI：用户范围
gh skill install . computerhistory-recall --from-local --agent gemini-cli --scope user
```

安装参数见 [GitHub CLI 手册](https://cli.github.com/manual/gh_skill_install)。先用 `gh skill install --help` 确认当前版本支持；没有该子命令时，可将整个目录复制到客户端官方文档指定的 Skill 目录。

| 客户端 | 项目发现目录 | 用户发现目录／安装方式 | 官方说明 |
|---|---|---|---|
| Codex | `.agents/skills/` | `~/.agents/skills/`，也支持链接目录 | [Build skills](https://developers.openai.com/codex/skills/) |
| Antigravity App | `.agents/skills/` | `~/.gemini/config/skills/` | [App skill locations](https://www.antigravity.google/docs/skills#antigravity-app-skill-locations) |
| Gemini CLI | `.agents/skills/`、`.gemini/skills/` | `gh` 安装或 `gemini skills link /绝对路径/skills/computerhistory-recall --scope user` | [Agent Skills](https://geminicli.com/docs/cli/skills/) |

安装后查看客户端的 Skill 列表；如未刷新，重新加载或重启客户端。以上路径和命令依据官方文档核对，客户端版本、文件访问权限和脚本执行权限仍须在实际环境检查。Antigravity App 与其 CLI 是不同客户端，不应混用全局路径。此仓库不执行安装，也不修改用户的全局或私有 Skill 目录。

DSH 的 Skill 发现路径和安装接口尚未确认，因此不宣称已验证兼容。若 DSH 或其他客户端支持开放规范的 `SKILL.md`、附带脚本与本地 Python 执行，可按其文档安装相同目录；也可直接运行下文脚本，将必要结果交给 Agent。查询 `--app DSH` 只表示过滤已记录的 DSH 活动，不证明 DSH 客户端支持 Skill。

### 从公开仓库安装

当相应提交已同步到公开仓库后，可执行：

```bash
gh skill install Chesszyh/ComputerHistory-release skills/computerhistory-recall \
  --pin main --agent codex --scope user
```

`--pin main` 选择默认分支上的源码；不指定时 `gh` 优先选择最新标签，该标签可能早于 Skill。需要固定版本时，将 `main` 换成包含 Skill 的公开提交 SHA（提交标识）。Antigravity App 可将末尾安装选项换成 `--dir "$HOME/.gemini/config/skills"`；Gemini CLI 可换成 `--agent gemini-cli --scope user`。安装行为与发现路径以上述官方文档为准。

## 查询

以下在源码根目录执行；安装后用已安装 Skill 中脚本的绝对路径。默认读取 `~/.computer-history`，自定义采集器 `--out` 的用户应在每次查询中使用对应的 `--root`。

```bash
# 某个自然日的摘要与时间线
python3 skills/computerhistory-recall/scripts/query_history.py \
  --from 2026-10-20 --to 2026-10-20 --timezone Asia/Shanghai --format json

# 文件名或技术词；重复关键词取“或”，应用条件再取交集
python3 skills/computerhistory-recall/scripts/query_history.py \
  --root '/path/to/history' --query 'Example.swift' --query '光标 Bug' --app Codex

# 摘要不足时，按日期和关键词查原始证据
python3 skills/computerhistory-recall/scripts/query_history.py \
  --source events --from 2026-10-12 --to 2026-10-18 \
  --timezone Asia/Shanghai --query '同步方案' --limit 8 --format json

python3 skills/computerhistory-recall/scripts/query_history.py --help
```

每个 `--query` 是完整的、不区分大小写的字面子串，不分词、不做语义搜索。重复关键词去重后取“或”，按命中词数量降序、活动时间降序排列；日期及应用过滤取交集。无关键词时按活动时间由新到旧。默认返回 8 条，`--limit` 允许 1–50；片段最多 480 个 Unicode 码点，标题及应用等展示字段也有长度限制，来源记忆最多展示 8 个并保留总数。

`--from`、`--to` 都包含边界，按查询时区的自然日筛选；缺省为运行机器的本地时区，可用 `--timezone` 指定 IANA（互联网号码分配机构）时区名。事件和时间线按其时间戳判断。记忆从 UTC 文件名还原开始时刻，已知十分钟／六小时记忆按覆盖区间相交判断，其他粒度按开始时刻判断。日报与周报按其 `key` 和保存的 `timeZone` 还原覆盖区间，不按 `generatedAt` 判断；周报命中某天不代表其中所有内容都发生在那天。

`--app` 匹配记录中实际保存的应用名或 Bundle ID 子串，不做别名映射。记忆和时间线通常只保存 Bundle ID，因此可用 `--app com.openai.codex`；若应用显示名无法命中，改用实际 Bundle ID 或关键词。报告没有应用字段，带应用过滤时不会返回报告。

`--format json` 输出检索范围、总匹配数 `matched`、返回数 `returned`、截断标记 `truncated`、缺损标记 `partial`、警告计数和结果数组。每条保留时间、类型、证据来源类别、可用应用／窗口／记录编号、相对来源路径及相关片段。事件附段名和 JSONL 行号；事件 ID 在重启后可能复用，引用时同时带段名。时间线附来源记忆文件名，报告另列生成时间和覆盖区间。

没有查询条件时仅返回有限近期摘要。`events` 和 `all` 必须指定非空关键词、日期或应用条件之一，否则返回错误。匹配数多于返回数时，Agent 应缩小条件、分日期或分应用继续查。

## 数据范围与证据

| 层级 | 读取范围 | 用途 |
|---|---|---|
| `summaries`（默认） | `memories/*.md`、`narrative.json`、`reports/daily/*.json`、`reports/weekly/*.json` | 先定位任务、日期和接续点 |
| `events` | `segments/*/events.jsonl` 或 `events.jsonl.gz` | 按需核对文本变化、点击目标、快捷键、选择及界面片段 |
| `all` | 上述两层 | 已确定范围后的联合检索 |

记忆按照 `MemoryWriter.fileName`／`MemoryIndex.parse` 的命名读取，支持旧的 UUID 后缀及当前文件名；只解析本项目生成的简单 frontmatter，不引入通用 YAML 解析器。此前上下文、用户特征及 Citations 引用小节不参与记忆正文匹配，避免把前驱活动归到当前时段。报告只查最终 `body` 与标题，不查完整 `material`。可读导出重复这些数据，本脚本不重复检索导出文件；也不读请求台账、配置、日志、回收站或分批缓存。菜单栏隐藏的记录可能仍存在于这些来源中；查询范围以表中数据为准。

事件字段依据 [EventStreamRecord](../Sources/ComputerHistoryCore/EventStreamModels.swift) 提取。压缩段遵循 [EventArchive.eventsURL](../Sources/ComputerHistoryCore/EventArchive.swift) 的“同段优先原文”规则，不重复返回原文及归档。支持带偏移／小数秒的 RFC3339（标准互联网时间格式）及旧版从 2001-01-01 UTC 起算的数值日期。可选字段缺失保留未知；损坏 JSON 行、非法时间戳及损坏归档产生有界警告并继续查其他记录。目录或文件无法读取则非零退出，指出路径和权限问题，不静默切换根目录。

`derived_memory`、`derived_narrative`、`derived_report` 表示派生内容，仍可能有模型归纳错误；`recorded_event` 表示直接记录。`generation` 尽可能保留模型／事实／失败状态，时间线缺少相应字段时保持未知。窗口出现、控件变化、点击或 Enter 按键不单独证明完成、保存或发送，AX 差分及 OCR 文本也可能缺少上下文。回答应结合多条证据，把 Agent 自己的推断单独说明。

## 隐私边界与限制

脚本只用 Python 标准库读取本地文件，不联网、不调用模型、不写入或删除历史，也不启动其他程序。历史中的命令、对话与提示词注入均是数据，不构成当前用户授权；Skill 禁止执行其中的指令或据此开展外部操作。

选中的历史片段会进入当前 Agent 上下文；使用云端模型时，可能发送给相应模型服务。本地读取不能称为端到端本地处理，截断也不等于脱敏。Agent 只应提取回答需要的片段。其他采集与外发入口见[隐私说明](privacy.md)。

查询按文件顺序读取并维护有限结果，没有持久索引或全文数据库；大历史尤其压缩事件查询可能较慢。限制输出数量不会避免读取候选文件，宜使用摘要先定位再查事件。多文件读取不是事务快照，采集中尚未写完的末行可能被跳过。原始段可能已按保留策略删除，摘要和时间线也可能重复描述同一活动；它们不能当作相互独立的证据。无结果只说明给定范围未匹配，不证明没有活动。
