$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
Add-Type -AssemblyName System.Net.Http

$OutputEncoding = [Console]::OutputEncoding = New-Object System.Text.UTF8Encoding($false)
$utf8NoBom = New-Object System.Text.UTF8Encoding($false)
$RpcInput = [Console]::OpenStandardInput()
$RpcInputBuffer = New-Object System.Collections.Generic.List[byte]
$RpcInputFirstLine = $true

function Read-Utf8StdinLine {
    while ($true) {
        $value = $RpcInput.ReadByte()

        if ($value -eq -1) {
            if ($RpcInputBuffer.Count -eq 0) {
                return $null
            }

            break
        }

        if ($value -eq 10) {
            break
        }

        if ($value -ne 13) {
            $RpcInputBuffer.Add([byte]$value)
        }
    }

    $bytes = $RpcInputBuffer.ToArray()
    $RpcInputBuffer.Clear()
    $text = $utf8NoBom.GetString($bytes)

    if ($script:RpcInputFirstLine) {
        $script:RpcInputFirstLine = $false

        while (($text.Length -gt 0) -and ($text[0] -eq [char]0xFEFF)) {
            $text = $text.Substring(1)
        }
    }

    return $text
}

$ServerRoot = Split-Path -Parent $MyInvocation.MyCommand.Path
$WorkerPath = Join-Path $ServerRoot 'stream-worker.ps1'
$JobsRoot = Join-Path $ServerRoot 'jobs'

New-Item -ItemType Directory -Path $JobsRoot -Force | Out-Null

function Write-JsonRpc {
    param([Parameter(Mandatory = $true)]$Object)

    $json = $Object | ConvertTo-Json -Depth 40 -Compress
    [Console]::Out.WriteLine($json)
    [Console]::Out.Flush()
}

function Write-RpcError {
    param(
        $Id,
        [int]$Code,
        [string]$Message
    )

    Write-JsonRpc -Object ([ordered]@{
        jsonrpc = '2.0'
        id = $Id
        error = [ordered]@{
            code = $Code
            message = $Message
        }
    })
}

function Has-Property {
    param(
        $Object,
        [string]$Name
    )

    if ($null -eq $Object) {
        return $false
    }

    return ($null -ne $Object.PSObject.Properties[$Name])
}

