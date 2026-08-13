# Codex DeepSeek Visible Stream

[English summary](#english-summary)

让 Codex 在 Windows 上以“立即返回 `job_id` + 后台 DeepSeek SSE + 可见轮询”的方式调用 DeepSeek V4，并修复中文提示词导致 MCP 工具长期卡住的问题。

## 修复了什么

Windows PowerShell 5.1 的标准输入常使用系统代码页（中文环境通常是 CP936），而 Codex 的 stdio MCP 请求是 UTF-8。旧实现直接调用 `[Console]::In.ReadLine()`，中文 JSON-RPC 可能被破坏成：

```text
id=null
error.code=-32700
message=Parse error
```

客户端仍在等待原请求的 `id`，于是表面上像 DeepSeek 推理卡住，实际请求根本没有进入任务创建函数。

Hotfix 3.3 直接读取 stdin 原始字节，按 LF 分帧，再用 UTF-8 解码。服务端版本：`3.3.3-0813-hotfix3-utf8-raw`。

```mermaid
flowchart LR
    A["Codex UTF-8 JSON-RPC"] --> B["raw stdin bytes"]
    B --> C["split on LF"]
    C --> D["UTF-8 decode"]
    D --> E["deepseek_start"]
    E --> F["job_id immediately"]
    F --> G["background SSE worker"]
    G --> H["deepseek_poll every 5s"]
```

## 内容

- `deepseek-visible-stream/SKILL.md`：可被 Codex 自动触发的 Skill 工作流。
- `scripts/Install-DeepSeek-Visible-Stream-Hotfix3.ps1`：带备份的安装/升级器。
- `scripts/Test-Utf8-Input-Regression.ps1`：不调用 API 的原始 UTF-8 回归。
- `scripts/Test-DeepSeek-Visible-Streaming.ps1`：真实低成本流式集成测试。
- `scripts/source/`：解码后的服务端与 worker 审计副本。

## 安装 Skill

```powershell
git clone https://github.com/Master-1st/codex-deepseek-visible-stream.git
$skillRoot = Join-Path $env:USERPROFILE '.codex\skills\deepseek-visible-stream'
New-Item -ItemType Directory -Force -Path $skillRoot | Out-Null
Copy-Item -Recurse -Force `
  '.\codex-deepseek-visible-stream\deepseek-visible-stream\*' `
  $skillRoot
```

完全退出并重启 Codex，使新 Skill 生效。

## 安装 MCP Hotfix

交互式：

```powershell
.\codex-deepseek-visible-stream\deepseek-visible-stream\scripts\Install-DeepSeek-Visible-Stream-Hotfix3.cmd
```

自动化：

```powershell
$env:DEEPSEEK_INSTALL_NO_GUI = '1'
powershell.exe -NoProfile -ExecutionPolicy Bypass -File `
  '.\codex-deepseek-visible-stream\deepseek-visible-stream\scripts\Install-DeepSeek-Visible-Stream-Hotfix3.ps1'
```

安装器会先备份现有 `server.ps1`、`stream-worker.ps1` 和 `config.toml`，只替换带标签的 DeepSeek MCP 配置块，不会修改聊天记录或 Luna Worker。它会把用户级 `DEEPSEEK_NETWORK_MODE` 设置为 `direct`；若检测到 `~/.agents/skills/sol-multi-worker-orchestrator/SKILL.md`，还会幂等更新其中的 `DEEPSEEK_VISIBLE_STREAM` 标记块。

## 验证

先跑不调用 DeepSeek API 的回归：

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File `
  '.\codex-deepseek-visible-stream\deepseek-visible-stream\scripts\Test-Utf8-Input-Regression.ps1'
```

通过标准：

```text
UTF-8 MCP input regression PASSED.
Chinese JSON-RPC request preserved id=2 and reached dispatch.
```

然后完全退出并重启 Codex，再调用 `deepseek_status`。配置了 `DEEPSEEK_API_KEY` 后，可选择运行真实流式测试。

## 安全

- 不包含或打印 DeepSeek API Key。
- 不要把 `.codex` 配置、job 请求文件或日志提交到公开仓库。
- 不要批量终止所有 PowerShell 进程；需要取消时只处理已确认的 MCP/worker PID。
- 不展示 DeepSeek 原始 `reasoning_content`，仅报告阶段与字符数。

## English summary

This Codex Skill installs and validates an asynchronous DeepSeek V4 MCP worker for Windows. It fixes CJK JSON-RPC hangs caused by PowerShell 5.1 decoding UTF-8 stdin with a legacy system code page. Hotfix 3.3 reads raw stdin bytes, splits on LF, decodes UTF-8 explicitly, returns a `job_id` immediately, and exposes progress through `deepseek_poll`.

## License

MIT
