param()

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$codexHome = if ($env:CODEX_HOME) {
    $env:CODEX_HOME
} else {
    Join-Path $env:USERPROFILE '.codex'
}

$serverPath = Join-Path $codexHome 'deepseek-mcp\server.ps1'

if (-not (Test-Path -LiteralPath $serverPath -PathType Leaf)) {
    throw "Missing MCP server: $serverPath"
}

function Send-Utf8JsonLine {
    param(
        [Parameter(Mandatory = $true)]
        [System.IO.Stream]$Stream,

        [Parameter(Mandatory = $true)]
        [System.Text.Encoding]$Encoding,

        [Parameter(Mandatory = $true)]
        [string]$Json
    )

    $bytes = $Encoding.GetBytes($Json + "`n")
    $Stream.Write($bytes, 0, $bytes.Length)
    $Stream.Flush()
}

function Read-JsonRpcResponse {
    param(
        [Parameter(Mandatory = $true)]
        [System.IO.StreamReader]$Reader,

        [Parameter(Mandatory = $true)]
        [int]$Id,

        [int]$TimeoutSeconds = 5
    )

    $deadline = [DateTime]::UtcNow.AddSeconds($TimeoutSeconds)
    $readTask = $Reader.ReadLineAsync()

    while ([DateTime]::UtcNow -lt $deadline) {
        $remainingMilliseconds = [int][Math]::Max(
            1,
            [Math]::Min(
                500,
                ($deadline - [DateTime]::UtcNow).TotalMilliseconds
            )
        )

        if (-not $readTask.Wait($remainingMilliseconds)) {
            continue
        }

        $line = $readTask.Result
        if ($null -eq $line) {
            throw 'MCP server closed stdout before returning the requested response.'
        }

        try {
            $candidate = ([string]$line) | ConvertFrom-Json

            if (
                ($null -ne $candidate.id) -and
                ([string]$candidate.id -eq [string]$Id)
            ) {
                return $candidate
            }
        }
        catch {}

        $readTask = $Reader.ReadLineAsync()
    }

    throw "Timed out waiting for JSON-RPC response id=$Id."
}

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
Write-Host "MCP server under test: $serverPath"
$utf8NoBom = New-Object System.Text.UTF8Encoding($false)
$utf8Reader = New-Object System.IO.StreamReader(
    $process.StandardOutput.BaseStream,
    $utf8NoBom,
    $false,
    4096,
    $true
)

try {
    $initialize = '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-06-18","capabilities":{},"clientInfo":{"name":"stream-test","version":"1.1"}}}'
    $initialized = '{"jsonrpc":"2.0","method":"notifications/initialized","params":{}}'
    $cjkPrompt = [string]::Concat(
        [char]0x4E2D,
        [char]0x6587,
        [char]0x77ED,
        [char]0x63D0,
        [char]0x793A
    )
    $start = [ordered]@{
        jsonrpc = '2.0'
        id = 2
        method = 'tools/call'
        params = [ordered]@{
            name = 'deepseek_start'
            arguments = [ordered]@{
                prompt = $cjkPrompt
                system_prompt = 'Return exactly: STREAM_UTF8_OK'
                task_type = 'quick_check'
                complexity = 'routine'
                priority = 'latency'
                model = 'deepseek-v4-flash'
                reasoning_effort = 'high'
                thinking = $false
                max_tokens = 256
            }
        }
    } | ConvertTo-Json -Depth 8 -Compress

    Send-Utf8JsonLine -Stream $process.StandardInput.BaseStream -Encoding $utf8NoBom -Json $initialize
    $null = Read-JsonRpcResponse -Reader $utf8Reader -Id 1 -TimeoutSeconds 5
    Send-Utf8JsonLine -Stream $process.StandardInput.BaseStream -Encoding $utf8NoBom -Json $initialized

    $startWatch = [Diagnostics.Stopwatch]::StartNew()
    Send-Utf8JsonLine -Stream $process.StandardInput.BaseStream -Encoding $utf8NoBom -Json $start
    $startResponse = Read-JsonRpcResponse -Reader $utf8Reader -Id 2 -TimeoutSeconds 5
    $startWatch.Stop()

    $startText = [string]$startResponse.result.content[0].text
    Write-Host $startText -ForegroundColor Cyan
    Write-Host "deepseek_start latency: $($startWatch.ElapsedMilliseconds) ms"

    if ($startWatch.ElapsedMilliseconds -ge 3000) {
        throw "deepseek_start exceeded the 3-second latency budget."
    }

    $match = [regex]::Match(
        $startText,
        'job_id=([0-9]{14}-[a-f0-9]{12})'
    )

    if (-not $match.Success) {
        throw 'Could not parse job_id.'
    }

    $jobId = $match.Groups[1].Value

    for ($i = 1; $i -le 60; $i++) {
        Start-Sleep -Seconds 1

        $pollJson = (
            '{"jsonrpc":"2.0","id":3,"method":"tools/call","params":' +
            '{"name":"deepseek_poll","arguments":{"job_id":"' +
            $jobId +
            '","wait_seconds":0}}}'
        )

        Send-Utf8JsonLine -Stream $process.StandardInput.BaseStream -Encoding $utf8NoBom -Json $pollJson
        $pollResponse = Read-JsonRpcResponse `
            -Reader $utf8Reader `
            -Id 3 `
            -TimeoutSeconds 5
        $pollText = [string]$pollResponse.result.content[0].text

        if (-not [string]::IsNullOrWhiteSpace($pollText)) {
            Write-Host ''
            Write-Host $pollText
        }

        if ($pollText -match 'DeepSeek JOB COMPLETED') {
            if ($pollText -notmatch 'STREAM_UTF8_OK') {
                throw 'DeepSeek completed, but the expected UTF-8 test answer was missing.'
            }

            Write-Host ''
            Write-Host 'Visible streaming UTF-8 test PASSED.' -ForegroundColor Green
            exit 0
        }

        if ($pollText -match 'DeepSeek JOB FAILED') {
            throw 'Visible streaming job failed.'
        }

        if ($pollText -match 'DeepSeek JOB INCOMPLETE') {
            throw 'Visible streaming job exhausted its output budget.'
        }
    }

    throw 'Visible streaming test timed out after 60 seconds.'
}
finally {
    try { $utf8Reader.Dispose() } catch {}
    try { $process.StandardInput.Close() } catch {}

    if (-not $process.HasExited) {
        $process.Kill()
        $process.WaitForExit()
    }

    $process.Dispose()
}
