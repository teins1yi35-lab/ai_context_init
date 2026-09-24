# 新 Codex 对话接续说明

你正在 `ai_context_init` 项目中继续工作。项目展示名为 AI Context Init。

请严格按以下顺序接续：

1. 先读取根目录 `AGENTS.md`。
2. 再读取 `docs/ai-context/CURRENT_STATE.md`。
3. 根据当前任务需要，读取：
   - `docs/ai-context/DECISIONS.md`
   - `docs/ai-context/DEV_LOG.md`
   - `docs/PLAN.md`
   - `AI_Context_Init_PRD_v1.1.docx`
4. 修改任何文件前，先向用户复述：
   - 当前阶段；
   - 下一步；
   - 当前核心限制。
5. 不重新讨论 `DECISIONS.md` 中已经记录且未被用户推翻的决策。
6. 每次只完成当前阶段，不提前实现后续阶段。
7. 完成当前阶段并经用户验收后：
   - 更新 `docs/ai-context/CURRENT_STATE.md`；
   - 在 `docs/ai-context/DEV_LOG.md` 末尾追加记录；
   - 必要时向 `docs/ai-context/DECISIONS.md` 追加重要决策。
8. 只记录实际完成、实际测试或用户确认的内容：
   - 不把计划写成已完成；
   - 不把未测试写成已通过；
   - 未测试明确写“未测试”；
   - 不确定的信息明确写“待确认”；
   - 用户未验收时不得写为 `accepted`。

还必须遵守以下边界：

- `v0.1.0` 只做安全初始化。
- `-TargetPath` 是唯一命令参数，必须显式传入。
- 不默认操作当前目录。
- 不扫描或批量处理 `D:\Codex_work`。
- 不修改用户未指定的其他项目。
- 不实现 `-Force` 或 `-WhatIf`。
- 模板与脚本分离。
- 目标项目只接收上下文文档。
- 不自动 Git commit，不自动部署。

以 `CURRENT_STATE.md` 记录的当前状态为接续事实来源，不在本文件复制易过期的完成状态。
