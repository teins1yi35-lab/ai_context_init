# Changelog

## [0.2.0] - Unreleased

### 已实现

- 新增只读 `scripts/validate-ai-context.ps1`，仅接受必填 `-TargetPath`，只读取固定 5 个上下文文档。
- 检查文件存在且非空、严格 UTF-8、Schema Version、文件角色、必要字段、受管理标记、残留占位符和受控状态规则。
- 对 CURRENT_STATE 明显过长、HANDOFF 明确复制动态状态和 UTF-8 BOM 给出 Warning；Warning 不单独导致非零退出。
- 输出逐项 `Passed`、`Warnings`、`Errors`、处理建议、汇总数量和退出码。
- 固定退出码契约：成功或仅有 Warning 为 `0`，参数错误为 `1`，路径错误为 `2`，审计错误为 `3`，无法完成审计的读取错误为 `4`。
- 新增可重复运行的正式隔离矩阵，覆盖完整样本、字段/标记/编码错误、路径与权限边界、清单外文件、缺失/空文件、残留占位符和版本不匹配。
- 正式矩阵在 Windows PowerShell `5.1.26100.8875` 与 PowerShell `7.6.6` 均为 `19/19` 通过，并以哈希、长度和写入时间验证校验器零写入。

### 不包含

- 不自动修复、升级、迁移、删除或改写目标项目文档。
- 不提供 JSON 输出，不扫描清单外文件，不强制 Project Name 与目录名一致。
- 不实现 v0.3.0 的 `update-ai-context.ps1` 或结构化受控更新。
- 不自动提交 Git、打标签、推送、发布或部署。

### 发布状态

- v0.2.0 阶段 4 的实现与双环境验证已完成并通过用户验收。
- 本节随已获授权的本地 v0.2.0 release commit 提交；尚未创建 `v0.2.0` 标签、推送、部署或创建远程发布。

## [0.1.0] - 2026-09-24（仅本地标签）

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
- 本地提交和 `v0.1.0` 标签已完成；尚未 push、部署或创建远程发布。
