param(
    [Parameter(Mandatory = $true)]
    [string]$JobDirectory
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
Add-Type -AssemblyName System.Net.Http

$utf8NoBom = New-Object System.Text.UTF8Encoding($false)

function Write-TextAtomic {
    param(
        [string]$Path,
        [string]$Text
    )

    $tempPath = $Path + '.tmp.' + [Guid]::NewGuid().ToString('N')
    [IO.File]::WriteAllText($tempPath, $Text, $utf8NoBom)

    for ($attempt = 1; $attempt -le 5; $attempt++) {
        try {
            Move-Item -LiteralPath $tempPath -Destination $Path -Force
            return
        }
        catch {
            if ($attempt -eq 5) {
                throw
            }

            Start-Sleep -Milliseconds 30
        }
    }
}

function Write-State {
    param(
        [hashtable]$State
    )

    $State.updated_at = (Get-Date).ToUniversalTime().ToString('o')
    $State.seq = [int]$State.seq + 1

    $json = $State | ConvertTo-Json -Depth 12 -Compress
    Write-TextAtomic -Path (Join-Path $JobDirectory 'state.json') -Text $json
}

function Get-UserEnvironmentValue {
    param(
        [string]$Name,
        [string]$DefaultValue = ''
    )

    $value = [Environment]::GetEnvironmentVariable($Name)

    if ([string]::IsNullOrWhiteSpace($value)) {
        $value = [Environment]::GetEnvironmentVariable(
            $Name,
            [EnvironmentVariableTarget]::User
        )
    }

    if ([string]::IsNullOrWhiteSpace($value)) {
        return $DefaultValue
    }

    return [string]$value
}

function Get-DeepSeekKey {
    $key = Get-UserEnvironmentValue -Name 'DEEPSEEK_API_KEY' -DefaultValue ''

    if ([string]::IsNullOrWhiteSpace($key)) {
        throw 'DEEPSEEK_API_KEY is not configured.'
    }

    return $key
}

function Get-NetworkMode {
    $mode = (
        Get-UserEnvironmentValue `
            -Name 'DEEPSEEK_NETWORK_MODE' `
            -DefaultValue 'direct'
    ).Trim().ToLowerInvariant()

    if ($mode -notin @('direct', 'system', 'proxy')) {
        throw "Invalid DEEPSEEK_NETWORK_MODE='$mode'."
    }

    return $mode
}

function New-HttpContext {
    param([int]$TimeoutSeconds)

    $mode = Get-NetworkMode
    $handler = New-Object System.Net.Http.HttpClientHandler

    switch ($mode) {
        'direct' {
            $handler.UseProxy = $false
        }

        'system' {
            $handler.UseProxy = $true
        }

        'proxy' {
            $proxyUrl = Get-UserEnvironmentValue `
                -Name 'DEEPSEEK_PROXY_URL' `
                -DefaultValue ''

            if ([string]::IsNullOrWhiteSpace($proxyUrl)) {
                throw 'DEEPSEEK_NETWORK_MODE=proxy but DEEPSEEK_PROXY_URL is empty.'
            }

            $handler.UseProxy = $true
            $handler.Proxy = New-Object System.Net.WebProxy($proxyUrl, $true)
        }
    }

    $client = New-Object System.Net.Http.HttpClient($handler)
    $client.Timeout = [TimeSpan]::FromSeconds($TimeoutSeconds)

    return [pscustomobject]@{
        Mode = $mode
        Handler = $handler
        Client = $client
    }
}

function Dispose-HttpContext {
    param($Context)

    if ($null -eq $Context) {
        return
    }

    try {
        if ($null -ne $Context.Client) {
            $Context.Client.Dispose()
        }
    }
    catch {}

    try {
        if ($null -ne $Context.Handler) {
            $Context.Handler.Dispose()
        }
    }
    catch {}
}

$state = @{
    seq = 0
    job_id = [IO.Path]::GetFileName($JobDirectory)
    status = 'running'
    phase = 'starting'
    model = ''
    effort = ''
    network_mode = ''
    reasoning_chars = 0
    answer_chars = 0
    elapsed_ms = 0
    keepalive_count = 0
    message = 'DeepSeek worker is starting.'
    pid = $PID
    started_at = (Get-Date).ToUniversalTime().ToString('o')
    updated_at = (Get-Date).ToUniversalTime().ToString('o')
    finish_reason = ''
    prompt_tokens = $null
    completion_tokens = $null
    total_tokens = $null
    error = ''
}

$context = $null
$request = $null
$response = $null
$content = $null
$stream = $null
$reader = $null
$answerWriter = $null
$stopwatch = [Diagnostics.Stopwatch]::StartNew()

try {
    New-Item -ItemType Directory -Path $JobDirectory -Force | Out-Null

    $requestPath = Join-Path $JobDirectory 'request.json'

    if (-not (Test-Path -LiteralPath $requestPath -PathType Leaf)) {
        throw "Missing request file: $requestPath"
    }

    $requestData = (
        Get-Content -Raw -Encoding UTF8 -LiteralPath $requestPath
    ) | ConvertFrom-Json

    # Minimize local prompt retention: delete the request package as soon as it
    # has been loaded into this process.
    Remove-Item -LiteralPath $requestPath -Force -ErrorAction SilentlyContinue

    $state.model = [string]$requestData.model
    $state.effort = [string]$requestData.reasoning_effort
    $state.phase = 'connecting'
    $state.message = 'Connecting to DeepSeek API.'
    Write-State -State $state

    $apiKey = Get-DeepSeekKey

    $timeoutSeconds = 600
    if ($null -ne $requestData.timeout_seconds) {
        $timeoutSeconds = [int]$requestData.timeout_seconds
    }

    if ($timeoutSeconds -lt 60) {
        $timeoutSeconds = 60
    }

    if ($timeoutSeconds -gt 1200) {
        $timeoutSeconds = 1200
    }

    $context = New-HttpContext -TimeoutSeconds $timeoutSeconds
    $state.network_mode = [string]$context.Mode
    Write-State -State $state

    $payload = [ordered]@{
        model = [string]$requestData.model
        messages = @(
            [ordered]@{
                role = 'system'
                content = [string]$requestData.system_prompt
            },
            [ordered]@{
                role = 'user'
                content = [string]$requestData.prompt
            }
        )
        stream = $true
        stream_options = [ordered]@{
            include_usage = $true
        }
        thinking = [ordered]@{
            type = $(if ([bool]$requestData.thinking) { 'enabled' } else { 'disabled' })
        }
        reasoning_effort = [string]$requestData.reasoning_effort
        max_tokens = [int]$requestData.max_tokens
    }

    $jsonBody = $payload | ConvertTo-Json -Depth 20 -Compress

    $request = New-Object `
        System.Net.Http.HttpRequestMessage `
        -ArgumentList @(
            [System.Net.Http.HttpMethod]::Post,
            'https://api.deepseek.com/chat/completions'
        )

    $request.Headers.Authorization = New-Object `
        System.Net.Http.Headers.AuthenticationHeaderValue `
        -ArgumentList @('Bearer', $apiKey)

    $request.Headers.Accept.Clear()

    [void]$request.Headers.Accept.Add(
        (New-Object `
            System.Net.Http.Headers.MediaTypeWithQualityHeaderValue `
            -ArgumentList @('text/event-stream'))
    )

    $content = New-Object `
        System.Net.Http.StringContent `
        -ArgumentList @(
            $jsonBody,
            [System.Text.Encoding]::UTF8,
            'application/json'
        )

    $request.Content = $content

    $state.phase = 'waiting_for_inference'
    $state.message = 'Request accepted locally; waiting for DeepSeek SSE stream.'
    Write-State -State $state

    $sendTask = $context.Client.SendAsync(
        $request,
        [System.Net.Http.HttpCompletionOption]::ResponseHeadersRead
    )

    $response = $sendTask.Result

    if (-not $response.IsSuccessStatusCode) {
        $errorBody = ''

        if ($null -ne $response.Content) {
            $errorBody = [string]$response.Content.ReadAsStringAsync().Result
        }

        if ($errorBody.Length -gt 2000) {
            $errorBody = $errorBody.Substring(0, 2000)
        }

        throw (
            "DeepSeek API returned HTTP " +
            ([int]$response.StatusCode) +
            " $($response.ReasonPhrase). Body: $errorBody"
        )
    }

    $stream = $response.Content.ReadAsStreamAsync().Result
    $reader = New-Object System.IO.StreamReader(
        $stream,
        [System.Text.Encoding]::UTF8,
        $true,
        8192,
        $true
    )

    $answerPath = Join-Path $JobDirectory 'answer.txt'
    $answerWriter = New-Object System.IO.StreamWriter(
        $answerPath,
        $false,
        $utf8NoBom
    )
    $answerWriter.AutoFlush = $true

    $lastStateFlush = [DateTime]::UtcNow
    $currentPhase = [string]$state.phase
    $done = $false

    while (-not $reader.EndOfStream) {
        $line = $reader.ReadLine()

        if ($null -eq $line) {
            break
        }

        if ($line.StartsWith(':')) {
            $state.keepalive_count = [int]$state.keepalive_count + 1
            $state.elapsed_ms = [int64]$stopwatch.ElapsedMilliseconds
            $state.message = (
                "DeepSeek SSE connection alive; waiting/processing. " +
                "keepalive=$($state.keepalive_count)"
            )

            if (([DateTime]::UtcNow - $lastStateFlush).TotalSeconds -ge 2) {
                Write-State -State $state
                $lastStateFlush = [DateTime]::UtcNow
            }

            continue
        }

        if (-not $line.StartsWith('data:')) {
            continue
        }

        $data = $line.Substring(5).TrimStart()

        if ($data -eq '[DONE]') {
            $done = $true
            break
        }

        if ([string]::IsNullOrWhiteSpace($data)) {
            continue
        }

        $chunk = $null

        try {
            $chunk = $data | ConvertFrom-Json
        }
        catch {
            continue
        }

        if ($null -ne $chunk.usage) {
            if ($null -ne $chunk.usage.prompt_tokens) {
                $state.prompt_tokens = [int64]$chunk.usage.prompt_tokens
            }

            if ($null -ne $chunk.usage.completion_tokens) {
                $state.completion_tokens = [int64]$chunk.usage.completion_tokens
            }

            if ($null -ne $chunk.usage.total_tokens) {
                $state.total_tokens = [int64]$chunk.usage.total_tokens
            }
        }

        if (
            ($null -eq $chunk.choices) -or
            ($chunk.choices.Count -lt 1)
        ) {
            continue
        }

        $choice = $chunk.choices[0]

        if (
            ($null -ne $choice.finish_reason) -and
            (-not [string]::IsNullOrWhiteSpace([string]$choice.finish_reason))
        ) {
            $state.finish_reason = [string]$choice.finish_reason
        }

        $delta = $choice.delta
        $phaseChanged = $false

        if ($null -ne $delta) {
            $reasoningDelta = ''

            if (
                $null -ne $delta.PSObject.Properties['reasoning_content'] -and
                $null -ne $delta.reasoning_content
            ) {
                $reasoningDelta = [string]$delta.reasoning_content
            }

            if (-not [string]::IsNullOrEmpty($reasoningDelta)) {
                $state.reasoning_chars = (
                    [int64]$state.reasoning_chars +
                    [int64]$reasoningDelta.Length
                )

                if ($currentPhase -ne 'thinking') {
                    $currentPhase = 'thinking'
                    $state.phase = 'thinking'
                    $phaseChanged = $true
                }

                $state.message = (
                    "DeepSeek is reasoning. reasoning_chars=" +
                    $state.reasoning_chars
                )
            }

            $contentDelta = ''

            if (
                $null -ne $delta.PSObject.Properties['content'] -and
                $null -ne $delta.content
            ) {
                $contentDelta = [string]$delta.content
            }

            if (-not [string]::IsNullOrEmpty($contentDelta)) {
                $answerWriter.Write($contentDelta)

                $state.answer_chars = (
                    [int64]$state.answer_chars +
                    [int64]$contentDelta.Length
                )

                if ($currentPhase -ne 'answering') {
                    $currentPhase = 'answering'
                    $state.phase = 'answering'
                    $phaseChanged = $true
                }

                $state.message = (
                    "DeepSeek is streaming the final answer. answer_chars=" +
                    $state.answer_chars
                )
            }
        }

        $state.elapsed_ms = [int64]$stopwatch.ElapsedMilliseconds

        if (
            $phaseChanged -or
            (([DateTime]::UtcNow - $lastStateFlush).TotalMilliseconds -ge 700)
        ) {
            Write-State -State $state
            $lastStateFlush = [DateTime]::UtcNow
        }
    }

    $answerWriter.Flush()
    $stopwatch.Stop()

    $answer = ''

    if (Test-Path -LiteralPath $answerPath -PathType Leaf) {
        $answer = [string](
            Get-Content -Raw -Encoding UTF8 -LiteralPath $answerPath
        )
    }

    if ([string]::IsNullOrWhiteSpace($answer)) {
        throw (
            "DeepSeek SSE ended without final content. " +
            "reasoning_chars=$($state.reasoning_chars); done=$done"
        )
    }

    $state.status = 'completed'
    $state.phase = 'completed'
    $state.elapsed_ms = [int64]$stopwatch.ElapsedMilliseconds
    $state.message = 'DeepSeek streaming completed; result is ready.'
    Write-State -State $state
}
catch {
    if ($stopwatch.IsRunning) {
        $stopwatch.Stop()
    }

    $root = $_.Exception

    while ($null -ne $root.InnerException) {
        $root = $root.InnerException
    }

    $state.status = 'failed'
    $state.phase = 'failed'
    $state.elapsed_ms = [int64]$stopwatch.ElapsedMilliseconds
    $state.error = "$($root.GetType().FullName): $($root.Message)"
    $state.message = 'DeepSeek streaming failed.'

    try {
        Write-State -State $state
    }
    catch {}
}
finally {
    try {
        if ($null -ne $answerWriter) {
            $answerWriter.Dispose()
        }
    }
    catch {}

    try {
        if ($null -ne $reader) {
            $reader.Dispose()
        }
    }
    catch {}

    try {
        if ($null -ne $stream) {
            $stream.Dispose()
        }
    }
    catch {}

    try {
        if ($null -ne $response) {
            $response.Dispose()
        }
    }
    catch {}

    try {
        if ($null -ne $request) {
            $request.Dispose()
        }
    }
    catch {}

    try {
        if ($null -ne $content) {
            $content.Dispose()
        }
    }
    catch {}

    Dispose-HttpContext -Context $context
}
