# 标题

中文提示词让 DeepSeek 卡死？我把 Codex MCP 修好了

# 正文

我遇到一个很隐蔽的问题：

同一个 `deepseek_start`，英文提示词不到 1 秒就返回 `job_id`，换成中文后却能一直转圈，直到 660 秒超时。

一开始很像 DeepSeek 推理慢，实际请求根本没到 DeepSeek。

根因是编码错位：Codex 的 stdio MCP 发 UTF-8，而 Windows PowerShell 5.1 在中文系统上可能按 CP936 读取 stdin。中文 JSON-RPC 被读坏后，服务端返回的是：

`id=null / -32700 Parse error`

客户端还在等原来的请求 id，所以表现为“工具卡死”。

最终修法没有继续依赖 Console 编码设置，而是：

1. 直接读 stdin 原始字节；
2. 按 LF 分帧；
3. 显式用 UTF-8 解码；
4. `deepseek_start` 立即返回 `job_id`；
5. 后台跑 DeepSeek SSE，用 `deepseek_poll` 每 5 秒显示阶段。

我把安装器、Codex Skill、无 API 回归测试、真实流式测试和 GitHub Actions 都整理开源了。

回归标准不是“版本号看起来对”，而是中文请求必须保留 `id=2` 并进入方法分派。旧版会稳定复现 `id=null / -32700`，修复版通过。

GitHub：Master-1st/codex-deepseek-visible-stream

如果你也在 Windows 上给 Codex 接 DeepSeek，并遇到中文提示词卡住，可以直接用这个 Skill。安装后记得完全退出并重启 Codex，旧 MCP 进程不会自动重载。

# 标签

#Codex #DeepSeek #MCP #PowerShell #UTF8 #AI编程 #开源项目 #Windows开发 #程序员日常 #Debug
