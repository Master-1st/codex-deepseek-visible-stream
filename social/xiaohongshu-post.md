# 标题

我把 DeepSeek V4 部署进 Codex 了：Sol 总控，还能自动路由 Pro / Flash

# 正文

这次开源的重点不是“修了一个 Bug”，而是把 DeepSeek V4 真正变成 Codex 里的异步专家：

- Sol 负责需求、规划、权限、综合、验证和最终回答；
- Luna 负责本地仓库、命令和明确可验收的执行；
- DeepSeek V4 Flash 负责低成本快速检查；
- DeepSeek V4 Pro 负责数学、算法、架构、复杂调试和独立审查。

调用不会再黑盒卡几分钟：

1. `deepseek_start` 立即返回 `job_id`；
2. DeepSeek 在后台通过 SSE 推理；
3. `deepseek_poll` 每 30 秒返回一次当前阶段，终态会提前返回；
4. Sol 拿到结果后独立复核，再给最终结论。

我还补了两层“别浪费 token”保护：

- `max_tokens` 不再固定给一个容易截断的小值，而是按推理强度自动给 16K / 32K / 64K，并用 `final_answer_max_chars` 单独控制答案长度；
- 如果长答案超过 Codex 单次工具输出窗口，用 `deepseek_read` 从本地分页续读，不会重新请求 DeepSeek，也不会重复消耗 API token。

如果 DeepSeek 自己返回 `finish_reason=length`，任务会明确标成 `INCOMPLETE`，不会再伪装成成功然后让 Sol 整题重跑。

项目同时保留了 Windows PowerShell 5.1 的中文 UTF-8 MCP 兼容层，解决 `id=null / -32700 Parse error`。

安装器、Codex Skill、无 API 回归测试、真实 SSE 测试和 GitHub Actions 都已整理好。

GitHub：Master-1st/codex-deepseek-visible-stream

# 标签

#Codex #DeepSeek #MCP #AI编程 #开源项目 #Agent #PowerShell #Windows开发 #程序员日常
