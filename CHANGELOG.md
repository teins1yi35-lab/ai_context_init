# Changelog

## [0.1.0] - 发布准备中

### 已实现

- 使用必填 `-TargetPath` 对用户明确指定的已存在目录进行安全初始化。
- 从规范化后的目标文件夹名称推导 `ProjectName`。
- 在模板中将 `Goal` 和 `TechStack` 初始化为“待确认”。
- 固定生成以下 5 个上下文文档：
  - `AGENTS.md`
  - `docs/ai-context/CURRENT_STATE.md`
  - `docs/ai-context/DEV_LOG.md`
  - `docs/ai-context/DECISIONS.md`
  - `docs/ai-context/HANDOFF_PROMPT.md`
- 已有文件逐个跳过，缺失文件继续创建，正式文件不会被覆盖、删除或改写。
- 对目标路径、模板、Schema 标记、占位符和必要目录执行预检查。
- 使用同目录临时文件、严格内容校验、UTF-8 无 BOM 和无覆盖原子提升。
- 执行生成后校验，并输出 `Created`、`Skipped`、`Warnings`、`Failed` 和退出码。
- 支持中文和空格路径；不会扫描或批量处理 `D:\Codex_work`，也不会把工具源码复制到目标项目。
- 提供 Windows PowerShell 5.1 使用说明、错误提示和退出码处理建议。

### 不包含

- 不提供 `-Force`、`-WhatIf`、`-ProjectName`、`-Goal` 或 `-TechStack`。
- 不实现 v0.2.0 的 `validate-ai-context.ps1`。
- 不实现 v0.3.0 的 `update-ai-context.ps1`。
- 不自动分析项目代码、更新已有文档、提交 Git、发布或部署。

### 发布状态

- Windows PowerShell 5.1 和 PowerShell 7 核心验证均已完成。
- PowerShell 7 使用版本 `7.6.6`，双环境临时项目验证通过。
- Git 仓库已初始化；提交和标签仍需用户最后授权，当前尚未执行。
