param(
    [string]$AppHome = ""
)

$ErrorActionPreference = "Stop"

function Write-Info([string]$Message) {
    Write-Host "[Clash 补丁] $Message"
}

function Backup-Once([string]$Path) {
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { return }
    $directory = Split-Path -Parent $Path
    $name = Split-Path -Leaf $Path
    $existing = Get-ChildItem -LiteralPath $directory -Filter "$name.clash-patch.*.backup" -ErrorAction SilentlyContinue
    if ($existing.Count -gt 0) { return }
    $stamp = Get-Date -Format "yyyyMMdd-HHmmss"
    Copy-Item -LiteralPath $Path -Destination "$Path.clash-patch.$stamp.backup"
}

function Write-Utf8Atomic([string]$Path, [string]$Content) {
    $directory = Split-Path -Parent $Path
    $temporary = Join-Path $directory (".clash-patch-" + [System.IO.Path]::GetRandomFileName())
    try {
        [System.IO.File]::WriteAllText($temporary, $Content, (New-Object System.Text.UTF8Encoding($false)))
        Move-Item -LiteralPath $temporary -Destination $Path -Force
    } finally {
        if (Test-Path -LiteralPath $temporary) { Remove-Item -LiteralPath $temporary -Force }
    }
}

function Set-TopLevelScalar([string]$Text, [string]$Key, [string]$Value) {
    $pattern = "(?m)^" + [regex]::Escape($Key) + ":[^\r\n]*$"
    $replacement = "$Key`: $Value"
    if ([regex]::IsMatch($Text, $pattern)) {
        return [regex]::Replace($Text, $pattern, $replacement, 1)
    }
    if ($Text.Length -gt 0 -and -not $Text.EndsWith("`n")) { $Text += "`r`n" }
    return $Text + $replacement + "`r`n"
}

function Set-TunBlock([string]$Text) {
    $managed = [ordered]@{
        "enable" = "true"
        "stack" = "system"
        "dns-hijack" = "[any:53, tcp://any:53]"
        "auto-route" = "true"
        "auto-detect-interface" = "true"
        "strict-route" = "true"
    }
    $lines = @($Text -split "`r?`n")
    $start = -1
    for ($i = 0; $i -lt $lines.Count; $i++) {
        if ($lines[$i] -match '^tun:\s*(?:#.*)?$') { $start = $i; break }
        if ($lines[$i] -match '^tun:\s*\{') {
            throw "config.yaml 使用了行内 tun 写法，无法安全合并。原文件没有被修改。"
        }
    }

    if ($start -lt 0) {
        if ($Text.Length -gt 0 -and -not $Text.EndsWith("`n")) { $Text += "`r`n" }
        $block = "tun:`r`n"
        foreach ($entry in $managed.GetEnumerator()) { $block += "  $($entry.Key): $($entry.Value)`r`n" }
        return $Text + $block
    }

    $finish = $lines.Count
    for ($i = $start + 1; $i -lt $lines.Count; $i++) {
        if ($lines[$i] -match '^\S' -and $lines[$i] -notmatch '^#') { $finish = $i; break }
    }

    foreach ($entry in $managed.GetEnumerator()) {
        $found = -1
        for ($i = $start + 1; $i -lt $finish; $i++) {
            if ($lines[$i] -match ('^\s+' + [regex]::Escape($entry.Key) + ':')) { $found = $i; break }
        }
        $line = "  $($entry.Key): $($entry.Value)"
        if ($found -ge 0) {
            $lines[$found] = $line
        } else {
            $before = @($lines[0..($finish - 1)])
            $after = if ($finish -lt $lines.Count) { @($lines[$finish..($lines.Count - 1)]) } else { @() }
            $lines = @($before + $line + $after)
            $finish += 1
        }
    }
    return ($lines -join "`r`n")
}

