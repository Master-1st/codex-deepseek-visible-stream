param(
    [string]$TargetServerPath = ''
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$selectedServerPath = if (-not [string]::IsNullOrWhiteSpace($TargetServerPath)) {
    (Resolve-Path -LiteralPath $TargetServerPath).Path
} else {
    Join-Path $PSScriptRoot 'source\server.ps1'
}

if (-not (Test-Path -LiteralPath $selectedServerPath -PathType Leaf)) {
    throw "Missing server under test: $selectedServerPath"
}

$selectedWorkerPath = Join-Path (
    Split-Path -Parent $selectedServerPath
) 'stream-worker.ps1'

if (-not (Test-Path -LiteralPath $selectedWorkerPath -PathType Leaf)) {
    throw "Missing worker paired with server: $selectedWorkerPath"
}

function Assert-True {
    param(
        [bool]$Condition,
        [string]$Message
    )

    if (-not $Condition) {
        throw $Message
    }
}

function Send-Utf8JsonLine {
    param(
        [System.IO.Stream]$Stream,
        [System.Text.Encoding]$Encoding,
        [string]$Json
    )

    $bytes = $Encoding.GetBytes($Json + "`n")
    $Stream.Write($bytes, 0, $bytes.Length)
    $Stream.Flush()
}

function Read-JsonRpcResponse {
    param(
        [System.IO.StreamReader]$Reader,
        [int]$Id,
        [int]$TimeoutSeconds = 5
    )

    $deadline = [DateTime]::UtcNow.AddSeconds($TimeoutSeconds)
    $readTask = $Reader.ReadLineAsync()

    while ([DateTime]::UtcNow -lt $deadline) {
        if (-not $readTask.Wait(250)) {
            continue
        }

        $line = $readTask.Result

        if ($null -eq $line) {
            throw 'MCP server closed stdout before returning a response.'
        }

        try {
            $candidate = ([string]$line) | ConvertFrom-Json

            if ([string]$candidate.id -eq [string]$Id) {
                return $candidate
            }
        }
        catch {}

        $readTask = $Reader.ReadLineAsync()
    }

    throw "Timed out waiting for JSON-RPC response id=$Id."
}

function New-TestState {
    param(
        [string]$JobId,
        [string]$Status,
        [string]$Phase,
        [string]$FinishReason,
        [int]$AnswerChars
    )

    return [ordered]@{
        seq = 10
        job_id = $JobId
        status = $Status
        phase = $Phase
        model = 'deepseek-v4-pro'
        effort = 'max'
        network_mode = 'direct'
        reasoning_chars = 2000
        answer_chars = $AnswerChars
        elapsed_ms = 1200
        keepalive_count = 1
        message = 'Synthetic control-plane state.'
        pid = $null
        started_at = '2026-08-13T00:00:00Z'
        updated_at = '2026-08-13T00:00:01Z'
        finish_reason = $FinishReason
        max_tokens = 65536
        max_tokens_explicit = $false
        final_answer_max_chars = 12000
        prompt_tokens = 100
        completion_tokens = 65000
        reasoning_tokens = 60000
        total_tokens = 65100
        error = $(if ($Status -eq 'incomplete') { 'finish_reason=length' } else { '' })
    }
}

$tempRoot = Join-Path (
    [IO.Path]::GetTempPath()
) ('deepseek-router-contract-' + [Guid]::NewGuid().ToString('N'))
$utf8NoBom = New-Object System.Text.UTF8Encoding($false)
$process = $null
$reader = $null

try {
    New-Item -ItemType Directory -Path $tempRoot -Force | Out-Null
    $serverPath = Join-Path $tempRoot 'server.ps1'
    $workerPath = Join-Path $tempRoot 'stream-worker.ps1'
    Copy-Item -LiteralPath $selectedServerPath -Destination $serverPath -Force
    [IO.File]::WriteAllText(
        $workerPath,
        "param([string]`$JobDirectory)`r`n",
        $utf8NoBom
    )

    $jobsRoot = Join-Path $tempRoot 'jobs'
    New-Item -ItemType Directory -Path $jobsRoot -Force | Out-Null

    $incompleteJobId = '20260813000000-abcdef123456'
    $incompleteJobRoot = Join-Path $jobsRoot $incompleteJobId
    New-Item -ItemType Directory -Path $incompleteJobRoot -Force | Out-Null
    $longAnswer = 'A' * 30000
    [IO.File]::WriteAllText(
        (Join-Path $incompleteJobRoot 'answer.txt'),
        $longAnswer,
        $utf8NoBom
    )
    [IO.File]::WriteAllText(
        (Join-Path $incompleteJobRoot 'state.json'),
        ((New-TestState `
            -JobId $incompleteJobId `
            -Status 'incomplete' `
            -Phase 'incomplete' `
            -FinishReason 'length' `
            -AnswerChars $longAnswer.Length) | ConvertTo-Json -Depth 8 -Compress),
        $utf8NoBom
    )

    $completedJobId = '20260813000001-fedcba654321'
    $completedJobRoot = Join-Path $jobsRoot $completedJobId
    New-Item -ItemType Directory -Path $completedJobRoot -Force | Out-Null
    [IO.File]::WriteAllText(
        (Join-Path $completedJobRoot 'answer.txt'),
        'COMPLETE_OK',
        $utf8NoBom
    )
    [IO.File]::WriteAllText(
        (Join-Path $completedJobRoot 'state.json'),
        ((New-TestState `
            -JobId $completedJobId `
            -Status 'completed' `
            -Phase 'completed' `
            -FinishReason 'stop' `
            -AnswerChars 11) | ConvertTo-Json -Depth 8 -Compress),
        $utf8NoBom
    )

    $runningJobId = '20260813000002-123456abcdef'
    $runningJobRoot = Join-Path $jobsRoot $runningJobId
    New-Item -ItemType Directory -Path $runningJobRoot -Force | Out-Null
    [IO.File]::WriteAllText(
        (Join-Path $runningJobRoot 'state.json'),
        ((New-TestState `
            -JobId $runningJobId `
            -Status 'running' `
            -Phase 'thinking' `
            -FinishReason '' `
            -AnswerChars 0) | ConvertTo-Json -Depth 8 -Compress),
        $utf8NoBom
    )

    $startInfo = New-Object System.Diagnostics.ProcessStartInfo
    $startInfo.FileName = 'powershell.exe'
    $startInfo.Arguments = (
        '-NoLogo -NoProfile -NonInteractive -ExecutionPolicy Bypass -File ' +
        '"' + $serverPath + '"'
    )
    $startInfo.UseShellExecute = $false
    $startInfo.CreateNoWindow = $true
    $startInfo.RedirectStandardInput = $true
    $startInfo.RedirectStandardOutput = $true
    $startInfo.RedirectStandardError = $true

    $process = New-Object System.Diagnostics.Process
    $process.StartInfo = $startInfo
    [void]$process.Start()
    $reader = New-Object System.IO.StreamReader(
        $process.StandardOutput.BaseStream,
        $utf8NoBom,
        $false,
        4096,
        $true
    )

    $initialize = [ordered]@{
        jsonrpc = '2.0'
        id = 1
        method = 'initialize'
        params = [ordered]@{
            protocolVersion = '2025-06-18'
            capabilities = [ordered]@{}
            clientInfo = [ordered]@{
                name = 'router-contract-test'
                version = '1.0'
            }
        }
    } | ConvertTo-Json -Depth 8 -Compress

    Send-Utf8JsonLine `
        -Stream $process.StandardInput.BaseStream `
        -Encoding $utf8NoBom `
        -Json $initialize
    $initializeResponse = Read-JsonRpcResponse -Reader $reader -Id 1

    Assert-True `
        -Condition ([string]$initializeResponse.result.serverInfo.version -eq '3.4.0-0813-codex-router-budget') `
        -Message 'Unexpected MCP server version.'
    Assert-True `
        -Condition ([string]$initializeResponse.result.instructions -match 'Route mathematics') `
        -Message 'Routing instructions are missing.'
    Assert-True `
        -Condition ([string]$initializeResponse.result.instructions -match 'wait_seconds=30') `
        -Message '30-second polling instructions are missing.'

    $listRequest = '{"jsonrpc":"2.0","id":2,"method":"tools/list","params":{}}'
    Send-Utf8JsonLine `
        -Stream $process.StandardInput.BaseStream `
        -Encoding $utf8NoBom `
        -Json $listRequest
    $listResponse = Read-JsonRpcResponse -Reader $reader -Id 2
    $tools = @($listResponse.result.tools)
    $toolNames = @($tools | ForEach-Object { [string]$_.name })
    Assert-True `
        -Condition ('deepseek_read' -in $toolNames) `
        -Message 'deepseek_read is missing from tools/list.'

    $pollTool = $tools | Where-Object { $_.name -eq 'deepseek_poll' } | Select-Object -First 1
    $pollWait = $pollTool.inputSchema.properties.wait_seconds
    Assert-True `
        -Condition (([int]$pollWait.default -eq 30) -and ([int]$pollWait.maximum -eq 30)) `
        -Message 'deepseek_poll must default to and cap at 30 seconds.'

    $startTool = $tools | Where-Object { $_.name -eq 'deepseek_start' } | Select-Object -First 1
    $maxTokens = $startTool.inputSchema.properties.max_tokens
    Assert-True `
        -Condition ([int]$maxTokens.maximum -eq 384000) `
        -Message 'max_tokens schema cap is not 384000.'
    Assert-True `
        -Condition ($null -eq $maxTokens.PSObject.Properties['default']) `
        -Message 'max_tokens must be optional so automatic budgeting can run.'
    $finalChars = $startTool.inputSchema.properties.final_answer_max_chars
    Assert-True `
        -Condition (([int]$finalChars.default -eq 12000) -and ([int]$finalChars.maximum -eq 60000)) `
        -Message 'final_answer_max_chars schema is incorrect.'

    $mathStart = [ordered]@{
        jsonrpc = '2.0'
        id = 6
        method = 'tools/call'
        params = [ordered]@{
            name = 'deepseek_start'
            arguments = [ordered]@{
                prompt = 'Analyze a synthetic math task.'
                task_type = 'math'
                complexity = 'complex'
                priority = 'balanced'
                model = 'auto'
                reasoning_effort = 'auto'
                thinking = $true
            }
        }
    } | ConvertTo-Json -Depth 8 -Compress
    Send-Utf8JsonLine `
        -Stream $process.StandardInput.BaseStream `
        -Encoding $utf8NoBom `
        -Json $mathStart
    $mathResponse = Read-JsonRpcResponse -Reader $reader -Id 6
    $mathText = [string]$mathResponse.result.content[0].text
    Assert-True `
        -Condition (
            ($mathText -match 'model=deepseek-v4-pro') -and
            ($mathText -match 'effort=max') -and
            ($mathText -match 'max_tokens=65536') -and
            ($mathText -match 'max_tokens_explicit=False')
        ) `
        -Message 'Auto routing did not select Pro/max with a 64K budget for math.'

    $flashStart = [ordered]@{
        jsonrpc = '2.0'
        id = 7
        method = 'tools/call'
        params = [ordered]@{
            name = 'deepseek_start'
            arguments = [ordered]@{
                prompt = 'Run a synthetic low-cost check.'
                task_type = 'quick_check'
                complexity = 'routine'
                priority = 'cost'
                model = 'auto'
                reasoning_effort = 'auto'
                thinking = $false
            }
        }
    } | ConvertTo-Json -Depth 8 -Compress
    Send-Utf8JsonLine `
        -Stream $process.StandardInput.BaseStream `
        -Encoding $utf8NoBom `
        -Json $flashStart
    $flashResponse = Read-JsonRpcResponse -Reader $reader -Id 7
    $flashText = [string]$flashResponse.result.content[0].text
    Assert-True `
        -Condition (
            ($flashText -match 'model=deepseek-v4-flash') -and
            ($flashText -match 'max_tokens=16384') -and
            ($flashText -match 'max_tokens_explicit=False')
        ) `
        -Message 'Auto routing did not select Flash with a 16K non-thinking budget.'

    $chineseWritingStart = [ordered]@{
        jsonrpc = '2.0'
        id = 10
        method = 'tools/call'
        params = [ordered]@{
            name = 'deepseek_start'
            arguments = [ordered]@{
                prompt = 'Draft a synthetic Chinese technical paragraph.'
                task_type = 'chinese_writing'
                complexity = 'routine'
                priority = 'quality'
                model = 'auto'
                reasoning_effort = 'auto'
                thinking = $true
            }
        }
    } | ConvertTo-Json -Depth 8 -Compress
    Send-Utf8JsonLine `
        -Stream $process.StandardInput.BaseStream `
        -Encoding $utf8NoBom `
        -Json $chineseWritingStart
    $chineseWritingResponse = Read-JsonRpcResponse -Reader $reader -Id 10
    $chineseWritingText = [string]$chineseWritingResponse.result.content[0].text
    Assert-True `
        -Condition (
            ($chineseWritingText -match 'model=deepseek-v4-pro') -and
            ($chineseWritingText -match 'effort=high') -and
            ($chineseWritingText -match 'max_tokens=32768')
        ) `
        -Message 'Quality-first Chinese writing did not route to DeepSeek V4 Pro.'

    $explicitBudgetStart = [ordered]@{
        jsonrpc = '2.0'
        id = 8
        method = 'tools/call'
        params = [ordered]@{
            name = 'deepseek_start'
            arguments = [ordered]@{
                prompt = 'Validate explicit output controls.'
                task_type = 'analysis'
                complexity = 'complex'
                priority = 'quality'
                model = 'deepseek-v4-pro'
                reasoning_effort = 'high'
                thinking = $true
                max_tokens = 80000
                final_answer_max_chars = 50000
            }
        }
    } | ConvertTo-Json -Depth 8 -Compress
    Send-Utf8JsonLine `
        -Stream $process.StandardInput.BaseStream `
        -Encoding $utf8NoBom `
        -Json $explicitBudgetStart
    $explicitResponse = Read-JsonRpcResponse -Reader $reader -Id 8
    $explicitText = [string]$explicitResponse.result.content[0].text
    Assert-True `
        -Condition (
            ($explicitText -match 'max_tokens=80000') -and
            ($explicitText -match 'max_tokens_explicit=True') -and
            ($explicitText -match 'final_answer_max_chars=50000')
        ) `
        -Message 'Explicit output budget controls were not preserved.'

    $timedPoll = [ordered]@{
        jsonrpc = '2.0'
        id = 9
        method = 'tools/call'
        params = [ordered]@{
            name = 'deepseek_poll'
            arguments = [ordered]@{
                job_id = $runningJobId
                wait_seconds = 1
            }
        }
    } | ConvertTo-Json -Depth 8 -Compress
    $pollWatch = [Diagnostics.Stopwatch]::StartNew()
    Send-Utf8JsonLine `
        -Stream $process.StandardInput.BaseStream `
        -Encoding $utf8NoBom `
        -Json $timedPoll
    $timedResponse = Read-JsonRpcResponse -Reader $reader -Id 9
    $pollWatch.Stop()
    $timedText = [string]$timedResponse.result.content[0].text
    Assert-True `
        -Condition (
            ($pollWatch.ElapsedMilliseconds -ge 750) -and
            ($pollWatch.ElapsedMilliseconds -lt 4000) -and
            ($timedText -match 'DeepSeek JOB RUNNING')
        ) `
        -Message 'Non-terminal long-poll did not honor its requested wait window.'

    $pollIncomplete = [ordered]@{
        jsonrpc = '2.0'
        id = 3
        method = 'tools/call'
        params = [ordered]@{
            name = 'deepseek_poll'
            arguments = [ordered]@{
                job_id = $incompleteJobId
                wait_seconds = 0
            }
        }
    } | ConvertTo-Json -Depth 8 -Compress
    Send-Utf8JsonLine `
        -Stream $process.StandardInput.BaseStream `
        -Encoding $utf8NoBom `
        -Json $pollIncomplete
    $incompleteResponse = Read-JsonRpcResponse -Reader $reader -Id 3
    $incompleteText = [string]$incompleteResponse.result.content[0].text
    Assert-True `
        -Condition ($incompleteText -match 'DeepSeek CALL INCOMPLETE') `
        -Message 'finish_reason=length was not surfaced as incomplete.'
    Assert-True `
        -Condition ($incompleteText -notmatch 'DeepSeek CALL OK') `
        -Message 'Incomplete output was incorrectly reported as CALL OK.'
    Assert-True `
        -Condition ($incompleteText -match 'answer_next_offset=24000') `
        -Message 'Long terminal answer was not chunked at 24000 characters.'

    $readRequest = [ordered]@{
        jsonrpc = '2.0'
        id = 4
        method = 'tools/call'
        params = [ordered]@{
            name = 'deepseek_read'
            arguments = [ordered]@{
                job_id = $incompleteJobId
                offset_chars = 24000
                max_chars = 12000
            }
        }
    } | ConvertTo-Json -Depth 8 -Compress
    Send-Utf8JsonLine `
        -Stream $process.StandardInput.BaseStream `
        -Encoding $utf8NoBom `
        -Json $readRequest
    $readResponse = Read-JsonRpcResponse -Reader $reader -Id 4
    $readText = [string]$readResponse.result.content[0].text
    Assert-True `
        -Condition (($readText -match 'returned_chars=6000') -and ($readText -match 'eof=true')) `
        -Message 'deepseek_read did not return the expected final local chunk.'
    Assert-True `
        -Condition ($readText -match 'api_tokens_charged=0') `
        -Message 'deepseek_read did not identify local zero-API-token retrieval.'

    $pollCompleted = [ordered]@{
        jsonrpc = '2.0'
        id = 5
        method = 'tools/call'
        params = [ordered]@{
            name = 'deepseek_poll'
            arguments = [ordered]@{
                job_id = $completedJobId
                wait_seconds = 0
            }
        }
    } | ConvertTo-Json -Depth 8 -Compress
    Send-Utf8JsonLine `
        -Stream $process.StandardInput.BaseStream `
        -Encoding $utf8NoBom `
        -Json $pollCompleted
    $completedResponse = Read-JsonRpcResponse -Reader $reader -Id 5
    $completedText = [string]$completedResponse.result.content[0].text
    Assert-True `
        -Condition (($completedText -match 'DeepSeek CALL OK') -and ($completedText -match 'COMPLETE_OK')) `
        -Message 'Natural completion was not returned as CALL OK.'

    $workerText = Get-Content -Raw -Encoding UTF8 -LiteralPath $selectedWorkerPath
    Assert-True `
        -Condition ($workerText -match "finish_reason -eq 'length'") `
        -Message 'Worker does not classify finish_reason=length.'
    Assert-True `
        -Condition ($workerText -match "status = 'incomplete'") `
        -Message 'Worker does not emit incomplete status.'

    Write-Host 'DeepSeek Codex Router control-plane contract PASSED.' -ForegroundColor Green
    Write-Host '30-second polling, routing, budgets, incomplete handling, and local paging validated.'
}
finally {
    try {
        if ($null -ne $reader) {
            $reader.Dispose()
        }
    }
    catch {}

    try {
        if (($null -ne $process) -and (-not $process.HasExited)) {
            $process.Kill()
            $process.WaitForExit()
        }
    }
    catch {}

    try {
        if ($null -ne $process) {
            $process.Dispose()
        }
    }
    catch {}

    if (Test-Path -LiteralPath $tempRoot -PathType Container) {
        Remove-Item -LiteralPath $tempRoot -Recurse -Force
    }
}
