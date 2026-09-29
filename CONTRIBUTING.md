# 贡献指南

**简体中文** · [English](CONTRIBUTING_EN.md)

欢迎提交问题、建议和改进。使用说明见 [README](README.md)，安全问题请按 [安全反馈流程](SECURITY.md) 私密报告。

## 问题与建议

使用问题和功能建议请提交 [Issue](https://github.com/Luoxu777/codex-task-stats/issues)。较大的行为调整先说明问题、使用场景与方案，便于确认范围。

问题报告请包含：

- 程序版本、Windows 版本、客户端名称与版本，以及 `$PSVersionTable.PSVersion`。
- 安装方式和 Codex Home 的选择方式；私有路径使用占位符。
- 最小复现步骤、预期结果、实际结果及影响范围。
- 相关配置、状态检查失败字段，以及人工检查过的最小脱敏日志片段。

优先提供合成的 Hook/JSONL 样本，无需提交真实聊天内容。请友善讨论技术问题，避免人身攻击或公开他人信息。

## 开发与验证

使用 Windows 11 和 Windows PowerShell 5.1。项目无需额外包管理器或服务端。遵循 `.editorconfig` 和 `.gitattributes`：PowerShell 使用 UTF-8 BOM / CRLF，Markdown、JSON 使用 UTF-8 / LF。

从仓库根目录运行：

```powershell
# 文档修改
powershell.exe -NoLogo -NoProfile -NonInteractive -ExecutionPolicy Bypass -File .\tests\documentation.tests.ps1
git diff --check

# 代码、配置、Hook 模板、安装或卸载修改
powershell.exe -NoLogo -NoProfile -NonInteractive -ExecutionPolicy Bypass -File .\scripts\test.ps1
```

完整回归使用临时 Codex Home 验证安装、迁移和卸载，保持测试目录与真实安装隔离。涉及显示变化时，还需在目标客户端的新任务中验证；分别记录脚本检查与客户端观察结果。

## 提交与 Pull Request

- 聚焦一个问题或一组关联行为，保留无关工作区修改。不要提交被忽略的文件、运行数据、用户配置或未脱敏日志。
- 提交说明使用完整的中英双语格式：中文标题、中文分项、英文标题、对应英文分项，段落间空一行。标题使用完整句并以句号结束。说明标题使用“主要内容 / Main changes”，首次功能提交可用“主要功能 / Main features”。默认不使用 Conventional Commit 前缀，维护者另有要求时遵循其要求。
- PR 描述包含背景、改动内容、影响范围、实际验证结果及风险或未验证项。
- 用户可见行为同步更新对应的中英文文档。两种语言分文件，章节和信息对应，通过顶部链接切换。
- 版本以 `VERSION` 为准，变更记录按版本号组织，README 保留通用使用说明。仅在有确定记录时注明发布日期。
- 修改 Hook 默认行为时同步 `hooks.template.json`、安装器及相关检查；修改配置时同步中英文配置参考，说明生效方式和迁移行为。
- 展示截图注明来源、环境及适用范围，历史验证记录保留原有边界。

## 许可证

贡献沿用项目的 [MIT 许可证](LICENSE)，请保留必要的版权及来源说明。
