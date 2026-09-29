# 配置与排查参考

**简体中文** · [English](CONFIGURATION_EN.md)

适用于 **v4.0**。使用说明见 [README](README.md)，默认配置见 [config.example.json](config/config.example.json)。

## 配置位置与生效

编辑 `<CodexHome>\task-stats\config\config.json`，修改前先备份。仓库的示例文件供新安装和迁移使用，修改它不会自动更新已安装配置。JSON 不支持注释；布尔值使用 `true` / `false`，数字不要加引号。合并所需属性，不要用局部片段覆盖整个配置。

一般设置由后续 Hook 读取，涉及起点、采集和完成摘要缓存时应从新任务验证，避免轮中改动造成证据缺失。配置不会重排已经保存的历史日志或摘要。`tokenStatistics` 的缺省和无效类型使用默认值；其他字段没有统一的强类型纠错保证，应遵循下表类型。

`collection.intermediateMode` 是安装模式记录。异步/同步行为取决于 `hooks.json` 的 `async`；切换模式必须重新运行安装器。不要据此字段或状态脚本打印的配置值认定客户端已执行 Hook。

## 显示与 Token

| 配置路径 | 类型 / 默认值 | 含义 |
| --- | --- | --- |
| `schemaVersion` | 整数 / `11` | 安装器管理的配置格式版本，不是程序版本；不要手工提升 |
| `display.multiline` | 布尔 / `true` | 使用真实 LF；关闭后用 `｜` 连接 |
| `display.labelAlignment` | 字符串 / `center` | `center`、`left`、`right`、`none`；前三种在多行图标/普通样式中对齐标签与 Token 数值 |
| `display.showCoverageNotice` | 布尔 / `false` | 在摘要追加总体覆盖说明，不替代各项不完整提示 |
| `display.showSuccessStatus` | 布尔 / `false` | 是否显示成功状态；非成功状态仍显示 |
| `display.hideEmptyCategories` | 布尔 / `true` | 隐藏空分类，不隐藏 Token 的零值或缺失提示 |
| `display.emptyValue` | 字符串 / `无` | 非隐藏空分类使用的占位文本 |
| `display.highlightStyle` | 字符串 / `icon` | `icon`、`bracket`、`none`；括号样式不进行对齐填充 |
| `display.icons.*` | 字符串映射 / 见示例 | `start`、`end`、`mcp`、`skill`、`subagent`、`file`、`git`、`other` 的图标 |
| `display.labels.*` | 字符串映射 / 见示例 | `mcp`、`skill`、`subagent`、`file`、`git`、`other` 的标签；不修改客户端事件名称或全部固定中文文案 |
| `tokenStatistics.enabled` | 布尔 / `true` | 开启 Token 采集、展示和日志 |
| `tokenStatistics.showTurn` | 布尔 / `true` | 显示本轮 Token 区块 |
| `tokenStatistics.showSession` | 布尔 / `true` | 显示当前聊天累计 Token 区块 |
| `tokenStatistics.fields` | 字符串数组 / 十项全部 | 选择可见字段；空数组隐藏区块，日志仍保留完整已知值 |

