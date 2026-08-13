---
name: deepseek-visible-stream
description: Deploy and operate DeepSeek V4 Pro and Flash inside Codex as asynchronous MCP specialists with explicit Sol-Luna-DeepSeek routing, 30-second visible polling, output-budget protection, zero-API-token local answer paging, and Windows PowerShell 5.1 UTF-8 compatibility. Use when users ask Sol to call DeepSeek, install DeepSeek in Codex, route work among Sol, Luna, and DeepSeek, inspect DeepSeek connectivity, avoid truncated long answers, or repair Chinese and CJK MCP input failures.
---

# DeepSeek Codex Router

Deploy DeepSeek V4 inside Codex as a bounded specialist. Keep Sol in control of intent, permissions, planning, integration, verification, and the final answer.

## Route work

- Keep ambiguous requirements, architecture decisions, cross-worker coordination, safety judgments, integration, and the user-facing conclusion with Sol.
- Route local repository inspection, tool execution, mechanical edits, and bounded verifiable work to Luna when available.
- Route routine independent checks, low-cost analysis, and latency-sensitive work to DeepSeek V4 Flash.
- Route mathematics, algorithms, architecture, complex debugging, adversarial review, and critical research to DeepSeek V4 Pro.
- Route Chinese drafting, rewriting, translation, polishing, and summarization to DeepSeek by default. Use Flash for routine text and Pro for academic, quality-first, or critical text; Sol verifies facts and performs the final integration.
- Give DeepSeek a self-contained task packet. It has no implicit access to local files, tools, or conversation history.
- Never create Luna-to-DeepSeek or DeepSeek-to-Luna recursive chains.

## Install and validate

1. Confirm the host is Windows and the MCP command uses Windows PowerShell 5.1 (`powershell.exe`).
2. Install or upgrade with the bundled installer. The legacy Hotfix3 filename is retained for in-place upgrades:

   ```powershell
   $env:DEEPSEEK_INSTALL_NO_GUI = '1'
   powershell.exe -NoProfile -ExecutionPolicy Bypass -File scripts\Install-DeepSeek-Visible-Stream-Hotfix3.ps1
   ```

   For an interactive install, run `scripts\Install-DeepSeek-Visible-Stream-Hotfix3.cmd`.
3. Fully exit and restart Codex or ChatGPT. MCP servers are long-lived; replacing a file does not reload an existing process.
4. Run the no-API regressions:

   ```powershell
   powershell.exe -NoProfile -ExecutionPolicy Bypass -File scripts\Test-Utf8-Input-Regression.ps1
   powershell.exe -NoProfile -ExecutionPolicy Bypass -File scripts\Test-Control-Plane-Contract.ps1
   ```

5. Call `deepseek_status` to validate the configured key and API connectivity.
6. When one low-cost real API call is acceptable, run `scripts\Test-DeepSeek-Visible-Streaming.ps1`.

## Operate visibly

1. Call `deepseek_start` with a self-contained prompt plus task metadata. Prefer `model=auto` so the routing rules select Flash or Pro. Use `task_type=chinese_writing`, `translation`, `polishing`, `writing`, or `summarization` for text work.
2. Report the returned `job_id`, selected model, reasoning effort, and effective budget immediately.
3. Call `deepseek_poll(job_id, wait_seconds=30)` until the state is terminal. Each call waits 30 seconds and returns earlier only when the job completes, fails, is cancelled, or becomes incomplete.
4. Give one compact user update per returned poll. Do not continuously poll between those 30-second windows.
5. On `completed`, independently verify DeepSeek's result and synthesize it as Sol.
6. On `failed`, report the useful worker error and diagnose before retrying.

Prefer `deepseek_start` plus `deepseek_poll` over synchronous `deepseek_consult`.

## Protect output and token spend

- Omit `max_tokens` for normal calls. The router automatically uses 16K with thinking disabled, 32K for high effort, and 64K for max effort. `max_tokens` is a shared hard ceiling for hidden reasoning and final content, so a small explicit value can starve the answer.
- Use `final_answer_max_chars` to request the desired final-answer length. The default is 12,000 characters; the accepted range is 1,000-60,000.
- Treat `status=incomplete` or `finish_reason=length` as incomplete, never as success. Preserve any partial answer. Do not rerun the full reasoning task automatically.
- If missing material is essential, make at most one targeted continuation with `thinking=false`, supplying the partial answer and asking only for the missing sections.
- A terminal poll returns at most 24,000 answer characters. If `answer_eof=false`, call `deepseek_read(job_id, offset_chars=answer_next_offset)` until `eof=true`. `deepseek_read` reads the local answer file, makes no DeepSeek API request, and consumes no DeepSeek tokens.
- When the MCP tool is invoked through Code Mode `functions.exec`, give the terminal poll/read enough host-side capture budget, for example:

  ```javascript
  // @exec: {"yield_time_ms": 35000, "max_output_tokens": 12000}
  const result = await tools.deepseek_poll({job_id, wait_seconds: 30});
  text(result);
  ```

  Host capture size and DeepSeek `max_tokens` are different limits. Use local paging if the host still clips a result.

## Interpret states

- `queued`, `connecting`, `waiting_for_inference`: request setup and API connection.
- `thinking`: DeepSeek is reasoning; expose only counts, never raw `reasoning_content`.
- `answering`: final content is being persisted locally.
- `completed`: natural completion; the answer and usage are ready.
- `incomplete`: the shared output budget ended before a natural stop; partial content is preserved.
- `failed`, `cancelled`: terminal error or explicit cancellation.

## Diagnose compatibility

- `id=null`, `code=-32700`, or Chinese-only hangs: verify the server reads raw stdin bytes through LF and decodes them with UTF-8. Do not rely on the PowerShell 5.1 console code page.
- `deepseek_start` times out and no job directory appears: the request did not reach job creation. Inspect MCP reload, stdio transport, and the active server path.
- Version mismatch: reinstall, fully restart the app, and verify `3.4.0-0813-codex-router-budget`.
- `deepseek_status` fails: inspect `DEEPSEEK_NETWORK_MODE`, proxy/TLS configuration, and the returned HTTP error without printing credentials.

## Safety

- Never print, copy, or commit `DEEPSEEK_API_KEY`.
- Preserve unrelated `config.toml` content. The installer updates only its tagged MCP block.
- Do not broadly terminate PowerShell processes. Identify exact MCP or worker PIDs first.
- Do not expose raw reasoning content. Counts and phase are sufficient.
- Treat `scripts/source/server.ps1` and `scripts/source/stream-worker.ps1` as audit copies; the installer is the deployment entry point.
