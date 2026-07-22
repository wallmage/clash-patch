param(
    [string]$ControllerUrl = "http://127.0.0.1:9097",
    [string]$Secret = "",
    [string]$MainGroup = "",
    [string]$AiGroup = "",
    [int]$ObservationSeconds = 15
)

$ErrorActionPreference = "Stop"

function Invoke-ControllerJson([string]$Endpoint) {
    $headers = @{}
    if (-not [string]::IsNullOrWhiteSpace($Secret)) {
        $headers["Authorization"] = "Bearer $Secret"
    }
    $uri = $ControllerUrl.TrimEnd("/") + $Endpoint
    $response = Invoke-WebRequest -UseBasicParsing -Uri $uri -Headers $headers -Method Get -TimeoutSec 5
    if ([int]$response.StatusCode -ne 200) { throw "本地控制器请求失败。" }
    return ($response.Content | ConvertFrom-Json)
}

function Get-Policy {
    $path = Join-Path (Split-Path -Parent (Split-Path -Parent $PSScriptRoot)) "references\policy.json"
    if (-not (Test-Path -LiteralPath $path -PathType Leaf)) { throw "找不到策略文件。" }
    return (Get-Content -LiteralPath $path -Raw -Encoding UTF8 | ConvertFrom-Json)
}

function Find-Group([object]$Proxies, [object[]]$Candidates, [string]$Requested, [string]$Label) {
    if (-not [string]::IsNullOrWhiteSpace($Requested)) {
        if ($null -eq $Proxies.PSObject.Properties[$Requested]) { throw "找不到$Label。" }
        return $Requested
    }
    foreach ($candidate in $Candidates) {
        $name = [string]$candidate
        if ($null -ne $Proxies.PSObject.Properties[$name]) { return $name }
    }
    if ($Label -eq "AI 分组") {
        foreach ($property in $Proxies.PSObject.Properties) {
            $type = [string]$property.Value.type
            if ($type -eq "Selector" -and [string]$property.Name -match '(?i)(^|[^A-Za-z])AI([^A-Za-z]|$)|OpenAI|人工智能|🤖') {
                return [string]$property.Name
            }
        }
    }
    throw "无法自动识别$Label；未进行分流验证。"
}

function Get-ConnectionIds {
    $connections = @((Invoke-ControllerJson "/connections").connections)
    $ids = @{}
    foreach ($connection in $connections) {
        if ($null -ne $connection -and -not [string]::IsNullOrWhiteSpace([string]$connection.id)) {
            $ids[[string]$connection.id] = $true
        }
    }
    return $ids
}

function Start-TestTraffic([string]$Url) {
    $curl = Get-Command curl.exe -ErrorAction SilentlyContinue
    if ($null -eq $curl) { throw "找不到 Windows 自带的 curl.exe。" }
    $start = New-Object System.Diagnostics.ProcessStartInfo
    $start.FileName = $curl.Source
    $start.Arguments = '--http1.1 -L --max-time 15 --limit-rate 2k --output NUL --silent "' + $Url.Replace('"', '\"') + '"'
    $start.UseShellExecute = $false
    $start.CreateNoWindow = $true
    $process = New-Object System.Diagnostics.Process
    $process.StartInfo = $start
    if (-not $process.Start()) { throw "无法启动分流测试请求。" }
    return $process
}

function Observe-Route([string]$Label, [string]$Url, [string]$HostPattern, [string]$ExpectedGroup, [string]$ExpectedSelection) {
    $known = Get-ConnectionIds
    $process = Start-TestTraffic $Url
    try {
        $deadline = [DateTime]::UtcNow.AddSeconds($ObservationSeconds)
        while ([DateTime]::UtcNow -lt $deadline) {
            Start-Sleep -Milliseconds 100
            $connections = @((Invoke-ControllerJson "/connections").connections)
            foreach ($connection in $connections) {
                if ($null -eq $connection -or $known.ContainsKey([string]$connection.id)) { continue }
                $host = [string]$connection.metadata.host
                if ($host -notmatch $HostPattern) { continue }
                $chains = @($connection.chains | ForEach-Object { [string]$_ })
                $passed = ($chains -notcontains "DIRECT") -and
                    ($chains -contains $ExpectedGroup) -and
                    ($chains -contains $ExpectedSelection) -and
                    ($ExpectedSelection -ne "DIRECT")
                Write-Host ("{0}：{1}" -f $Label, $(if ($passed) { "通过" } else { "失败" }))
                return $passed
            }
        }
        Write-Host "$Label：失败（没有观察到对应连接）"
        return $false
    } finally {
        if ($null -ne $process -and -not $process.HasExited) {
            try { $process.Kill() } catch { }
        }
        if ($null -ne $process) { $process.Dispose() }
    }
}

try {
    if ($ObservationSeconds -lt 1 -or $ObservationSeconds -gt 60) { throw "观察时间必须为 1 到 60 秒。" }
    $policy = Get-Policy
    $proxyResponse = Invoke-ControllerJson "/proxies"
    $proxies = $proxyResponse.proxies
    if ($null -eq $proxies) { throw "本地控制器没有返回代理组。" }

    $main = Find-Group $proxies @($policy.main_group_names) $MainGroup "主代理组"
    $ai = Find-Group $proxies @($policy.ai_group_names) $AiGroup "AI 分组"
    $mainSelection = [string]$proxies.PSObject.Properties[$main].Value.now
    $aiSelection = [string]$proxies.PSObject.Properties[$ai].Value.now
    if ([string]::IsNullOrWhiteSpace($mainSelection) -or $mainSelection -eq "DIRECT") { throw "主代理组当前没有选择有效代理节点。" }
    if ([string]::IsNullOrWhiteSpace($aiSelection) -or $aiSelection -eq "DIRECT") { throw "AI 分组当前没有选择有效代理节点。" }

    Write-Output "主代理组：已识别；当前选择已隐藏"
    Write-Output "AI 分组：已识别；当前选择已隐藏"
    $checks = @(
        (Observe-Route "Google" "https://www.google.com/search?q=clash-route-verification" "google" $main $mainSelection),
        (Observe-Route "OpenAI" "https://openai.com/" "openai" $ai $aiSelection),
        (Observe-Route "Anthropic" "https://www.anthropic.com/" "anthropic" $ai $aiSelection),
        (Observe-Route "Claude" "https://claude.ai/" "claude" $ai $aiSelection)
    )
    if (@($checks | Where-Object { -not $_ }).Count -gt 0) { exit 1 }
    exit 0
} catch {
    [Console]::Error.WriteLine("[Clash 补丁] Windows 分流验证失败：$($_.Exception.Message)")
    exit 1
}