Token 字段定义、顺序、缺失状态及示例见 [Token 统计](README.md#token-统计)。显示对齐与客户端限制见 [Hook 展示说明](HOOK_DISPLAY.md)。

## Skill 采集

以下设置主要影响 Skill 证据；`maxBytes` 还用于共用的会话切片读取。关闭某一种 Skill 证据来源不代表关闭所有 Skill 识别，也不会关闭独立的 Token 采集。

| 配置路径 | 类型 / 默认值 | 含义 |
| --- | --- | --- |
| `skillCollection.explicitMarkers` | 字符串数组 / `["$"]` | 提示中的请求使用回退标记；普通文本 `@` 不作为 Skill 标记推断；空数组关闭这一来源 |
| `skillCollection.maxStructuredNodes` | 整数 / `2000` | 结构化输入遍历预算 |
| `skillCollection.transcript.enabled` | 布尔 / `true` | 启用 Skill 会话记录补采 |
| `skillCollection.transcript.readMain` | 布尔 / `true` | 读取主会话 Skill 证据 |
| `skillCollection.transcript.readSubagents` | 布尔 / `true` | 读取能够关联的子Agent Skill 证据 |
| `skillCollection.transcript.requireSkillPathInXml` | 布尔 / `true` | XML Skill 识别要求路径证据 |
| `skillCollection.transcript.currentTurnLookbackEnabled` | 布尔 / `true` | 允许有界回看以查找本轮证据 |
| `skillCollection.transcript.lookbackBytes` | 整数 / `1048576` | 回看字节预算，默认 1 MiB |
| `skillCollection.transcript.settleInitialMs` | 整数 / `100` | 读取 Skill 会话记录前的初始等待，毫秒 |
| `skillCollection.transcript.settleQuietMs` | 整数 / `100` | 观察文件稳定的安静窗口，毫秒 |
| `skillCollection.transcript.settleMaxMs` | 整数 / `600` | 初始等待之后的会话记录稳定检查上限，毫秒 |
| `skillCollection.transcript.maxBytes` | 整数 / `4194304` | 共用会话切片的字节预算，默认 4 MiB，限制为 64 KiB 至 32 MiB；也影响经该读取器补采的文件、MCP 和子Agent活动 |
| `skillCollection.transcript.maxLines` | 整数 / `10000` | Skill 会话记录处理行数预算，限制为 100 至 100000 |
| `skillCollection.commandRead.enabled` | 布尔 / `true` | 识别读取 `SKILL.md` 的命令证据 |
| `skillCollection.commandRead.preferParsedCommand` | 布尔 / `true` | 优先使用结构化命令证据 |
| `skillCollection.commandRead.rawCommandFallback` | 布尔 / `true` | 允许在内存解析原命令作为回退，不保存原命令 |
| `skillCollection.commandRead.requireCompletedExecution` | 布尔 / `true` | 命令读取识别要求执行完成证据 |

`Skill ×N` 的作用域去重及证据等级见 [统计口径](README.md#skill)。增大读取预算无法补回客户端未提供的事件。

## 文件、活动与日志

| 配置路径 | 类型 / 默认值 | 含义 |
| --- | --- | --- |
| `fileTracking.enabled` | 布尔 / `true` | 文件变更采集开关 |
| `fileTracking.parseApplyPatch` | 布尔 / `true` | 解析工具补丁以辅助编辑证据关联，不是原生 `FileChange` 读取总开关 |
| `collection.settleInitialMs` | 整数 / `350` | Stop 汇总前等待中间事件的初始时长，毫秒 |
| `collection.settleQuietMs` | 整数 / `350` | Journal 稳定等待窗口，毫秒 |
| `collection.settleMaxMs` | 整数 / `2500` | 初始等待之后的 Journal 稳定检查上限，毫秒 |
| `collection.includePermissionRequests` | 布尔 / `true` | 在“其他”中统计权限请求，不控制权限策略或 Hook 注册 |
| `collection.includeCompaction` | 布尔 / `true` | 在“其他”中统计完成的上下文压缩，不控制压缩行为 |
| `logging.enabled` | 布尔 / `true` | 写每日日志；关闭不会移除已有日志或统计状态 |
| `logging.filePrefix` | 字符串 / `codex-task` | 日志文件名前缀，经安全处理后使用 |
| `debug.enabled` | 布尔 / `false` | 运行时诊断日志；位置见下文 |
| `toolAliases.*` | 字符串映射 / 见示例 | 为可分类的本地工具命名；默认包含 `Bash`、`update_plan`、`view_image` |
| `commandLogging.mode` | 字符串 / `safe` | 仅支持 `safe`、`off`；不存在原命令 `full` 模式 |
| `commandLogging.includeGit` | 布尔 / `true` | 是否保存 Git 安全命令明细，不关闭 Git 次数统计 |
| `commandLogging.includeShell` | 布尔 / `true` | 是否保存 Shell 安全命令明细，不关闭 Shell 次数统计 |
| `commandLogging.maxCommandChars` | 整数 / `4096` | 安全命令摘要的截断阈值，最小按 128 处理；截断后还会附加标记 |
| `commandLogging.maxRunsPerTask` | 整数 / `200` | Git、Shell 各自保留的命令运行明细上限，最小按 1 处理，不是总调用计数上限 |

共用会话切片的字节预算可以按上表调整，但文件内容核验预算、子Agent数量与读取时间预算，以及 Token 读取预算仍独立限制，不能通过一个字段统一调整。参见 [文件统计](README.md#文件) 和 [Token 边界](README.md#缺失与不完整数据)。

## 安装记录与兼容字段

以下字段仍可能出现在默认配置、升级结果或状态输出中；保留它们不代表旧算法仍在运行。

| 配置路径 | 示例默认值 | 当前状态 |
| --- | --- | --- |
| `collection.intermediateMode` | `quiet` | 安装器写入的模式记录；使用 `-IntermediateMode Quiet/Strict` 改变实际注册 |
| `fileTracking.gitStatusSupplement` | `true` | 历史兼容字段，当前文件计数不读取它，也不启用 Git 状态补计 |
| `fileTracking.gitStatusTimeoutMs` | `1500` | 历史兼容字段，当前文件计数不读取它 |
| `fileTracking.maxGitStatusEntries` | `5000` | 历史兼容字段，当前文件计数不读取它 |
| `skillCollection.mode` | `multi-source` | 描述性兼容字段，当前实现固定使用多源证据，不提供算法切换 |
| `skillCollection.deduplicateWithinTurn` | `true` | 兼容字段，当前实现始终按作用域与 Skill 名称去重，设为 false 不关闭去重 |
| `agentManagementTools` | 字符串数组 / 见示例 | 兼容列表；当前 Agent 管理识别由程序逻辑决定，不读取这个列表作为自定义入口 |

这些兼容字段可保留在现有配置中，无需为升级手工删除。

## 安装与推荐配置

所有脚本的 Codex Home 优先级为显式 `-CodexHome`、环境变量 `CODEX_HOME`、当前用户目录下的 `.codex`。维护同一安装时保持解析结果一致。

| 脚本 / 参数 | 用途 |
| --- | --- |
| `scripts/install.ps1 -IntermediateMode Quiet` | 默认模式；开始/结束同步，中间 Hook 异步 |
| `scripts/install.ps1 -IntermediateMode Strict` | 中间 Hook 也同步，可能增加等待或界面记录 |
| `scripts/install.ps1 -Force` | 在发现客户端配置禁用 Hook 时允许继续安装，不会启用 Hook |
| `scripts/status.ps1` | 检查目标安装与源码、配置、注册、兼容探针，不能代替客户端触发验证 |
| `scripts/apply-recommended-display.ps1` | 有选择地覆盖下列显示及采集设置，不重写 Hook 注册 |
| `scripts/uninstall.ps1` | 清理范围、参数组合和确认方式见 [卸载](README.md#卸载) |

安装器备份已有配置、Hook 和运行时，并合并迁移配置；失败时尝试恢复被替换文件。备份位于 `<CodexHome>\task-stats\backups`。备份可能含原有自定义设置或 Hook 命令，不应直接公开。

推荐配置脚本在实际写入前备份配置，覆盖范围如下：

- 恢复全部显示选项、分类标签和图标，以及 Token 开关、两个范围和十项字段。
- 开启文件采集和补丁解析；重设 `gitStatusSupplement=true`，仅补齐缺失的两个 Git 扫描预算字段。这些仍是上表所述的兼容字段。
- 恢复 Skill 的结构化预算、命令读取与 transcript 设置；重设描述性模式和去重字段；仅在缺失时补齐 `explicitMarkers`，保留已有标记选择。
- 恢复 Git/Shell 命令明细开关及长度、条数上限；保留已有 `commandLogging.mode=off`，其他模式归一为 `safe`。
- 设置配置格式版本；移除旧默认 `toolAliases.apply_patch=文件修改`，其他别名保持原值。
- 不修改 `collection`、`logging`、`debug` 或 `agentManagementTools`。因此即使恢复 Token 开关，原来关闭的每日日志仍保持关闭。

在仓库根目录运行以下命令，预览推荐配置操作；将 `-CodexHome` 替换为安装时使用的目录：

```powershell
powershell.exe -NoLogo -NoProfile -NonInteractive -ExecutionPolicy Bypass -File .\scripts\apply-recommended-display.ps1 -CodexHome "E:\.codex" -WhatIf
```

核对范围后去掉 `-WhatIf` 应用。它不是只改变排版的脚本，会覆盖上述自定义采集设置；通常不需要为此重新审核 Hook，使用新任务验证即可。

## 常见问题与诊断

| 现象 | 首先检查 |
| --- | --- |
| 没有开始提示或结束摘要 | Codex Home 是否相同、客户端 Hook 是否启用/信任、是否完全重启并开启新任务 |
| 状态检查失败 | `OverallHealthy` 及具体文件、语法、注册、兼容探针失败字段；不要只重装或使用 Force 掩盖原因 |
| 修改配置后没有变化 | 是否编辑已安装配置、是否看旧任务；Quiet/Strict 是否经安装器重新注册 |
| 文件“统计不完整” | 日志的文件统计限制；没有原生记录的写入不能靠旧 Git 字段补齐 |
| Token“未提供”或“未确认” | [Token 验证与排查](README.md#验证与排查)中的用量字段、起点、轮次和预算边界 |
| Skill 数量与读取次数不同 | [作用域去重与证据等级](README.md#skill)，以及关闭/缺失的采集来源 |
| 换行、空格或对齐异常 | [Hook 输出与客户端边界](HOOK_DISPLAY.md#按数据流定位问题)，分别检查真实输出和显示 |

临时设置 `debug.enabled=true` 可生成 `<CodexHome>\task-stats\debug\codex-task-stats-YYYY-MM-DD.jsonl`，记录运行事件、会话/轮次标识及诊断信息。启动阶段的固定故障诊断可能独立于该开关，状态脚本会报告可见的启动诊断位置。排查后关闭开关；关闭不会删除已经写入的诊断文件。

`data/state`、`data/journal`、`data/completed` 分别用于过程状态、事件和完成结果缓存。不要在运行中的任务里删除它们。停止相关任务后需要重置时，使用文档规定的卸载/重装流程，先保存自定义配置和需要保留的日志。

提交问题时只附最小脱敏片段，不上传整份聊天 JSONL、配置备份或完整用户目录。安全日志是尽力脱敏机制，公开前仍需检查；疑似敏感信息泄露按 [SECURITY.md](SECURITY.md) 处理。