function Get-ArgumentValue {
    param(
        $Object,
        [string]$Name,
        $DefaultValue
    )

    if (Has-Property -Object $Object -Name $Name) {
        return $Object.$Name
    }

    return $DefaultValue
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

function Cleanup-OldJobs {
    $cutoff = (Get-Date).ToUniversalTime().AddHours(-24)

    foreach ($directory in (
        Get-ChildItem `
            -LiteralPath $JobsRoot `
            -Directory `
            -ErrorAction SilentlyContinue
    )) {
        try {
            if ($directory.LastWriteTimeUtc -lt $cutoff) {
                Remove-Item `
                    -LiteralPath $directory.FullName `
                    -Recurse `
                    -Force `
                    -ErrorAction SilentlyContinue
            }
        }
        catch {}
    }
}

function Resolve-DeepSeekModel {
    param(
        [string]$RequestedModel,
        [string]$TaskType,
        [string]$Complexity,
        [string]$Priority
    )

    if ($RequestedModel -in @('deepseek-v4-pro', 'deepseek-v4-flash')) {
        return $RequestedModel
    }

    if ($Priority -in @('latency', 'cost')) {
        return 'deepseek-v4-flash'
    }

    if ($Complexity -eq 'critical') {
        return 'deepseek-v4-pro'
    }

    if ($TaskType -in @(
        'math',
        'algorithm',
        'architecture',
        'debugging',
        'adversarial',
        'research'
    )) {
        return 'deepseek-v4-pro'
    }

    if (($TaskType -eq 'coding') -and ($Complexity -ne 'routine')) {
        return 'deepseek-v4-pro'
    }

    if (($TaskType -eq 'review') -and ($Priority -eq 'quality')) {
        return 'deepseek-v4-pro'
    }

    if (
        ($TaskType -in @(
            'writing',
            'chinese_writing',
            'translation',
            'polishing',
            'summarization'
        )) -and
        ($Priority -eq 'quality')
    ) {
        return 'deepseek-v4-pro'
    }

    return 'deepseek-v4-flash'
}

function Resolve-ReasoningEffort {
    param(
        [string]$RequestedEffort,
        [string]$Model,
        [string]$TaskType,
        [string]$Complexity
    )

    if ($RequestedEffort -in @('high', 'max')) {
        return $RequestedEffort
    }

    if ($Model -eq 'deepseek-v4-pro') {
        if (
            ($Complexity -eq 'critical') -or
            ($TaskType -in @(
                'math',
                'algorithm',
                'architecture',
                'debugging',
                'adversarial'
            ))
        ) {
            return 'max'
        }

        return 'high'
    }

    if (
        ($Complexity -ne 'routine') -and
        ($TaskType -in @('coding', 'debugging', 'review', 'adversarial'))
    ) {
        return 'max'
    }

    return 'high'
}

function Get-DefaultSystemPrompt {
    return @"
You are DeepSeek Worker, an external specialist controlled by a primary GPT-5.6 Sol orchestrator.

Work only on the bounded task and evidence supplied in the prompt.
You do not have implicit access to the local repository, the full conversation, shell commands,
tools, tests, or files that were not included in the task package.
Never claim that you read, edited, executed, or verified anything that was not supplied.

Return an independent, technically rigorous result. Prefer:
1. Conclusion
2. Key evidence and reasoning
3. Assumptions and uncertainty
4. Counterexamples / failure modes
5. Recommended verification

Match the output language requested in the task. For Chinese drafting, translation,
rewriting, or polishing, produce idiomatic native Chinese while preserving technical terms.

Do not orchestrate Luna or other workers. Do not request or expose credentials.
The primary Sol agent will compare your answer with local evidence, run validation,
and make the final decision.
"@
}

function New-DeepSeekJob {
    param([Parameter(Mandatory = $true)]$ArgumentsObject)

    Cleanup-OldJobs

    if (-not (Test-Path -LiteralPath $WorkerPath -PathType Leaf)) {
        throw "Missing stream worker: $WorkerPath"
    }

    $prompt = [string](
        Get-ArgumentValue `
            -Object $ArgumentsObject `
            -Name 'prompt' `
            -DefaultValue ''
    )

    if ([string]::IsNullOrWhiteSpace($prompt)) {
        throw 'prompt cannot be empty'
    }

    $taskType = [string](
        Get-ArgumentValue `
            -Object $ArgumentsObject `
            -Name 'task_type' `
            -DefaultValue 'analysis'
    )

    $complexity = [string](
        Get-ArgumentValue `
            -Object $ArgumentsObject `
            -Name 'complexity' `
            -DefaultValue 'complex'
    )

    $priority = [string](
        Get-ArgumentValue `
            -Object $ArgumentsObject `
            -Name 'priority' `
            -DefaultValue 'balanced'
    )

    $requestedModel = [string](
        Get-ArgumentValue `
            -Object $ArgumentsObject `
            -Name 'model' `
            -DefaultValue 'auto'
    )

    $requestedEffort = [string](
        Get-ArgumentValue `
            -Object $ArgumentsObject `
            -Name 'reasoning_effort' `
            -DefaultValue 'auto'
    )

    $validTaskTypes = @(
        'quick_check',
        'analysis',
        'coding',
        'debugging',
        'architecture',
        'math',
        'algorithm',
        'research',
        'review',
        'adversarial',
        'long_context',
        'summarization',
        'writing',
        'chinese_writing',
        'translation',
        'polishing'
    )

    if ($taskType -notin $validTaskTypes) {
        throw "Unsupported task_type: $taskType"
    }

    if ($complexity -notin @('routine', 'complex', 'critical')) {
        throw "Unsupported complexity: $complexity"
    }

    if ($priority -notin @('balanced', 'quality', 'latency', 'cost')) {
        throw "Unsupported priority: $priority"
    }

    if ($requestedModel -notin @(
        'auto',
        'deepseek-v4-pro',
        'deepseek-v4-flash'
    )) {
        throw "Unsupported model: $requestedModel"
    }

    if ($requestedEffort -notin @('auto', 'high', 'max')) {
        throw "Unsupported reasoning_effort: $requestedEffort"
    }

    $model = Resolve-DeepSeekModel `
        -RequestedModel $requestedModel `
        -TaskType $taskType `
        -Complexity $complexity `
        -Priority $priority

    $effort = Resolve-ReasoningEffort `
        -RequestedEffort $requestedEffort `
        -Model $model `
        -TaskType $taskType `
        -Complexity $complexity

    $thinking = [bool](
        Get-ArgumentValue `
            -Object $ArgumentsObject `
            -Name 'thinking' `
            -DefaultValue $true
    )

    $finalAnswerMaxChars = [int](
        Get-ArgumentValue `
            -Object $ArgumentsObject `
            -Name 'final_answer_max_chars' `
            -DefaultValue 12000
    )

    if ($finalAnswerMaxChars -lt 1000) {
        $finalAnswerMaxChars = 1000
    }

    if ($finalAnswerMaxChars -gt 60000) {
        $finalAnswerMaxChars = 60000
    }

    $maxTokensExplicit = Has-Property `
        -Object $ArgumentsObject `
        -Name 'max_tokens'

    $automaticMaxTokens = if (-not $thinking) {
        16384
    } elseif ($effort -eq 'max') {
        65536
    } else {
        32768
    }

    $maxTokens = [int](
        Get-ArgumentValue `
            -Object $ArgumentsObject `
            -Name 'max_tokens' `
            -DefaultValue $automaticMaxTokens
    )

    if ($maxTokens -lt 256) {
        $maxTokens = 256
    }

    if ($maxTokens -gt 384000) {
        $maxTokens = 384000
    }

    $systemPrompt = [string](
        Get-ArgumentValue `
            -Object $ArgumentsObject `
            -Name 'system_prompt' `
            -DefaultValue ''
    )

    if ([string]::IsNullOrWhiteSpace($systemPrompt)) {
        $systemPrompt = Get-DefaultSystemPrompt
    }

    $outputContract = @"

Final-answer contract:
- Return a complete final answer no longer than $finalAnswerMaxChars characters.
- max_tokens is shared by hidden reasoning and final content; reserve enough budget for final content.
- Prefer a complete concise answer over an exhaustive answer that is cut off.
- Cover every requested section before adding optional detail.
- End the final answer naturally. Never omit the final answer after reasoning.
"@
    $systemPrompt = $systemPrompt.TrimEnd() + $outputContract

    $jobId = (
        (Get-Date).ToUniversalTime().ToString('yyyyMMddHHmmss') +
        '-' +
        [Guid]::NewGuid().ToString('N').Substring(0, 12)
    )

    $jobDirectory = Join-Path $JobsRoot $jobId
    New-Item -ItemType Directory -Path $jobDirectory -Force | Out-Null

    $requestData = [ordered]@{
        prompt = $prompt
        system_prompt = $systemPrompt
        task_type = $taskType
        complexity = $complexity
        priority = $priority
        model = $model
        reasoning_effort = $effort
        thinking = $thinking
        max_tokens = $maxTokens
        max_tokens_explicit = [bool]$maxTokensExplicit
        final_answer_max_chars = $finalAnswerMaxChars
        timeout_seconds = 600
    }

    $requestJson = $requestData | ConvertTo-Json -Depth 12 -Compress

    [IO.File]::WriteAllText(
        (Join-Path $jobDirectory 'request.json'),
        $requestJson,
        $utf8NoBom
    )

    $initialState = [ordered]@{
        seq = 1
        job_id = $jobId
        status = 'queued'
        phase = 'queued'
        model = $model
        effort = $effort
        network_mode = Get-NetworkMode
        reasoning_chars = 0
        answer_chars = 0
        elapsed_ms = 0
        keepalive_count = 0
        message = 'DeepSeek streaming job queued.'
        pid = $null
        started_at = (Get-Date).ToUniversalTime().ToString('o')
        updated_at = (Get-Date).ToUniversalTime().ToString('o')
        finish_reason = ''
        max_tokens = $maxTokens
        max_tokens_explicit = [bool]$maxTokensExplicit
        final_answer_max_chars = $finalAnswerMaxChars
        prompt_tokens = $null
        completion_tokens = $null
        reasoning_tokens = $null
        total_tokens = $null
        error = ''
    }

    [IO.File]::WriteAllText(
        (Join-Path $jobDirectory 'state.json'),
        ($initialState | ConvertTo-Json -Depth 12 -Compress),
        $utf8NoBom
    )

    $process = Start-Process `
        -FilePath 'powershell.exe' `
        -ArgumentList @(
            '-NoLogo',
            '-NoProfile',
            '-NonInteractive',
            '-ExecutionPolicy',
            'Bypass',
            '-File',
            ('"' + $WorkerPath + '"'),
            '-JobDirectory',
            ('"' + $jobDirectory + '"')
        ) `
        -WindowStyle Hidden `
        -PassThru

    return [pscustomobject]@{
        job_id = $jobId
        model = $model
        effort = $effort
        max_tokens = $maxTokens
        max_tokens_explicit = [bool]$maxTokensExplicit
        final_answer_max_chars = $finalAnswerMaxChars
        pid = $process.Id
        job_directory = $jobDirectory
    }
}

function Read-JobState {
    param([string]$JobId)

    if ($JobId -notmatch '^[0-9]{14}-[a-f0-9]{12}$') {
        throw 'Invalid job_id format.'
    }

    $jobDirectory = Join-Path $JobsRoot $JobId
    $statePath = Join-Path $jobDirectory 'state.json'

    if (-not (Test-Path -LiteralPath $statePath -PathType Leaf)) {
        throw "Unknown DeepSeek job: $JobId"
    }

    for ($attempt = 1; $attempt -le 5; $attempt++) {
        try {
            return (
                Get-Content -Raw -Encoding UTF8 -LiteralPath $statePath
            ) | ConvertFrom-Json
        }
        catch {
            if ($attempt -eq 5) {
                throw
            }

            Start-Sleep -Milliseconds 40
        }
    }
}

function Get-AnswerText {
    param([string]$JobId)

    $answerPath = Join-Path (Join-Path $JobsRoot $JobId) 'answer.txt'

    if (-not (Test-Path -LiteralPath $answerPath -PathType Leaf)) {
        return ''
    }

    for ($attempt = 1; $attempt -le 3; $attempt++) {
        try {
            return [string](
                Get-Content -Raw -Encoding UTF8 -LiteralPath $answerPath
            )
        }
        catch {
            if ($attempt -eq 3) {
                return ''
            }

            Start-Sleep -Milliseconds 40
        }
    }

    return ''
}

function Format-JobProgress {
    param(
        $State,
        [string]$Answer,
        [int]$PreviewChars = 1000
    )

    $elapsedSeconds = [math]::Round(
        ([double]$State.elapsed_ms / 1000.0),
        1
    )
    $maxTokens = Get-ArgumentValue -Object $State -Name 'max_tokens' -DefaultValue ''
    $maxTokensExplicit = Get-ArgumentValue -Object $State -Name 'max_tokens_explicit' -DefaultValue ''
    $finalAnswerMaxChars = Get-ArgumentValue -Object $State -Name 'final_answer_max_chars' -DefaultValue ''
    $reasoningTokens = Get-ArgumentValue -Object $State -Name 'reasoning_tokens' -DefaultValue ''

    $terminalAnswer = $Answer
    $terminalAnswerLimit = 24000
    $answerTotalChars = $terminalAnswer.Length
    $answerReturnedChars = $answerTotalChars
    $answerNextOffset = $answerTotalChars
    $answerEof = $true

    if ($answerTotalChars -gt $terminalAnswerLimit) {
        $terminalAnswer = $terminalAnswer.Substring(0, $terminalAnswerLimit)
        $answerReturnedChars = $terminalAnswerLimit
        $answerNextOffset = $terminalAnswerLimit
        $answerEof = $false
    }

    $answerDelivery = (
        "`nanswer_total_chars=$answerTotalChars" +
        "`nanswer_returned_chars=$answerReturnedChars" +
        "`nanswer_next_offset=$answerNextOffset" +
        "`nanswer_eof=$($answerEof.ToString().ToLowerInvariant())"
    )

    if (-not $answerEof) {
        $answerDelivery += (
            "`nanswer_delivery=chunked; call deepseek_read with " +
            "offset_chars=$answerNextOffset. Local reads make no API call " +
            "and consume no DeepSeek tokens."
        )
    }

    $text = @(
        "DeepSeek JOB $($State.status.ToString().ToUpperInvariant())",
        "job_id=$($State.job_id)",
        "phase=$($State.phase)",
        "model=$($State.model)",
        "effort=$($State.effort)",
        "network_mode=$($State.network_mode)",
        "elapsed_sec=$elapsedSeconds",
        "reasoning_chars=$($State.reasoning_chars)",
        "answer_chars=$($State.answer_chars)",
        "max_tokens=$maxTokens",
        "max_tokens_explicit=$maxTokensExplicit",
        "final_answer_max_chars=$finalAnswerMaxChars",
        "keepalive_count=$($State.keepalive_count)",
        "message=$($State.message)"
    ) -join "`n"

    if (
        (-not [string]::IsNullOrWhiteSpace($Answer)) -and
        ($State.status -notin @('completed', 'incomplete'))
    ) {
        $preview = $Answer

        if ($preview.Length -gt $PreviewChars) {
            $preview = $preview.Substring(
                $preview.Length - $PreviewChars,
                $PreviewChars
            )
        }

        $text += (
            "`n`npartial_final_answer_tail:`n" +
            $preview
        )
    }

    if ($State.status -eq 'completed') {
        $text += (
            "`nfinish_reason=$($State.finish_reason)" +
            "`nprompt_tokens=$($State.prompt_tokens)" +
            "`ncompletion_tokens=$($State.completion_tokens)" +
            "`nreasoning_tokens=$reasoningTokens" +
            "`ntotal_tokens=$($State.total_tokens)" +
            $answerDelivery +
            "`n`nDeepSeek CALL OK`n`n" +
            $terminalAnswer
        )
    }

    if ($State.status -eq 'incomplete') {
        $text += (
            "`nfinish_reason=$($State.finish_reason)" +
            "`nprompt_tokens=$($State.prompt_tokens)" +
            "`ncompletion_tokens=$($State.completion_tokens)" +
            "`nreasoning_tokens=$reasoningTokens" +
            "`ntotal_tokens=$($State.total_tokens)" +
            "`nerror=$($State.error)" +
            $answerDelivery +
            "`n`nDeepSeek CALL INCOMPLETE`n" +
            "The output budget ended before a natural stop. " +
            "Do not rerun the full reasoning task. If anything is missing, " +
            "start one targeted continuation with thinking=false and ask only " +
            "for the missing sections."
        )

        if (-not [string]::IsNullOrWhiteSpace($Answer)) {
            $text += "`n`npartial_answer:`n" + $terminalAnswer
        }
    }

    if ($State.status -eq 'failed') {
        $text += "`nerror=$($State.error)"
    }

    return $text
}

function Invoke-DeepSeekStatus {
    $apiKey = Get-DeepSeekKey
    $context = $null
    $request = $null
    $response = $null
    $stopwatch = [Diagnostics.Stopwatch]::StartNew()

    try {
        $context = New-HttpContext -TimeoutSeconds 15

        $request = New-Object `
            System.Net.Http.HttpRequestMessage `
            -ArgumentList @(
                [System.Net.Http.HttpMethod]::Get,
                'https://api.deepseek.com/models'
            )

        $request.Headers.Authorization = New-Object `
            System.Net.Http.Headers.AuthenticationHeaderValue `
            -ArgumentList @('Bearer', $apiKey)

        $response = $context.Client.SendAsync($request).Result
        $body = [string]$response.Content.ReadAsStringAsync().Result
        $stopwatch.Stop()

        if (-not $response.IsSuccessStatusCode) {
            throw (
                "DeepSeek /models returned HTTP " +
                ([int]$response.StatusCode) +
                " $($response.ReasonPhrase)"
            )
        }

        $parsed = $body | ConvertFrom-Json
        $models = @(
            $parsed.data |
            ForEach-Object { [string]$_.id } |
            Where-Object { -not [string]::IsNullOrWhiteSpace($_) }
        )

        return (
            "DeepSeek STATUS OK`n" +
            "network_mode=$($context.Mode)`n" +
            "latency_ms=$($stopwatch.ElapsedMilliseconds)`n" +
            "models=$($models -join ', ')"
        )
    }
    finally {
        try {
            if ($null -ne $response) { $response.Dispose() }
        }
        catch {}

        try {
            if ($null -ne $request) { $request.Dispose() }
        }
        catch {}

        Dispose-HttpContext -Context $context
    }
}

function Invoke-DeepSeekStart {
    param($ArgumentsObject)

    $job = New-DeepSeekJob -ArgumentsObject $ArgumentsObject

    return (
        "DeepSeek STREAM JOB STARTED`n" +
        "job_id=$($job.job_id)`n" +
        "model=$($job.model)`n" +
        "effort=$($job.effort)`n" +
        "max_tokens=$($job.max_tokens)`n" +
        "max_tokens_explicit=$($job.max_tokens_explicit)`n" +
        "final_answer_max_chars=$($job.final_answer_max_chars)`n" +
        "pid=$($job.pid)`n" +
        "Next: call deepseek_poll with this job_id. " +
        "Use wait_seconds=30; it returns after 30 seconds or immediately on a terminal state."
    )
}

function Invoke-DeepSeekPoll {
    param($ArgumentsObject)

    $jobId = [string](
        Get-ArgumentValue `
            -Object $ArgumentsObject `
            -Name 'job_id' `
            -DefaultValue ''
    )

    if ([string]::IsNullOrWhiteSpace($jobId)) {
        throw 'job_id is required.'
    }

    $waitSeconds = [int](
        Get-ArgumentValue `
            -Object $ArgumentsObject `
            -Name 'wait_seconds' `
            -DefaultValue 30
    )

    if ($waitSeconds -lt 0) {
        $waitSeconds = 0
    }

    if ($waitSeconds -gt 30) {
        $waitSeconds = 30
    }

    $initial = Read-JobState -JobId $jobId
    $deadline = [DateTime]::UtcNow.AddSeconds($waitSeconds)
    $state = $initial

    while (
        ([DateTime]::UtcNow -lt $deadline) -and
        ($state.status -notin @('completed', 'incomplete', 'failed', 'cancelled'))
    ) {
        Start-Sleep -Milliseconds 250
        $state = Read-JobState -JobId $jobId
    }

    $answer = Get-AnswerText -JobId $jobId

    return Format-JobProgress `
        -State $state `
        -Answer $answer `
        -PreviewChars 1200
}

function Invoke-DeepSeekRead {
    param($ArgumentsObject)

    $jobId = [string](
        Get-ArgumentValue `
            -Object $ArgumentsObject `
            -Name 'job_id' `
            -DefaultValue ''
    )

    if ([string]::IsNullOrWhiteSpace($jobId)) {
        throw 'job_id is required.'
    }

    $offsetChars = [int](
        Get-ArgumentValue `
            -Object $ArgumentsObject `
            -Name 'offset_chars' `
            -DefaultValue 0
    )

    $maxChars = [int](
        Get-ArgumentValue `
            -Object $ArgumentsObject `
            -Name 'max_chars' `
            -DefaultValue 12000
    )

    if ($offsetChars -lt 0) {
        $offsetChars = 0
    }

    if ($maxChars -lt 1000) {
        $maxChars = 1000
    }

    if ($maxChars -gt 24000) {
        $maxChars = 24000
    }

    $state = Read-JobState -JobId $jobId
    $answer = Get-AnswerText -JobId $jobId
    $totalChars = $answer.Length

    if ($offsetChars -gt $totalChars) {
        $offsetChars = $totalChars
    }

    $remainingChars = $totalChars - $offsetChars
    $returnedChars = [math]::Min($maxChars, $remainingChars)
    $chunk = ''

    if ($returnedChars -gt 0) {
        $chunk = $answer.Substring($offsetChars, $returnedChars)
    }

    $nextOffset = $offsetChars + $returnedChars
    $eof = ($nextOffset -ge $totalChars)

    return (
        "DeepSeek LOCAL ANSWER CHUNK`n" +
        "job_id=$jobId`n" +
        "status=$($state.status)`n" +
        "offset_chars=$offsetChars`n" +
        "returned_chars=$returnedChars`n" +
        "total_chars=$totalChars`n" +
        "next_offset=$nextOffset`n" +
        "eof=$($eof.ToString().ToLowerInvariant())`n" +
        "api_tokens_charged=0`n`n" +
        $chunk
    )
}

function Invoke-DeepSeekCancel {
    param($ArgumentsObject)

    $jobId = [string](
        Get-ArgumentValue `
            -Object $ArgumentsObject `
            -Name 'job_id' `
            -DefaultValue ''
    )

    if ([string]::IsNullOrWhiteSpace($jobId)) {
        throw 'job_id is required.'
    }

    $state = Read-JobState -JobId $jobId

    if ($state.status -in @('completed', 'incomplete', 'failed', 'cancelled')) {
        return (
            "DeepSeek job is already terminal: " +
            "job_id=$jobId status=$($state.status)"
        )
    }

    $pidValue = $null

    if ($null -ne $state.pid) {
        $pidValue = [int]$state.pid
    }

    if ($null -ne $pidValue) {
        try {
            Stop-Process -Id $pidValue -Force -ErrorAction Stop
        }
        catch {}
    }

    $jobDirectory = Join-Path $JobsRoot $jobId

    $cancelled = [ordered]@{
        seq = [int]$state.seq + 1
        job_id = $jobId
        status = 'cancelled'
        phase = 'cancelled'
        model = [string]$state.model
        effort = [string]$state.effort
        network_mode = [string]$state.network_mode
        reasoning_chars = [int64]$state.reasoning_chars
        answer_chars = [int64]$state.answer_chars
        elapsed_ms = [int64]$state.elapsed_ms
        keepalive_count = [int64]$state.keepalive_count
        message = 'DeepSeek job cancelled by Sol/user.'
        pid = $pidValue
        started_at = [string]$state.started_at
        updated_at = (Get-Date).ToUniversalTime().ToString('o')
        finish_reason = ''
        max_tokens = Get-ArgumentValue -Object $state -Name 'max_tokens' -DefaultValue $null
        max_tokens_explicit = Get-ArgumentValue -Object $state -Name 'max_tokens_explicit' -DefaultValue $false
        final_answer_max_chars = Get-ArgumentValue -Object $state -Name 'final_answer_max_chars' -DefaultValue $null
        prompt_tokens = $state.prompt_tokens
        completion_tokens = $state.completion_tokens
        reasoning_tokens = Get-ArgumentValue -Object $state -Name 'reasoning_tokens' -DefaultValue $null
        total_tokens = $state.total_tokens
        error = ''
    }

    [IO.File]::WriteAllText(
        (Join-Path $jobDirectory 'state.json'),
        ($cancelled | ConvertTo-Json -Depth 12 -Compress),
        $utf8NoBom
    )

    return "DeepSeek JOB CANCELLED`njob_id=$jobId"
}

function Invoke-DeepSeekConsultCompatibility {
    param($ArgumentsObject)

    $job = New-DeepSeekJob -ArgumentsObject $ArgumentsObject
    $jobId = [string]$job.job_id
    $deadline = [DateTime]::UtcNow.AddMinutes(10)

    while ([DateTime]::UtcNow -lt $deadline) {
        Start-Sleep -Seconds 1
        $state = Read-JobState -JobId $jobId

        if ($state.status -in @('completed', 'incomplete', 'failed', 'cancelled')) {
            $answer = Get-AnswerText -JobId $jobId
            return Format-JobProgress -State $state -Answer $answer -PreviewChars 1200
        }
    }

    throw (
        "Synchronous compatibility call timed out. " +
        "Use deepseek_start + deepseek_poll instead. job_id=$jobId"
    )
}

$commonProperties = [ordered]@{
    prompt = [ordered]@{
        type = 'string'
        description = 'Self-contained task package.'
    }
    task_type = [ordered]@{
        type = 'string'
        enum = @(
            'quick_check',
            'analysis',
            'coding',
            'debugging',
            'architecture',
            'math',
            'algorithm',
            'research',
            'review',
            'adversarial',
            'long_context',
            'summarization',
            'writing',
            'chinese_writing',
            'translation',
            'polishing'
        )
        default = 'analysis'
    }
    complexity = [ordered]@{
        type = 'string'
        enum = @('routine', 'complex', 'critical')
        default = 'complex'
    }
    priority = [ordered]@{
        type = 'string'
        enum = @('balanced', 'quality', 'latency', 'cost')
        default = 'balanced'
    }
    model = [ordered]@{
        type = 'string'
        enum = @(
            'auto',
            'deepseek-v4-pro',
            'deepseek-v4-flash'
        )
        default = 'auto'
    }
    reasoning_effort = [ordered]@{
        type = 'string'
        enum = @('auto', 'high', 'max')
        default = 'auto'
    }
    thinking = [ordered]@{
        type = 'boolean'
        default = $true
    }
    max_tokens = [ordered]@{
        type = 'integer'
        minimum = 256
        maximum = 384000
        description = @'
Optional hard ceiling shared by hidden reasoning and final content. Omit it for the
automatic 16K/32K/64K budget selected from thinking and reasoning effort. Set it
only when the user explicitly wants a stricter cost ceiling.
'@
    }
    final_answer_max_chars = [ordered]@{
        type = 'integer'
        minimum = 1000
        maximum = 60000
        default = 12000
        description = @'
Desired maximum final-answer length in characters. This controls answer verbosity
without starving hidden reasoning of the shared max_tokens budget.
'@
    }
    system_prompt = [ordered]@{
        type = 'string'
    }
}

$startTool = [ordered]@{
    name = 'deepseek_start'
    title = 'Start DeepSeek Streaming Job'
    description = @'
Preferred DeepSeek invocation for any task that may take more than a few seconds.
Starts a true SSE streaming request in a background worker and returns immediately with a job_id.
Then call deepseek_poll with its 30-second long-poll default. It returns early only for a terminal state.
Do not expose raw reasoning_content; progress reports only show phase and reasoning character count.
'@
    inputSchema = [ordered]@{
        type = 'object'
        additionalProperties = $false
        properties = $commonProperties
        required = @('prompt')
    }
    annotations = [ordered]@{
        readOnlyHint = $true
        destructiveHint = $false
        idempotentHint = $false
        openWorldHint = $true
    }
}

$pollTool = [ordered]@{
    name = 'deepseek_poll'
    title = 'Poll DeepSeek Streaming Job'
    description = @'
Poll a DeepSeek streaming job. Returns within at most wait_seconds (0-30).
Shows queued/connecting/waiting_for_inference/thinking/answering/completed/incomplete,
elapsed time, keepalive count, reasoning character count, answer character count,
and a tail preview once the final answer starts streaming. A terminal result returns up
to 24,000 answer characters plus answer_next_offset for zero-API-token local paging.
'@
    inputSchema = [ordered]@{
        type = 'object'
        additionalProperties = $false
        properties = [ordered]@{
            job_id = [ordered]@{
                type = 'string'
            }
            wait_seconds = [ordered]@{
                type = 'integer'
                minimum = 0
                maximum = 30
                default = 30
            }
        }
        required = @('job_id')
    }
    annotations = [ordered]@{
        readOnlyHint = $true
        destructiveHint = $false
        idempotentHint = $true
        openWorldHint = $false
    }
}

$readTool = [ordered]@{
    name = 'deepseek_read'
    title = 'Read DeepSeek Answer Chunk'
    description = @'
Read a bounded chunk from the locally persisted answer for a job. This never calls
the DeepSeek API and consumes no DeepSeek tokens. Use it when a completed answer is
larger than one MCP/tool-output window, following answer_next_offset until eof=true.
'@
    inputSchema = [ordered]@{
        type = 'object'
        additionalProperties = $false
        properties = [ordered]@{
            job_id = [ordered]@{
                type = 'string'
            }
            offset_chars = [ordered]@{
                type = 'integer'
                minimum = 0
                default = 0
            }
            max_chars = [ordered]@{
                type = 'integer'
                minimum = 1000
                maximum = 24000
                default = 12000
            }
        }
        required = @('job_id')
    }
    annotations = [ordered]@{
        readOnlyHint = $true
        destructiveHint = $false
        idempotentHint = $true
        openWorldHint = $false
    }
}

$cancelTool = [ordered]@{
    name = 'deepseek_cancel'
    title = 'Cancel DeepSeek Streaming Job'
    description = 'Cancel a running DeepSeek streaming job by job_id.'
    inputSchema = [ordered]@{
        type = 'object'
        additionalProperties = $false
        properties = [ordered]@{
            job_id = [ordered]@{
                type = 'string'
            }
        }
        required = @('job_id')
    }
    annotations = [ordered]@{
        readOnlyHint = $false
        destructiveHint = $true
        idempotentHint = $true
        openWorldHint = $false
    }
}

$statusTool = [ordered]@{
    name = 'deepseek_status'
    title = 'DeepSeek Connection Status'
    description = 'Fast connectivity/API-key check against DeepSeek /models.'
    inputSchema = [ordered]@{
        type = 'object'
        additionalProperties = $false
        properties = [ordered]@{}
    }
    annotations = [ordered]@{
        readOnlyHint = $true
        destructiveHint = $false
        idempotentHint = $true
        openWorldHint = $true
    }
}

$compatTool = [ordered]@{
    name = 'deepseek_consult'
    title = 'DeepSeek V4 Worker (Synchronous Compatibility)'
    description = @'
Compatibility tool. It now uses the same SSE worker internally but waits for completion before returning.
Prefer deepseek_start + deepseek_poll so the user can see progress instead of waiting blindly.
'@
    inputSchema = [ordered]@{
        type = 'object'
        additionalProperties = $false
        properties = $commonProperties
        required = @('prompt')
    }
    annotations = [ordered]@{
        readOnlyHint = $true
        destructiveHint = $false
        idempotentHint = $false
        openWorldHint = $true
    }
}

$serverInstructions = @'
DeepSeek V4 Worker and Codex Luna Worker are specialists under the primary GPT-5.6 Sol thread.
Sol owns intent, planning, permission decisions, decomposition, synthesis, verification, and the final answer.
Route local repository/tool execution and bounded mechanical work to Luna.
Route low-cost checks and routine independent analysis to DeepSeek V4 Flash.
Route mathematics, algorithms, architecture, complex debugging, adversarial review, and critical research to DeepSeek V4 Pro.
Route Chinese drafting, rewriting, translation, polishing, and summarization to DeepSeek by default: Flash for routine work, Pro for quality-first, academic, or critical text.
For DeepSeek, prefer deepseek_start followed by deepseek_poll rather than the synchronous deepseek_consult.
After deepseek_start returns, tell the user the job has started. Poll with wait_seconds=30.
Give a compact visible progress update on phase changes or about every 30 seconds.
Omit max_tokens unless the user explicitly requests a hard cost ceiling; the router selects a safe dynamic budget.
Use final_answer_max_chars to control answer verbosity without starving hidden reasoning.
Treat status=incomplete or finish_reason=length as incomplete, never as a successful final answer.
If continuation is needed, request only missing sections with thinking=false; never rerun the full reasoning task automatically.
If answer_eof=false, page through deepseek_read from answer_next_offset. It reads the local file and spends no DeepSeek tokens.
Do not expose raw reasoning_content; report reasoning_chars, reasoning_tokens, and phase only.
When phase becomes answering, partial_final_answer_tail may be surfaced if useful.
Never create Luna-to-DeepSeek or DeepSeek-to-Luna recursive chains.
'@

while ($true) {
    $line = Read-Utf8StdinLine

    if ($null -eq $line) {
        break
    }

    if ([string]::IsNullOrWhiteSpace($line)) {
        continue
    }

    try {
        $message = $line | ConvertFrom-Json
    }
    catch {
        Write-RpcError -Id $null -Code -32700 -Message 'Parse error'
        continue
    }

    $hasId = Has-Property -Object $message -Name 'id'
    $id = if ($hasId) { $message.id } else { $null }

    $method = if (Has-Property -Object $message -Name 'method') {
        [string]$message.method
    } else {
        ''
    }

    try {
        switch ($method) {
            'initialize' {
                if ($hasId) {
                    $requestedVersion = '2025-06-18'

                    if (
                        (Has-Property -Object $message -Name 'params') -and
                        (Has-Property -Object $message.params -Name 'protocolVersion')
                    ) {
                        $requestedVersion = [string]$message.params.protocolVersion
                    }

                    Write-JsonRpc -Object ([ordered]@{
                        jsonrpc = '2.0'
                        id = $id
                        result = [ordered]@{
                            protocolVersion = $requestedVersion
                            capabilities = [ordered]@{
                                tools = [ordered]@{}
                            }
                            serverInfo = [ordered]@{
                                name = 'deepseek-v4-worker'
                                version = '3.4.0-0813-codex-router-budget'
                            }
                            instructions = $serverInstructions
                        }
                    })
                }
            }

            'notifications/initialized' {}

            'ping' {
                if ($hasId) {
                    Write-JsonRpc -Object ([ordered]@{
                        jsonrpc = '2.0'
                        id = $id
                        result = [ordered]@{}
                    })
                }
            }

            'tools/list' {
                if ($hasId) {
                    Write-JsonRpc -Object ([ordered]@{
                        jsonrpc = '2.0'
                        id = $id
                        result = [ordered]@{
                            tools = @(
                                $startTool,
                                $pollTool,
                                $readTool,
                                $cancelTool,
                                $statusTool,
                                $compatTool
                            )
                        }
                    })
                }
            }

            'tools/call' {
                if (-not $hasId) {
                    continue
                }

                if (-not (Has-Property -Object $message -Name 'params')) {
                    Write-RpcError -Id $id -Code -32602 -Message 'Missing params'
                    continue
                }

                $toolName = if (
                    Has-Property -Object $message.params -Name 'name'
                ) {
                    [string]$message.params.name
                } else {
                    ''
                }

                $argumentsObject = if (
                    Has-Property -Object $message.params -Name 'arguments'
                ) {
                    $message.params.arguments
                } else {
                    [pscustomobject]@{}
                }

                try {
                    $text = switch ($toolName) {
                        'deepseek_start' {
                            Invoke-DeepSeekStart -ArgumentsObject $argumentsObject
                            break
                        }

                        'deepseek_poll' {
                            Invoke-DeepSeekPoll -ArgumentsObject $argumentsObject
                            break
                        }

                        'deepseek_read' {
                            Invoke-DeepSeekRead -ArgumentsObject $argumentsObject
                            break
                        }

                        'deepseek_cancel' {
                            Invoke-DeepSeekCancel -ArgumentsObject $argumentsObject
                            break
                        }

                        'deepseek_status' {
                            Invoke-DeepSeekStatus
                            break
                        }

                        'deepseek_consult' {
                            Invoke-DeepSeekConsultCompatibility `
                                -ArgumentsObject $argumentsObject
                            break
                        }

                        default {
                            throw "Unknown tool: $toolName"
                        }
                    }

                    Write-JsonRpc -Object ([ordered]@{
                        jsonrpc = '2.0'
                        id = $id
                        result = [ordered]@{
                            content = @(
                                [ordered]@{
                                    type = 'text'
                                    text = $text
                                }
                            )
                            isError = $false
                        }
                    })
                }
                catch {
                    Write-JsonRpc -Object ([ordered]@{
                        jsonrpc = '2.0'
                        id = $id
                        result = [ordered]@{
                            content = @(
                                [ordered]@{
                                    type = 'text'
                                    text = $_.Exception.Message
                                }
                            )
                            isError = $true
                        }
                    })
                }
            }

            default {
                if ($hasId) {
                    Write-RpcError `
                        -Id $id `
                        -Code -32601 `
                        -Message "Method not found: $method"
                }
            }
        }
    }
    catch {
        if ($hasId) {
            Write-RpcError `
                -Id $id `
                -Code -32603 `
                -Message "Internal error: $($_.Exception.Message)"
        } else {
            [Console]::Error.WriteLine(
                "MCP server error: $($_.Exception.Message)"
            )
        }
    }
}
