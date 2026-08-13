---
name: deepseek-visible-stream
description: Install, repair, validate, and operate a visible asynchronous DeepSeek V4 MCP worker for Codex on Windows PowerShell 5.1. Use when users ask to connect DeepSeek V4 Pro or Flash, add deepseek_start/deepseek_poll streaming, check DeepSeek connectivity, fix Chinese or CJK prompt hangs, diagnose JSON-RPC id=null / -32700 Parse error, correct CP936-versus-UTF-8 stdin handling, or install/upgrade DeepSeek Visible Stream Hotfix 3.3.
---

# DeepSeek Visible Stream

Use the bundled scripts to install and verify a Windows stdio MCP server that starts DeepSeek SSE jobs immediately, exposes visible polling, and decodes JSON-RPC stdin from raw UTF-8 bytes.

Keep Sol or the current primary agent responsible for scope, synthesis, local verification, and the final answer. Treat DeepSeek as an independent specialist.

## Workflow

1. Confirm the host is Windows and the MCP command uses Windows PowerShell 5.1 (`powershell.exe`).
2. Run the no-API UTF-8 regression before changing files when an existing server is available:

   ```powershell
   powershell.exe -NoProfile -ExecutionPolicy Bypass -File scripts\Test-Utf8-Input-Regression.ps1
   ```

   A healthy server preserves `id=2` and reaches method dispatch. The affected implementation returns `id=null` with JSON-RPC error `-32700`.
3. Install or upgrade with the bundled installer. It backs up the existing server, worker, and Codex config before writing:

   ```powershell
   $env:DEEPSEEK_INSTALL_NO_GUI = '1'
   powershell.exe -NoProfile -ExecutionPolicy Bypass -File scripts\Install-DeepSeek-Visible-Stream-Hotfix3.ps1
   ```

   For an interactive install, run `scripts\Install-DeepSeek-Visible-Stream-Hotfix3.cmd`.
4. Fully exit and restart Codex or ChatGPT. MCP servers are long-lived; replacing the file does not reload the already-running process.
5. Re-run `Test-Utf8-Input-Regression.ps1` in an ordinary user process. Do not treat a version string alone as proof.
6. Check API connectivity with `deepseek_status`.
7. Run the real streaming integration test when a configured API key and one low-cost call are acceptable:

   ```powershell
   powershell.exe -NoProfile -ExecutionPolicy Bypass -File scripts\Test-DeepSeek-Visible-Streaming.ps1
   ```

## Operate DeepSeek visibly

For work that may exceed a few seconds:

1. Call `deepseek_start` with a self-contained prompt, explicit model, reasoning effort, and token limit.
2. Report the returned `job_id` immediately.
3. Call `deepseek_poll(job_id, wait_seconds=5)` until the state is terminal.
4. Give compact updates when `phase` changes or roughly every 10-15 seconds.
5. On `completed`, independently verify and synthesize the result.
6. On `failed`, report the worker error exactly enough to diagnose it; do not silently retry expensive calls.

Prefer `deepseek_start` plus `deepseek_poll` over synchronous `deepseek_consult` for long work.

## Diagnose

- `id=null`, `code=-32700`, or Chinese-only hangs: verify the server reads raw stdin bytes until LF and decodes with `UTF8Encoding(false)`. Do not rely on PowerShell's default console code page.
- `deepseek_start` times out and no job directory appears: the request did not reach `New-DeepSeekJob`; inspect MCP process reload, stdio transport, and active server path.
- Version mismatch: reinstall, then fully restart the app. Hotfix 3.3 reports `3.3.3-0813-hotfix3-utf8-raw`.
- `deepseek_status` fails: check `DEEPSEEK_API_KEY`, `DEEPSEEK_NETWORK_MODE`, proxy settings, TLS, and the returned HTTP error without printing credentials.
- A job exists but fails: inspect its `state.json` and worker error. Separate transport parsing from API/SSE failures.

## Safety and verification

- Never print, copy, or commit `DEEPSEEK_API_KEY`.
- Preserve unrelated `config.toml` content. The installer updates only its tagged MCP block.
- Do not broadly kill every PowerShell process. Identify exact worker or MCP PIDs first.
- Do not expose raw `reasoning_content`; report phase and character counts.
- Treat `scripts/source/server.ps1` and `scripts/source/stream-worker.ps1` as audit copies. The installer is the tested deployment entry point.
- Require a passing raw UTF-8 regression after every input-path change.
