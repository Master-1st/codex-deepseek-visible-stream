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
    param(
        [Parameter(Mandatory = $true)][string]$ProbeServerPath,
        [bool]$IncludeBom = $false
    )

    Write-Host "Server under test: $ProbeServerPath"

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
    $requestBytes = [byte[]]$utf8NoBom.GetBytes(
        ($jsonLines -join "`n") + "`n"
    )

    if ($IncludeBom) {
        $utf8Bom = New-Object System.Text.UTF8Encoding($true)
        $requestBytes = [byte[]](
            $utf8Bom.GetPreamble() + $requestBytes
        )
    }
    $requestPath = Join-Path (
        [IO.Path]::GetTempPath()
    ) ('deepseek-utf8-' + [guid]::NewGuid().ToString('N') + '.jsonl')
    [IO.File]::WriteAllBytes($requestPath, $requestBytes)

    # Process.StandardInput can prepend a UTF-8 BOM on some PowerShell 5.1
    # hosts even when its BaseStream is used. File redirection preserves the
    # exact no-BOM bytes that a conforming stdio MCP client sends.
    $powerShellPath = Join-Path $env:WINDIR (
        'System32\WindowsPowerShell\v1.0\powershell.exe'
    )
    $childCommand = (
        '"' + $powerShellPath + '" ' +
        '-NoLogo -NoProfile -NonInteractive -ExecutionPolicy Bypass -File ' +
        '"' + $ProbeServerPath + '" < "' + $requestPath + '"'
    )
    $startInfo = New-Object System.Diagnostics.ProcessStartInfo
    $startInfo.FileName = Join-Path $env:WINDIR 'System32\cmd.exe'
    $startInfo.Arguments = '/d /s /c "' + $childCommand + '"'
    $startInfo.UseShellExecute = $false
    $startInfo.CreateNoWindow = $true
    $startInfo.RedirectStandardOutput = $true
    $startInfo.RedirectStandardError = $true

    $process = New-Object System.Diagnostics.Process
    $process.StartInfo = $startInfo
    [void]$process.Start()

    try {
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
        if (-not $process.HasExited) {
            $process.Kill()
            $process.WaitForExit()
        }

        $process.Dispose()
        Remove-Item -LiteralPath $requestPath -Force -ErrorAction SilentlyContinue
    }
}

if (-not (Test-Path -LiteralPath $selectedServerPath -PathType Leaf)) {
    throw "Missing patched or installed server: $selectedServerPath"
}

foreach ($includeBom in @($false, $true)) {
    $responses = Invoke-Probe `
        -ProbeServerPath $selectedServerPath `
        -IncludeBom $includeBom

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
}

Write-Host 'UTF-8 MCP input regression PASSED.' -ForegroundColor Green
Write-Host 'Chinese JSON-RPC request reached dispatch with and without an optional UTF-8 BOM.'
