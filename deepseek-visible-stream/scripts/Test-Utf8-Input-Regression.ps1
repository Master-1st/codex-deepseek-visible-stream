param(
    [string]$TargetServerPath = ''
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$codexHome = if ($env:CODEX_HOME) {
    $env:CODEX_HOME
} else {
    Join-Path $env:USERPROFILE '.codex'
}
$installedServerPath = Join-Path $codexHome 'deepseek-mcp\server.ps1'
$selectedServerPath = if (-not [string]::IsNullOrWhiteSpace($TargetServerPath)) {
    $TargetServerPath
} elseif (Test-Path -LiteralPath $installedServerPath -PathType Leaf) {
    $installedServerPath
} else {
    Join-Path $PSScriptRoot 'server.ps1'
}

function Invoke-Probe {
    param([Parameter(Mandatory = $true)][string]$ProbeServerPath)

    Write-Host "Server under test: $ProbeServerPath"

    $startInfo = New-Object System.Diagnostics.ProcessStartInfo
    $startInfo.FileName = 'powershell.exe'
    $startInfo.Arguments = (
        '-NoLogo -NoProfile -NonInteractive -ExecutionPolicy Bypass -File ' +
        '"' + $ProbeServerPath + '"'
    )
    $startInfo.UseShellExecute = $false
    $startInfo.CreateNoWindow = $true
    $startInfo.RedirectStandardInput = $true
    $startInfo.RedirectStandardOutput = $true
    $startInfo.RedirectStandardError = $true

    $process = New-Object System.Diagnostics.Process
    $process.StartInfo = $startInfo
    [void]$process.Start()

    try {
        $cjkPrompt = [string]::Concat(
            [char]0x4E2D,
            [char]0x6587,
            [char]0x77ED,
            [char]0x63D0,
            [char]0x793A
        )
        $messages = @(
            [ordered]@{
                jsonrpc = '2.0'
                id = 2
                method = 'not_a_real_method'
                params = [ordered]@{ prompt = $cjkPrompt }
            }
        )
        $jsonLines = $messages | ForEach-Object {
            $_ | ConvertTo-Json -Depth 8 -Compress
        }
        $utf8NoBom = New-Object System.Text.UTF8Encoding($false)
        $requestBytes = $utf8NoBom.GetBytes(
            ($jsonLines -join "`n") + "`n"
        )
        $process.StandardInput.BaseStream.Write(
            $requestBytes,
            0,
            $requestBytes.Length
        )
        $process.StandardInput.BaseStream.Flush()

        $responses = New-Object System.Collections.Generic.List[object]
        $deadline = [DateTime]::UtcNow.AddSeconds(5)
        $readTask = $process.StandardOutput.ReadLineAsync()

        while (
            ([DateTime]::UtcNow -lt $deadline) -and
            ($responses.Count -lt 1)
        ) {
            if (-not $readTask.Wait(250)) {
                continue
            }

            $line = $readTask.Result

            if ($null -eq $line) {
                break
            }

            try {
                $responses.Add(($line | ConvertFrom-Json))
            }
            catch {}

            $readTask = $process.StandardOutput.ReadLineAsync()
        }

        return ,$responses.ToArray()
    }
    finally {
        try { $process.StandardInput.Close() } catch {}

        if (-not $process.HasExited) {
            $process.Kill()
            $process.WaitForExit()
        }

        $process.Dispose()
    }
}

if (-not (Test-Path -LiteralPath $selectedServerPath -PathType Leaf)) {
    throw "Missing patched or installed server: $selectedServerPath"
}

$responses = Invoke-Probe -ProbeServerPath $selectedServerPath

if ($responses.Count -ne 1) {
    throw "Expected 1 JSON-RPC response, got $($responses.Count)."
}

$dispatchResponse = $responses | Where-Object {
    [string]$_.id -eq '2'
} | Select-Object -First 1

if (
    ($null -eq $dispatchResponse) -or
    ([int]$dispatchResponse.error.code -ne -32601)
) {
    throw (
        'UTF-8 request was not parsed correctly. Expected id=2 and ' +
        'error=-32601, received: ' +
        ($responses | ConvertTo-Json -Depth 8 -Compress)
    )
}

Write-Host 'UTF-8 MCP input regression PASSED.' -ForegroundColor Green
Write-Host 'Chinese JSON-RPC request preserved id=2 and reached dispatch.'
