# Codex Task Stats

**简体中文** · [English](README_EN.md)

[快速开始](#快速开始) · [统计口径](#统计口径) · [配置参考](CONFIGURATION.md) · [变更记录](CHANGELOG.md) · [参与贡献](CONTRIBUTING.md) · [安全反馈](SECURITY.md)

> 为 Windows 原生 Codex 工作流提供隐私优先的任务统计：自动汇总用时、MCP、Skill、子Agent、文件变更、Git、本地工具调用及当前聊天的 Token 用量。

<p align="center">
  <img src="assets/preview4.png" alt="Codex Task Stats 分类统计及本轮、累计 Token 预览" width="760" />
</p>

用户提供的运行截图，展示 MCP、Skill、文件、Git、其他活动，以及本轮和当前聊天累计 Token。文件变更证据不足时会显示“统计不完整”。

Codex 可以完成很长、很复杂的任务，但任务结束后常常很难快速回答这些问题：**到底跑了多久？用了哪些 MCP？调用了哪些 Skill？启动了几个子Agent？改了多少文件？Git 做了什么？**

Codex Task Stats 通过用户级 Hook 自动收集这些信息：客户端只显示一条紧凑的任务摘要，更详细的安全日志则按天保存在本地。同一个 Codex Home 下的项目无需重复配置。

如果它让你的长任务更容易理解、复盘和排查，欢迎给项目一个 Star ⭐。

## 亮点

- **零侵入任务摘要**：任务开始显示时间，结束自动汇总用时与关键活动。
- **Token 用量快照**：默认展示本轮和当前会话累计的十项指标，支持范围与字段选择；数据来源及限制见 [Token 统计](#token-统计)。
- **MCP 真实调用统计**：按 `server/tool` 聚合，只统计实际执行的调用。
- **Skill 多源识别**：结合结构化输入、transcript、子Agent记录、显式标记与 `SKILL.md` 读取证据。
- **子Agent 统计**：优先按真实 `agent_id` 去重，并在能够安全关联时显示可读角色名称；缺少生命周期时保留成功创建调用的回退计数。
- **文件变更统计**：以成功 `FileChange` 记录汇总新增、修改、删除；重命名和移动分别计入原路径删除、新路径新增。
- **Git 语义统计**：区分 Git 运行、指令和真正的变更操作；`status`、`diff`、dry-run 等只读行为不会被当成变更。
- **隐私优先日志**：命令默认以 `safe` 模式保存，敏感参数、远程地址、自由文本和工作区外路径会被隐藏。
- **本地、按日、可读**：无需服务端、数据库或额外面板，日志直接落在 Codex Home。
- **面向 Windows PowerShell 5.1**：安装、状态检查和核心回归测试都针对原生 Windows 环境设计。

## 它会显示什么

以下摘要和后文的日志均为展示示例，不代表同一次任务；具体项目和数量以实际运行为准。代码块按等宽字符列对齐，客户端实际排版见上方截图。

任务开始：

```text
🟢      开始      ： 14:07:08
```

任务结束：

```text
🔴      结束      ： 14:08:34（用时：1分26秒）
🔌      MCP       ： mysql_7/query ×2
🧩     Skill      ： analyze ×1
🤖    子Agent     ： code_reviewer ×1，architect ×1
📝      文件      ： 修改 ×3
🌿      Git       ： 运行 ×2，指令 ×6，变更 ×1
⚙️      其他      ： Shell命令 ×2

📊 本轮 Token（读取时快照）
        总量      ： 136,000
        输入      ： 128,000
        输出      ：   8,000
      缓存读取    ：  96,000
   未命中缓存输入 ：  32,000
      缓存写入    ：       0
     缓存命中率   ：     75%
      推理输出    ：   5,000
     非推理输出   ：   3,000
      推理占比    ：     63%

📈 累计 Token（读取时快照）
        总量      ： 816,000
        输入      ： 768,000
        输出      ：  48,000
      缓存读取    ： 576,000
   未命中缓存输入 ： 192,000
      缓存写入    ：       0
     缓存命中率   ：     75%
      推理输出    ：  30,000
     非推理输出   ：  18,000
      推理占比    ：     63%
```

没有数据的分类会自动隐藏。成功任务默认不显示“状态：完成”；失败、已中断或未知状态才会额外显示状态。

程序默认启用 `display.multiline: true`，按分类输出真实换行；设为 `false` 可恢复以 `｜` 分隔的单行摘要。实际显示效果取决于客户端。配置含义、验证结果和排查方法见 [Hook 展示与换行排查](HOOK_DISPLAY.md)。

多行模式下，开始、追加输入提示及结束摘要默认使用 `display.labelAlignment: "center"` 居中标签，也可设置为 `left`、`right` 或 `none`。按 Windows 参考字体宽度计算普通空格，字体测量不可用时回退到字符列宽估算；实际视觉效果取决于客户端字体。单行及括号样式保持原格式，文档代码块仅展示输出文本。

修改已安装的配置文件即可调整这些选项，文件位置见[本地日志与配置](#本地日志与配置)。

## Hook 在哪里显示

完成安装及客户端要求的 Hook 信任审核后，Hook 会出现在 Codex / ChatGPT 客户端的对话时间线中：`UserPromptSubmit` 在任务开始时显示开始时间，`Stop` 在任务结束时显示统计摘要。其他中间 Hook 默认静默采集，不会持续打断对话。

<p align="center">
  <img src="assets/hook-location2.png" alt="回答下方红框标出的 Hook 统计入口" width="900" />
</p>

截图中的红框标出回答下方的 Hook 统计入口，点击后可查看统计详情。入口位置和客户端外观可能随版本变化。

## 升级与重装

功能变更见 [变更记录](CHANGELOG.md)，配置格式和历史兼容字段见 [配置参考](CONFIGURATION.md)。

升级时使用原安装的 Codex Home。直接运行安装脚本会备份并迁移现有配置；要采用当前推荐显示与采集选项，可再运行 `scripts/apply-recommended-display.ps1`，它会覆盖对应选项。若希望清除旧程序与统计状态，先备份自定义配置，再运行 `scripts/uninstall.ps1 -RemoveProgram -Confirm:$false`，然后重新安装；该卸载方式保留日志和备份，但会移除配置，重装后使用默认配置。显式指定 Codex Home 时，各脚本都应使用相同的 `-CodexHome` 参数。

升级或重装后运行 `scripts/status.ps1`，完全重启客户端，并按客户端提示完成 Hook 信任审核及新任务验证。

## 快速开始

### 环境要求

- Windows 11
- 原生 Codex / ChatGPT 客户端的 Windows Agent 环境
- Windows PowerShell 5.1
- 当前 Windows 用户可写的 Codex Home

以上为目标环境；未声明 Windows 10、PowerShell 7、WSL、Linux 或 macOS 的兼容性。客户端还需实际支持并启用所需 Hook 事件；历史客户端验证环境见 [Hook 展示记录](HOOK_DISPLAY.md#历史验证记录与适用边界)，不作为最低版本保证。

### 1. 克隆或下载仓库

从 [GitHub 仓库](https://github.com/Luoxu777/codex-task-stats) 下载源码，或执行：

```powershell
git clone https://github.com/Luoxu777/codex-task-stats.git
Set-Location codex-task-stats
```

进入仓库根目录，确认可以看到：

```text
src/
scripts/
config/
tests/
```

### 2. 先运行回归测试

```powershell
powershell.exe -NoLogo -NoProfile -NonInteractive `
  -ExecutionPolicy Bypass `
  -File ".\scripts\test.ps1"
```

只有测试全部通过后再安装。

### 3. 安装

默认 Codex Home：

```powershell
powershell.exe -NoLogo -NoProfile -NonInteractive `
  -ExecutionPolicy Bypass `
  -File ".\scripts\install.ps1" `
  -IntermediateMode Quiet
```

自定义 Codex Home：

```powershell
powershell.exe -NoLogo -NoProfile -NonInteractive `
  -ExecutionPolicy Bypass `
  -File ".\scripts\install.ps1" `
  -CodexHome "E:\.codex" `
  -IntermediateMode Quiet
```

Codex Home 解析优先级：

```text
-CodexHome 参数
→ CODEX_HOME 环境变量
→ 当前用户目录\.codex
```

安装器会安全合并属于 Codex Task Stats 的 Hook，不要求手工覆盖整个 `hooks.json`。

默认 `Quiet` 将中间 Hook 注册为异步；`Strict` 改为同步，顺序更强，但可能增加等待和界面记录。切换时使用相同 Codex Home 重新运行安装器，并把参数改为 `-IntermediateMode Strict` 或 `Quiet`；仅修改配置文件中的 `collection.intermediateMode` 不会改变注册。`hooks.template.json` 对应默认 Quiet 模式，仅用于结构参考。

若安装器提示 `config.toml` 禁用 Hook，先检查客户端配置。`-Force` 仅允许安装继续，不会启用客户端 Hook，也不会绕过其他检查或信任审核。安装参数、备份和推荐配置的覆盖范围见 [配置参考](CONFIGURATION.md)。

### 4. 检查状态

```powershell
powershell.exe -NoLogo -NoProfile -NonInteractive `
  -ExecutionPolicy Bypass `
  -File ".\scripts\status.ps1"
```

状态脚本会检查运行时文件、语法、配置、Hook 注册和关键兼容探针。

重点查看 `OverallHealthy`、`RegisteredHandlerCount`（正常为 9）、`ProgramMatchesSource`、`LibraryMatchesSource` 和 `RuntimeCompatibilityPassed`。失败时保留具体失败字段，先处理路径、缺失文件或配置错误；不要仅凭某个配置值为 `True` 推断功能已经触发。

检查状态时应使用与安装时相同的 Codex Home。若安装时显式指定了目录，在上述命令末尾追加相同的参数，例如 `-CodexHome "E:\.codex"`；使用默认解析方式时，保持 `CODEX_HOME` 环境变量与安装时一致。

### 5. 审核 Hook 并验证首次运行

按照当前客户端提示，审核并信任新增或变更的 Hook 定义。非托管 Hook 在获得信任前会被跳过；更新定义后可能需要重新审核。Codex CLI 可通过 `/hooks` 管理信任；桌面客户端以其实际提示为准。详见[官方 Hook 信任说明](https://learn.chatgpt.com/docs/hooks#review-and-trust-hooks)。

完成审核后，运行一个新任务，确认出现开始提示、结束摘要，并在[本地日志目录](#本地日志与配置)生成对应记录。状态检查通过不等于已验证客户端能够实际触发 Hook。

## 详细日志示例

客户端摘要保持简洁，完整任务细节按天写入本地日志。一个任务的日志大致如下：

```text
【任务信息】
开始时间：2026-09-01 14:07:08 +08:00
结束时间：2026-09-01 14:08:34 +08:00
用时：1分26秒

【执行结果】
状态：完成

【调用统计】
MCP：
  - mysql_7/query ×2
Skill：
  - analyze ×1
  - code-review ×2
子Agent：
  - code_reviewer ×1
  - architect ×1
Git：
  运行 ×2
  指令 ×6
  变更 ×1
其他：
  - Shell命令 ×2

【文件变更】
文件：
  - 修改 ×3

【统计完整性】
总体完整性：部分
```

完整的脱敏示例见 [`examples/detailed-task.log`](examples/detailed-task.log)。真实日志还会包含经过安全处理后的 Git / Shell 命令明细、Skill 采集来源和统计完整性说明。

## 统计口径

### 任务与用时

同一次回答（同一 `turn`）的首次输入显示“开始”，回答中途追加的输入显示“第 N 次输入”和本次输入时间，每次输入独立显示一条提示。正常情况下，`Stop` 的用时从本次回答的首次输入计算到结束；回答结束后的新一轮输入重新计时、计数，不包含两次回答之间的等待时间。追加输入不会重置文件基线、工具次数或 Skill、子Agent统计；旧版全会话计时缓存不再参与统计。

若压缩等中间事件先建立了本轮状态，后到输入保留该状态的起点和已采集记录，因此统计起点可能早于输入提示时间。当前耗时优先使用保存的本轮开始时间与结束时间之差，受系统校时影响；起点不可用时才尝试单调时钟，两者均不可用时显示未知耗时。

开始 Hook 外层超时为 10 秒，内部锁等待为 1 秒，开始时不扫描工作区。

### MCP

只统计实际执行的 MCP，并按 `server/tool` 聚合。同名工具来自不同 MCP Server 时不会合并。

除工具 Hook 外，还会从本轮 transcript 的原生 `McpToolCall` 完成记录补采，并按调用 ID 去重。执行失败但已结束的调用也计次；运行中的调用、缺少稳定 ID 或仅在代码文本中提及工具不补计，参数和返回正文不保存。

### Skill

Skill 采用多源识别。由于客户端事件和 transcript 结构可能变化，它属于**尽力统计**，不应理解为 100% 完整审计。

`Skill ×N` 按本轮中的“作用域＋Skill 名称”去重：主任务在同一作用域反复读取同一个 Skill 只计一次；主任务和一个已关联子Agent都使用 `analyze` 时，可汇总为 `analyze ×2`。数字不是同一 Skill 的实际执行次数。

证据区分“已确认”“已读取”和“已请求”。缺少更强证据时，提示中的 `$skill` 可作为请求使用的回退，不能证明已执行；同一作用域有多种证据时保留优先级更高的证据。日志中的采集来源与证据等级用于解释这些区别。

### 子Agent

有真实身份的子Agent按本轮唯一 `agent_id` 去重。通过 `followup_task` 复用已有子Agent时，成功调用能关联到真实身份，且父子关系和本轮执行记录均通过校验，也会计入；同一子Agent多次续跑仍只计一次，普通消息和等待不会增加数量。可读名称只作为显示增强，不参与身份判断；无法安全、可靠地关联名称时，会回退到生命周期中的 `agent_type`。

汇总中完全没有生命周期启动事件时，已明确成功的创建调用可按稳定调用 ID 回退计数。该回退不代表已确认真实 Agent 身份，不能用来证明续跑或父子关系。

优先显示经过校验的短任务名称，通过创建调用返回的 `agent_id` 或子会话元数据关联身份，不按事件顺序猜测。路径、凭据式名称和提示词不会作为名称保存。

### 文件

客户端显示 `新增 ×N，修改 ×N，删除 ×N`，三类之和为本次回答的已确认变更文件数，不要求与客户端“已编辑”数量完全一致。重命名或移动计原路径删除和新路径新增；同一路径最终只归入一个类别。

按本次回答的成功 `FileChange` 记录去重，利用补丁反推涉及文件的首次内容，只定点读取最终内容。修改后恢复原样、新增后又删除均不计；新增后继续编辑仍计新增，删除后重建按内容是否恢复判断；仅暂存或提交已有修改不增加计数。失败记录不计入，追加输入不清空记录。

不再扫描整个工作区，旧的 `gitStatusSupplement`、`gitStatusTimeoutMs`、`maxGitStatusEntries` 不再参与文件计数。子Agent仅从已知会话目录查找并校验身份，在本次回答时间范围内与主任务记录按时间合并。文本比较统一 CRLF/LF，忽略一个文件头 BOM，保留正文和末尾换行差异；原文和补丁只在内存处理，不写入统计状态或日志。

没有上报 `FileChange` 的 Shell、MCP、IDE 写操作可能遗漏。记录截断、补丁缺失或冲突、文件不可读、子Agent记录无法关联时，显示已确认数量及“统计不完整”，日志说明原因。定点读取限制为单文件 4 MiB、最多 1000 个路径和约 32 MiB 文本，读取预算 2 秒、含补丁核验总预算 4 秒；子Agent读取最多 16 个、预算 2 秒，超限明确降级。这里的“已核验”只针对已采集记录，不代表完整磁盘审计。

### Git

```text
🌿 Git：运行 ×N，指令 ×M，变更 ×K
```

- **运行**：一次已完成的 Shell 工具调用中只要包含 Git 指令，就计一次。
- **指令**：顶层 `git` / `git.exe` / `git.cmd` 指令总数。
- **变更**：会改变工作区、暂存区、本地仓库、引用、Git 配置或远程仓库状态的 Git 指令数。

例如：

```powershell
git status; git diff; git add .; git commit -m "message"
```

统计为：

```text
运行 ×1，指令 ×4，变更 ×2
```

文件变化数量和 Git 变更指令数量是两个独立维度，不应该相等。

### 其他活动

“其他”包含 Shell 命令、计划更新、图片查看等本地工具，以及以下可观测事件。Git、文件编辑和 Agent 管理工具按各自规则分类，不保证此处等于所有工具调用的总和。

| 显示 | 计数含义 |
| --- | --- |
| `权限请求` | 收到的 `PermissionRequest` 事件；可通过 `collection.includePermissionRequests` 关闭计数 |
| `上下文压缩` | 收到的 `PostCompact` 事件；可通过 `collection.includeCompaction` 关闭计数 |
| `未确认调用` | 有前置记录，但汇总时没有匹配完成记录的调用；不等于执行失败 |
| `本地工具/名称` | 没有专用分类或别名的本地工具 |

## 隐私设计

默认命令日志模式：

```json
{
  "commandLogging": {
    "mode": "safe",
    "includeGit": true,
    "includeShell": true
  }
}
```

只支持：

- `safe`：保存安全处理后的命令摘要。
- `off`：不保存命令明细。

**不存在保存原始命令的 `full` 模式。**

项目会尽力隐藏 API Key、Token、Password、Cookie、Authorization、数据库认证信息、带认证 URL、Git remote 凭证、commit message、自由文本参数、工作区外绝对路径，以及无法证明可以安全保存的参数。

项目不会记录命令 `stdout`、`stderr`、工具返回正文或每条命令的独立用时。安全模式遵循一个简单原则：**无法安全判断时，宁可隐藏整条命令。**

公开提交 Issue 或日志前，请再次检查是否包含凭证、私有路径或业务数据；`safe` 是尽力而为的安全渲染机制，不是通用 DLP 或合规审计系统。

## Token 统计

### 统计范围与数据来源

Token 统计默认开启，在原有分类之后展示“本轮 Token”和“累计 Token”。本轮是一次回答，包含中途追加的输入；累计是**当前聊天**的累计消耗，包含本轮，不汇总其他聊天、项目或账户。

数据来自当前主会话 JSONL 的 `event_msg / token_count / info.total_token_usage`。本轮采用可信起止累计快照之差，会话采用结束时的累计快照；不累加重复快照，也不将 `last_token_usage` 当作整轮用量。这里的输入可包含多次模型请求中重复发送的上下文，不等于用户输入文字的长度。

统计以结束 Hook 读取时的数据为准，区块会显示“读取时快照”；不保证客户端已写入最后一次模型用量，不将其作为计费账单。独立子Agent的消耗是否已包含在主会话记录中取决于客户端，本工具不额外累加子Agent日志。当前不提供费用、上下文占用率或按模型拆分。

### 指标定义

| 字段键 | 显示名称 | 定义 |
| --- | --- | --- |
| `total` | 总量 | 数据源的 `total_tokens`；正常情况下为输入加输出 |
| `input` | 输入 | `input_tokens` |
| `output` | 输出 | `output_tokens`，包含推理输出 |
| `cachedInput` | 缓存读取 | `cached_input_tokens`，属于输入细分 |
| `uncachedInput` | 未命中缓存输入 | 输入减缓存读取 |
| `cacheWrite` | 缓存写入 | 数据源的 `cache_write_input_tokens`，不再次加到总量 |
| `cacheHitRate` | 缓存命中率 | 缓存读取除以输入 |
| `reasoningOutput` | 推理输出 | `reasoning_output_tokens`，属于输出细分 |
| `nonReasoningOutput` | 非推理输出 | 输出减推理输出；可能包含正文、工具调用等 |
| `reasoningShare` | 推理占比 | 推理输出除以输出 |

数量以整数和千分位显示，百分比四舍五入到整数（例如 `62.5%` 显示为 `63%`）。缓存读取和推理输出不能再加到总量中。比率由对应范围的累计分子和分母计算，不平均各请求的百分比。

### 配置

在[已安装的配置文件](#本地日志与配置)中合并以下属性，保留其他配置；不要用片段覆盖整个文件：

```json
{
  "tokenStatistics": {
    "enabled": true,
    "showTurn": true,
    "showSession": true,
    "fields": [
      "total", "input", "output", "cachedInput", "uncachedInput",
      "cacheWrite", "cacheHitRate", "reasoningOutput", "nonReasoningOutput", "reasoningShare"
    ]
  }
}
```

| 属性 | 类型与默认值 | 行为 |
| --- | --- | --- |
| `enabled` | 布尔值，`true` | 控制 Token 采集、显示和日志；关闭不影响原有统计 |
| `showTurn` | 布尔值，`true` | 显示本轮区块 |
| `showSession` | 布尔值，`true` | 显示当前会话累计区块 |
| `fields` | 字符串数组，默认上述全部十项 | 选择字段；按指标表顺序显示，重复项去重，未知键忽略；空数组隐藏两个区块 |

例如只显示本轮总量、输入和输出：设置 `showSession` 为 `false`，`fields` 为 `["total", "input", "output"]`。隐藏区块或字段仅影响客户端显示；`enabled` 与 `logging.enabled` 均为 `true` 时，日志仍保存完整的已知数值与状态。关闭 Skill 采集不影响 Token 统计。

缺少配置项或类型无效时使用默认值；布尔配置必须使用 JSON 的 `true` / `false`，不能使用字符串。安装升级会补齐缺失项，保留已有 `false`、空数组和字段选择。主动运行 `scripts/apply-recommended-display.ps1` 会恢复上述推荐值。

Token 沿用 `display.labelAlignment`，支持 `center`（默认）、`left`、`right`、`none`。可见 Token 字段参与统一标签宽度计算；单行模式仍以 `｜` 分隔，括号样式不补对齐空格。Token 真实零值与缺失提示不受 `display.hideEmptyCategories` 隐藏。详细日志保持无 Emoji、无排版填充。

在多行模式且标签对齐为 `center`、`left` 或 `right` 时，Token 数值列始终右对齐。列宽取本轮与会话累计中所有可见字段格式化后的最大宽度，数字、百分号和“未提供”等提示的末尾共用右边界；隐藏的范围或字段不参与计算。冒号后至少保留一个空格。此规则不新增配置项，不改变结束时间、MCP、Skill 等文字内容的排版。`none`、单行模式、括号样式和详细日志保持紧凑格式，不补数值对齐空格。

数值与标签共用现有字体度量和普通空格补齐方式；无法测量字体时采用字符列宽估算。客户端字体、缩放和折行可能造成视觉偏差，文档示例不代表像素级对齐保证。

### 缺失与不完整数据

| 显示 | 含义 |
| --- | --- |
| `0` | 数据源明确报告零值 |
| `未提供` | 数据源没有提供原始字段或没有可用用量记录；依赖缺失字段的推导项显示 `未确认`，并在区块状态中说明原因 |
| `不适用` | 比率的分母为零 |
| `未确认` / `统计不完整` | 基线、会话或轮次归属无法确认，或数值矛盾、计数回退、文件变化、读取额度不足 |

首次输入事件缺失、轮中启用功能或恢复旧状态时，如果无法证明起点，本轮不会显示为零；会话累计在来源可信时仍可独立显示。读取只限当前会话，每次 Hook 的 Token 读取最多 4 MiB、10,000 行；超出可核实范围会标明不完整，不扫描所有历史聊天。读取时尚未写完的 JSONL 行不参与统计。

会话文件超过 4 MiB 不代表本轮一定无法统计：起点回看会跳过截取开头尚无轮次边界的历史用量；如果后续能确认上一轮累计值、本轮边界和本轮连续记录，仍可计算本轮增量。真正缺少起点或本轮连续记录超出额度时，仍显示“未确认”。不同对话按会话标识与轮次标识分别保存状态，只用各自会话的累计值计算。

重复 Stop 与日志补写复用第一次冻结结果，不追加计算迟到的用量。配置修改影响后续任务，不能通过重复打开已完成摘要验证新配置。Token 读取失败不会阻断原有统计。

### 验证与排查

在仓库根目录运行完整回归，或仅运行 Token 专项检查：

```powershell
powershell.exe -NoLogo -NoProfile -NonInteractive -ExecutionPolicy Bypass -File .\scripts\test.ps1
powershell.exe -NoLogo -NoProfile -NonInteractive -ExecutionPolicy Bypass -File .\tests\token-statistics.tests.ps1
```

完整回归包含配置迁移、原有分类、Token 算术与边界、重复 Stop、日志补写及双语文档一致性检查。测试使用临时目录与合成 Token 数据，不需要读取真实聊天内容。文档检查也可独立运行 `tests/documentation.tests.ps1`。

如果显示“未提供”或“未确认”，先查看对应区块和本地日志中的状态，确认当前客户端是否提供用量字段、是否存在可信的首次输入记录。测试通过只证明所覆盖的脚本行为；安装后仍需在目标客户端的新任务中检查最终 Hook JSON、显示与日志。截图的观察范围见 [展示记录](HOOK_DISPLAY.md#历史验证记录与适用边界)。

## 本地日志与配置

默认日志位置：

```text
<CodexHome>\task-stats\logs\codex-task-YYYY-MM-DD.log
```

每个任务包含任务信息、执行结果、调用统计、文件变更、Skill 采集和统计完整性等区域。日志不使用 Emoji，方便搜索、Diff 和脚本处理。

日志写入失败时，摘要会提示失败，并保留冻结的汇总及原始统计数据。同一任务再次收到 `Stop` 时会重试补写，成功后才清理原始数据；补写使用第一次结束时的内容与时间，不重新统计。这不是后台自动重试。

安装后的配置位于：

```text
<CodexHome>\task-stats\config\config.json
```

仓库中的 [`config/config.example.json`](config/config.example.json) 是默认配置参考，可配置客户端分类图标与标签、Skill transcript 读取范围、中间 Hook 安静模式、日志开关、命令日志策略和工具别名。文件统计口径与旧配置的适用边界见[文件统计说明](#文件)。

逐项默认值、生效方式、兼容字段、推荐配置覆盖范围与调试方法见 [配置参考](CONFIGURATION.md)。通常在下一轮新任务验证配置；切换 Quiet/Strict 必须重新注册 Hook。

## 卸载

只移除 Hook：

```powershell
powershell.exe -NoLogo -NoProfile -NonInteractive `
  -ExecutionPolicy Bypass `
  -File ".\scripts\uninstall.ps1"
```

卸载时同样使用安装时的 Codex Home。若安装时显式指定了目录，在上述命令末尾追加相同的 `-CodexHome` 参数；使用默认解析方式时，保持 `CODEX_HOME` 环境变量与安装时一致。

完整选项：

| 参数 | 行为 |
| --- | --- |
| 无清理参数 | 只移除本项目 Hook，保留程序、配置、状态、日志和备份 |
| `-RemoveProgram` | 同时删除程序、配置、状态、调试日志及版本文件，保留每日日志和备份 |
| `-RemoveProgram -RemoveLogs` | 同时删除整个 `task-stats` 安装目录，包含日志和备份；不可从该目录恢复 |
| 单独 `-RemoveLogs` | 不触发数据清理；必须与 `-RemoveProgram` 一起使用 |
| `-WhatIf` | 预览要执行的操作，不执行删除 |
| `-Confirm:$false` | 跳过 PowerShell 确认；不建议在首次清理时使用 |

清理前可用 `-WhatIf` 预览；删除操作会请求确认。查看参数帮助：

```powershell
Get-Help .\scripts\uninstall.ps1 -Full
```

卸载脚本会先备份 `hooks.json`，并且只移除属于 Codex Task Stats 的处理器。

只有实际移除处理器时才生成卸载备份；完整清理也会删除刚生成的备份，需保留时先复制到安装目录之外。卸载后完全重启客户端。它不会删除 Codex 自身的聊天记录或其他 Hook。

## 项目结构

```text
codex-task-stats/
├── assets/                # README 预览图
├── config/                # 默认配置
├── examples/              # 脱敏日志示例
├── scripts/               # 安装、状态、测试、卸载
├── src/                   # Hook 主处理器与子Agent关联逻辑
├── tests/                 # 核心回归测试与最小样本
├── hooks.template.json    # Hook 结构参考
├── README.md
├── README_EN.md
├── CONFIGURATION.md       # 配置、生效方式及排查
├── CONFIGURATION_EN.md    # 英文配置参考
├── CONTRIBUTING.md        # 问题反馈与贡献约定
├── CONTRIBUTING_EN.md     # 英文贡献指南
├── SECURITY.md            # 安全问题私密反馈
├── SECURITY_EN.md         # 英文安全反馈说明
├── CHANGELOG.md           # 版本变更记录
├── CHANGELOG_EN.md        # 英文变更记录
├── HOOK_DISPLAY.md        # 展示边界与历史验证
└── LICENSE
```

## 已知边界

- Skill 统计依赖可观察到的结构化事件、transcript 和 `SKILL.md` 读取证据，格式变化可能造成遗漏。
- 某些托管工具可能没有完整的标准 Hook 事件。
- Shell 间接产生的文件变化不一定能够完整归因。
- 子Agent显示名称只有在能够安全且可靠关联时才会使用；成功创建调用的回退计数不代表已确认真实 Agent 身份。
- Token 是当前主会话记录的读取时快照；缺失字段、轮次边界、累计计数重置或迟到用量可能造成统计不完整，不能据此推导最终账单或全账户消耗。

## 反馈与贡献

使用问题与功能建议请提交 [GitHub Issue](https://github.com/Luoxu777/codex-task-stats/issues)，附程序和客户端版本、PowerShell 版本、脱敏配置、复现步骤与预期/实际结果。提交代码前请阅读 [贡献指南](CONTRIBUTING.md)；安全问题按 [安全反馈流程](SECURITY.md) 私密报告。

## 许可证

本项目采用 [MIT License](LICENSE)。使用、修改和分发时请保留许可证要求的版权及许可声明。
