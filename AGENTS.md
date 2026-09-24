# AI Context Init 项目规则

本文件记录 Codex 在 `ai_context_init` 项目中必须遵守的稳定规则。展示名为 AI Context Init。

## 任务开始与读取顺序

1. 开始任何任务前，先读取根目录 `AGENTS.md` 和 `docs/ai-context/CURRENT_STATE.md`。
2. 根据任务需要读取 `docs/ai-context/DECISIONS.md`、`docs/ai-context/DEV_LOG.md`、`docs/PLAN.md` 和 `AI_Context_Init_PRD_v1.1.docx`。
3. 修改文件前，先确认当前阶段、下一步和核心限制。
4. 已记录且未被用户推翻的决策不得重新讨论或暗中改变。

## 阶段与范围

- 每次只完成当前阶段，不提前实现后续阶段。
- 阶段 1 只建立项目定位与基础文档，不创建 `scripts`、`templates` 或 `tests`。
- 阶段 1 不编写 `init-ai-context.ps1`、模板或测试代码。
- v0.1.0 只实现安全初始化。
- v0.2.0 才实现 `validate-ai-context.ps1`。
- v0.3.0 才实现 `update-ai-context.ps1` 与结构化受控更新。
- 模板与脚本必须分离。
- 目标项目只接收上下文文档，不得复制 `ai_context_init` 的源码、脚本、模板或测试代码。

## v0.1.0 参数与路径规则

- `-TargetPath` 是 v0.1.0 唯一命令参数，必须由用户明确传入。
- 不默认操作当前目录。
- 不扫描或批量处理 `D:\Codex_work`。
- 不修改用户未指定的其他项目。
- `ProjectName` 从规范化后的目标文件夹名称推导。
- `Goal` 与 `TechStack` 初始值写“待确认”。
- v0.1.0 不支持 `-Force`。
- v0.1.0 不支持 `-WhatIf`。
- v0.1.0 不支持 `-ProjectName`、`-Goal` 或 `-TechStack`。

## 文件写入与退出码

- 默认不覆盖已有文件。
- 目标文件已存在时逐个跳过，其他缺失文件继续创建。
- `Skipped` 只表示未覆盖，不表示已有文件通过 Schema 校验。
- 成功或仅跳过返回退出码 `0`。
- 参数错误、路径错误、模板或 Schema 读取失败、写入失败、生成后校验失败返回非 `0`。
- 正式目标文件必须采用无覆盖创建语义；不得删除、替换或改写已有文件。
- 初始化范围只包含规定的 5 个目标上下文文件及必要目录。

## 兼容性与实现约束

- 同时兼容 Windows PowerShell 5.1 和 PowerShell 7。
- 支持中文和空格路径。
- 文件统一使用 UTF-8 编码；`init-ai-context.ps1` 使用明确的 .NET UTF-8 无 BOM 写入，实际输出仍须在后续阶段验证。
- 不执行来自文本参数的内容。
- 不自动提交 Git，不自动部署。
- 脚本、模板、Schema、文档和测试保持职责分离。

## 文档维护与证据规则

- 阶段验收后更新 `docs/ai-context/CURRENT_STATE.md`，并在 `docs/ai-context/DEV_LOG.md` 末尾追加记录。
- 重要产品或技术决策写入 `docs/ai-context/DECISIONS.md`；旧决策不得删除，若被替代应保留并标明取代关系。
- 修改上下文文档时，只记录实际完成、实际测试或用户确认的内容。
- 不把计划写成已完成，不把未测试写成已通过。
- 未执行测试必须明确写“未测试”。
- 无法确认的信息必须写“待确认”。
- 用户未验收时，不得把阶段状态写为 `accepted`，也不得擅自进入下一阶段。
- 更新前先读取原文件，避免依据对话记忆重写历史。

## 安全与仓库卫生

- 不提交 `.env`、API Key、token、密码、真实个人数据、备份 JSON、日志等敏感或无关文件。
- 不修改 PRD 原文，除非用户明确要求更新 PRD。
- 不修改清单外文件，不删除历史记录。
- 不自动 Git commit，不自动打标签，不自动发布，不自动部署。

## 当前能力状态

- 初始化脚本：已编写，已在隔离临时项目中完成 Windows PowerShell 5.1 和 PowerShell 7 核心人工验证。
- 模板：已建立 5 个 Schema 1 模板。
- 测试：尚未建立。
- 构建命令：尚未建立。
- 发布命令：尚未建立。