function Build-GlobalScript([string]$EnginePath, [string]$TargetPath) {
    $engine = Get-Content -LiteralPath $EnginePath -Raw -Encoding UTF8
    $begin = "// CLASH PATCH BEGIN"
    $end = "// CLASH PATCH END"
    $prefix = ""

    if (Test-Path -LiteralPath $TargetPath -PathType Leaf) {
        $current = Get-Content -LiteralPath $TargetPath -Raw -Encoding UTF8
        if ($current.Contains($begin)) {
            $prefix = $current.Substring(0, $current.IndexOf($begin)).TrimEnd()
        } elseif (-not [string]::IsNullOrWhiteSpace($current)) {
            $matches = [regex]::Matches($current, '(?m)^\s*function\s+main\s*\(')
            if ($matches.Count -ne 1) {
                throw "检测到已有全局扩展脚本，但无法安全合并。原脚本没有被修改，请把提示和 Script.js 截图发回来。"
            }
            $prefix = [regex]::Replace($current, '(?m)^\s*function\s+main\s*\(', 'function clashPatchPreviousMain(', 1).TrimEnd()
        }
    }

    $parts = @()
    if (-not [string]::IsNullOrWhiteSpace($prefix)) { $parts += $prefix }
    $parts += $begin
    $parts += $engine.Trim()
    $parts += $end
    return ($parts -join "`r`n") + "`r`n"
}

if ([string]::IsNullOrWhiteSpace($AppHome)) {
    $candidates = @(
        (Join-Path $env:APPDATA "io.github.clash-verge-rev.clash-verge-rev"),
        (Join-Path $env:LOCALAPPDATA "io.github.clash-verge-rev.clash-verge-rev")
    )
    $AppHome = $candidates | Where-Object { Test-Path -LiteralPath $_ -PathType Container } | Select-Object -First 1
}

if ([string]::IsNullOrWhiteSpace($AppHome) -or -not (Test-Path -LiteralPath $AppHome -PathType Container)) {
    Write-Error "没有找到受支持的 Clash Verge Rev。请安装最新版 Clash Verge Rev，打开一次后再运行 Clash 补丁。"
    exit 2
}

# Clash Verge Rev's documented global enhancement target is profiles/Script.js.
$profilesDirectory = Join-Path $AppHome "profiles"
$vergePath = Join-Path $AppHome "verge.yaml"
$configPath = Join-Path $AppHome "config.yaml"
$targetScript = Join-Path $profilesDirectory "Script.js"
$enginePath = Join-Path $PSScriptRoot "windows\clash_verge_global.js"

if (-not (Test-Path -LiteralPath $enginePath -PathType Leaf)) {
    Write-Error "安装包不完整：缺少 Windows 全局扩展脚本。"
    exit 3
}

New-Item -ItemType Directory -Path $profilesDirectory -Force | Out-Null

try {
    $scriptOutput = Build-GlobalScript $enginePath $targetScript
    $vergeInput = if (Test-Path -LiteralPath $vergePath) { Get-Content -LiteralPath $vergePath -Raw -Encoding UTF8 } else { "" }
    $vergeOutput = Set-TopLevelScalar $vergeInput "enable_tun_mode" "true"
    $vergeOutput = Set-TopLevelScalar $vergeOutput "enable_dns_settings" "false"
    $configInput = if (Test-Path -LiteralPath $configPath) { Get-Content -LiteralPath $configPath -Raw -Encoding UTF8 } else { "" }
    $configOutput = Set-TopLevelScalar $configInput "ipv6" "false"
    $configOutput = Set-TunBlock $configOutput

    Backup-Once $targetScript
    Backup-Once $vergePath
    Backup-Once $configPath
    Write-Utf8Atomic $targetScript $scriptOutput
    Write-Utf8Atomic $vergePath $vergeOutput
    Write-Utf8Atomic $configPath $configOutput

    Write-Info "已安装全局扩展脚本，之后每次加载或刷新订阅都会自动应用补丁。"
    Write-Info "已开启 TUN，并让全局脚本接管 DNS 配置。请在 Clash Verge Rev 中重新加载当前订阅或重启内核。"
    Write-Info "AI 规则会优先选择台湾家宽，其次选择日本家宽；如果两者都没有，不会替你改成其他地区。"
    exit 0
} catch {
    Write-Error "安装失败：$($_.Exception.Message)"
    exit 1
}
