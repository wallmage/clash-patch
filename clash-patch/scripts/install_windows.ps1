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
    $existing = @(Get-ChildItem -LiteralPath $directory -Filter "$name.clash-patch.*.backup" -ErrorAction SilentlyContinue)
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

function Split-YamlLines([string]$Text) {
    if ([string]::IsNullOrEmpty($Text)) { return @() }
    return @($Text -split "`r?`n")
}

function Join-YamlLines([string[]]$Lines) {
    if ($Lines.Count -eq 0) { return "" }
    $text = $Lines -join "`r`n"
    if (-not $text.EndsWith("`r`n")) { $text += "`r`n" }
    return $text
}

function Get-YamlIndent([string]$Line) {
    if ($Line -match '^ *\t') { throw "YAML 使用了制表符缩进，无法安全修改。" }
    if ($Line -match '^( *)') { return $Matches[1].Length }
    return 0
}

function Get-YamlMappingEntry([string]$Line) {
    $pattern = '^\s*(?:"([A-Za-z0-9_-]+)"|''([A-Za-z0-9_-]+)''|([A-Za-z0-9_-]+))\s*:\s*(.*)$'
    if ($Line -notmatch $pattern) { return $null }
    $key = @($Matches[1], $Matches[2], $Matches[3]) | Where-Object { -not [string]::IsNullOrEmpty($_) } | Select-Object -First 1
    return [pscustomobject]@{ Key = $key; Value = $Matches[4] }
}

function Find-YamlMappingNode(
    [string[]]$Lines,
    [string]$Key,
    [int]$Indent,
    [int]$SearchStart,
    [int]$SearchEnd
) {
    $foundIndexes = @()
    for ($i = $SearchStart; $i -lt $SearchEnd; $i++) {
        $line = $Lines[$i]
        if ([string]::IsNullOrWhiteSpace($line) -or $line.TrimStart().StartsWith("#")) { continue }
        if ((Get-YamlIndent $line) -ne $Indent) { continue }
        $entry = Get-YamlMappingEntry $line
        if ($null -ne $entry -and $entry.Key -eq $Key) {
            $foundIndexes += $i
        }
    }
    if ($foundIndexes.Count -gt 1) { throw "YAML 中存在重复键：$Key。原文件没有被修改。" }
    if ($foundIndexes.Count -eq 0) { return $null }

    $start = [int]$foundIndexes[0]
    $finish = $SearchEnd
    for ($i = $start + 1; $i -lt $SearchEnd; $i++) {
        $line = $Lines[$i]
        if ([string]::IsNullOrWhiteSpace($line)) { continue }
        $lineIndent = Get-YamlIndent $line
        if ($line.TrimStart().StartsWith("#")) {
            if ($lineIndent -le $Indent) { $finish = $i; break }
            continue
        }
        if ($lineIndent -le $Indent) { $finish = $i; break }
    }
    $entry = Get-YamlMappingEntry $Lines[$start]
    $value = if ($null -ne $entry) { $entry.Value } else { "" }
    return [pscustomobject]@{ Start = $start; End = $finish; Value = $value; Indent = $Indent }
}

function Replace-YamlRange([string[]]$Lines, [int]$Start, [int]$End, [string[]]$Replacement) {
    $before = @(if ($Start -gt 0) { $Lines[0..($Start - 1)] })
    $after = @(if ($End -lt $Lines.Count) { $Lines[$End..($Lines.Count - 1)] })
    return @($before + $Replacement + $after)
}

function Set-YamlTopLevelScalar([string]$Text, [string]$Key, [string]$Value) {
    $lines = @(Split-YamlLines $Text)
    $node = Find-YamlMappingNode $lines $Key 0 0 $lines.Count
    $replacement = @("$Key`: $Value")
    if ($null -eq $node) {
        while ($lines.Count -gt 0 -and [string]::IsNullOrWhiteSpace($lines[$lines.Count - 1])) {
            $lines = if ($lines.Count -eq 1) { @() } else { @($lines[0..($lines.Count - 2)]) }
        }
        return (Join-YamlLines -Lines @($lines + $replacement))
    }
    $updated = Replace-YamlRange -Lines $lines -Start $node.Start -End $node.End -Replacement $replacement
    return (Join-YamlLines -Lines $updated)
}

function Get-ManagedTunLines([int]$Indent, [string]$Key) {
    $prefix = " " * $Indent
    switch ($Key) {
        "enable" { return @("${prefix}enable: true") }
        "stack" { return @("${prefix}stack: system") }
        "dns-hijack" { return @("${prefix}dns-hijack:", "${prefix}  - any:53", "${prefix}  - tcp://any:53") }
        "auto-route" { return @("${prefix}auto-route: true") }
        "auto-detect-interface" { return @("${prefix}auto-detect-interface: true") }
        "strict-route" { return @("${prefix}strict-route: true") }
        default { throw "未知的 TUN 设置：$Key" }
    }
}

function New-ManagedTunBlock {
    $lines = @("tun:")
    foreach ($key in @("enable", "stack", "dns-hijack", "auto-route", "auto-detect-interface", "strict-route")) {
        $lines += @(Get-ManagedTunLines 2 $key)
    }
    return $lines
}

function Set-YamlTunMapping([string]$Text) {
    $lines = @(Split-YamlLines $Text)
    $tun = Find-YamlMappingNode $lines "tun" 0 0 $lines.Count
    if ($null -eq $tun) {
        while ($lines.Count -gt 0 -and [string]::IsNullOrWhiteSpace($lines[$lines.Count - 1])) {
            $lines = if ($lines.Count -eq 1) { @() } else { @($lines[0..($lines.Count - 2)]) }
        }
        $replacement = @(New-ManagedTunBlock)
        return (Join-YamlLines -Lines @($lines + $replacement))
    }

    $semanticValue = ($tun.Value -replace '\s+#.*$', '').Trim()
    if ($semanticValue -match '^\{') {
        throw "config.yaml 使用了行内 tun 写法，无法安全合并。原文件没有被修改。"
    }
    if ($semanticValue -ne "" -and $semanticValue -notmatch '^(?:null|~)$') {
        $replacement = @(New-ManagedTunBlock)
        $updated = Replace-YamlRange -Lines $lines -Start $tun.Start -End $tun.End -Replacement $replacement
        return (Join-YamlLines -Lines $updated)
    }
    if ($semanticValue -match '^(?:null|~)$') {
        $replacement = @(New-ManagedTunBlock)
        $updated = Replace-YamlRange -Lines $lines -Start $tun.Start -End $tun.End -Replacement $replacement
        return (Join-YamlLines -Lines $updated)
    }

    $childIndent = 2
    for ($i = $tun.Start + 1; $i -lt $tun.End; $i++) {
        if ([string]::IsNullOrWhiteSpace($lines[$i]) -or $lines[$i].TrimStart().StartsWith("#")) { continue }
        $childIndent = Get-YamlIndent $lines[$i]
        if ($childIndent -le 0) { throw "tun 节点不是有效的 YAML 映射。原文件没有被修改。" }
        break
    }

    foreach ($key in @("enable", "stack", "dns-hijack", "auto-route", "auto-detect-interface", "strict-route")) {
        $tun = Find-YamlMappingNode $lines "tun" 0 0 $lines.Count
        $child = Find-YamlMappingNode $lines $key $childIndent ($tun.Start + 1) $tun.End
        $replacement = @(Get-ManagedTunLines $childIndent $key)
        if ($null -eq $child) {
            $lines = Replace-YamlRange -Lines $lines -Start $tun.End -End $tun.End -Replacement $replacement
        } else {
            $lines = Replace-YamlRange -Lines $lines -Start $child.Start -End $child.End -Replacement $replacement
        }
    }
    return (Join-YamlLines -Lines $lines)
}

function Test-GeneratedYaml([string]$Text, [string]$Label) {
    $lines = @(Split-YamlLines $Text)
    $topKeys = @{}
    for ($i = 0; $i -lt $lines.Count; $i++) {
        $line = $lines[$i]
        if ([string]::IsNullOrWhiteSpace($line) -or $line.TrimStart().StartsWith("#")) { continue }
        if ((Get-YamlIndent $line) -ne 0) { continue }
        $entry = Get-YamlMappingEntry $line
        if ($null -ne $entry) {
            $key = $entry.Key
            if ($topKeys.ContainsKey($key)) { throw "$Label 生成了重复键：$key。" }
            $topKeys[$key] = $true
        }
    }

    if ($Label -eq "config.yaml") {
        foreach ($key in @("ipv6", "tun")) {
            if (-not $topKeys.ContainsKey($key)) { throw "$Label 缺少设置：$key。" }
        }
        $tun = Find-YamlMappingNode $lines "tun" 0 0 $lines.Count
        foreach ($key in @("enable", "stack", "dns-hijack", "auto-route", "auto-detect-interface", "strict-route")) {
            $found = $false
            for ($i = $tun.Start + 1; $i -lt $tun.End; $i++) {
                if ($lines[$i] -match ('^\s+' + [regex]::Escape($key) + '\s*:')) { $found = $true; break }
            }
            if (-not $found) { throw "$Label 缺少 TUN 设置：$key。" }
        }
    }
    return $true
}

function Find-MihomoCore([string]$Root) {
    try {
        $running = Get-Process -Name "verge-mihomo" -ErrorAction SilentlyContinue | Select-Object -First 1
        if ($null -ne $running -and -not [string]::IsNullOrWhiteSpace($running.Path) -and (Test-Path -LiteralPath $running.Path)) {
            return $running.Path
        }
    } catch { }

    $installCandidates = @()
    if (-not [string]::IsNullOrWhiteSpace($env:ProgramFiles)) {
        $installCandidates += (Join-Path (Join-Path $env:ProgramFiles "Clash Verge") "verge-mihomo.exe")
    }
    $programFilesX86 = [Environment]::GetEnvironmentVariable("ProgramFiles(x86)")
    if (-not [string]::IsNullOrWhiteSpace($programFilesX86)) {
        $installCandidates += (Join-Path (Join-Path $programFilesX86 "Clash Verge") "verge-mihomo.exe")
    }
    foreach ($candidate in $installCandidates) {
        if (Test-Path -LiteralPath $candidate -PathType Leaf) { return $candidate }
    }

    $relativeCandidates = @(
        "mihomo.exe",
        "clash-meta.exe",
        "resources\mihomo.exe",
        "resources\clash-meta.exe",
        "service\mihomo.exe"
    )
    foreach ($relative in $relativeCandidates) {
        $candidate = Join-Path $Root $relative
        if (Test-Path -LiteralPath $candidate -PathType Leaf) { return $candidate }
    }
    return $null
}

function Test-MihomoCandidate([string]$CorePath, [string]$Text, [string]$Directory) {
    if ([string]::IsNullOrWhiteSpace($CorePath)) { return }
    if ($Text -notmatch '(?m)^\s*(?:proxy-groups|proxies|proxy-providers)\s*:') { return }
    $temporary = Join-Path $Directory (".clash-patch-validate-" + [System.IO.Path]::GetRandomFileName() + ".yaml")
    try {
        [System.IO.File]::WriteAllText($temporary, $Text, (New-Object System.Text.UTF8Encoding($false)))
        & $CorePath -d $Directory -t -f $temporary *> $null
        if ($LASTEXITCODE -ne 0) { throw "Mihomo 拒绝了生成的 config.yaml。原文件没有被修改。" }
    } finally {
        if (Test-Path -LiteralPath $temporary) { Remove-Item -LiteralPath $temporary -Force }
    }
}

function Restore-Transaction([object[]]$Targets) {
    for ($i = $Targets.Count - 1; $i -ge 0; $i--) {
        $target = $Targets[$i]
        if ($target.Existed) {
            Write-Utf8Atomic $target.Path $target.Original
        } elseif (Test-Path -LiteralPath $target.Path) {
            Remove-Item -LiteralPath $target.Path -Force
        }
    }
}

function Build-GlobalScript([string]$EnginePath, [string]$TargetPath) {
    $engine = Get-Content -LiteralPath $EnginePath -Raw -Encoding UTF8
    $begin = "// CLASH PATCH BEGIN"
    $end = "// CLASH PATCH END"
    $prefix = ""
    $suffix = ""

    if (Test-Path -LiteralPath $TargetPath -PathType Leaf) {
        $current = Get-Content -LiteralPath $TargetPath -Raw -Encoding UTF8
        $beginIndex = $current.IndexOf($begin)
        $endIndex = $current.IndexOf($end)
        if ($beginIndex -ge 0 -or $endIndex -ge 0) {
            if ($beginIndex -lt 0 -or $endIndex -lt $beginIndex -or
                $current.IndexOf($begin, $beginIndex + $begin.Length) -ge 0 -or
                $current.IndexOf($end, $endIndex + $end.Length) -ge 0) {
                throw "检测到不完整或重复的 Clash 补丁标记。原脚本没有被修改。"
            }
            $prefix = $current.Substring(0, $beginIndex).TrimEnd()
            $suffix = $current.Substring($endIndex + $end.Length).Trim()
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
    if (-not [string]::IsNullOrWhiteSpace($suffix)) { $parts += $suffix }
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
    [Console]::Error.WriteLine("[Clash 补丁] 没有找到受支持的 Clash Verge Rev。请安装最新版 Clash Verge Rev，打开一次后再运行 Clash 补丁。")
    exit 2
}

# Clash Verge Rev 的全局扩展脚本位置：profiles/Script.js。
$profilesDirectory = Join-Path $AppHome "profiles"
$vergePath = Join-Path $AppHome "verge.yaml"
$configPath = Join-Path $AppHome "config.yaml"
$targetScript = Join-Path $profilesDirectory "Script.js"
$enginePath = Join-Path (Join-Path $PSScriptRoot "windows") "clash_verge_global.js"

if (-not (Test-Path -LiteralPath $enginePath -PathType Leaf)) {
    [Console]::Error.WriteLine("[Clash 补丁] 安装包不完整：缺少 Windows 全局扩展脚本。")
    exit 3
}

New-Item -ItemType Directory -Path $profilesDirectory -Force | Out-Null

try {
    $scriptOutput = Build-GlobalScript $enginePath $targetScript
    $vergeInput = if (Test-Path -LiteralPath $vergePath) { Get-Content -LiteralPath $vergePath -Raw -Encoding UTF8 } else { "" }
    $vergeOutput = Set-YamlTopLevelScalar $vergeInput "enable_tun_mode" "true"
    $vergeOutput = Set-YamlTopLevelScalar $vergeOutput "enable_dns_settings" "false"
    $configInput = if (Test-Path -LiteralPath $configPath) { Get-Content -LiteralPath $configPath -Raw -Encoding UTF8 } else { "" }
    $configOutput = Set-YamlTopLevelScalar $configInput "ipv6" "false"
    $configOutput = Set-YamlTunMapping $configOutput

    Test-GeneratedYaml $vergeOutput "verge.yaml" | Out-Null
    Test-GeneratedYaml $configOutput "config.yaml" | Out-Null
    $corePath = Find-MihomoCore $AppHome
    Test-MihomoCandidate $corePath $configOutput $AppHome

    $targets = @(
        [pscustomobject]@{ Path = $targetScript; Content = $scriptOutput; Existed = (Test-Path -LiteralPath $targetScript); Original = $(if (Test-Path -LiteralPath $targetScript) { Get-Content -LiteralPath $targetScript -Raw -Encoding UTF8 } else { "" }) },
        [pscustomobject]@{ Path = $vergePath; Content = $vergeOutput; Existed = (Test-Path -LiteralPath $vergePath); Original = $vergeInput },
        [pscustomobject]@{ Path = $configPath; Content = $configOutput; Existed = (Test-Path -LiteralPath $configPath); Original = $configInput }
    )
    foreach ($target in $targets) { Backup-Once $target.Path }

    try {
        foreach ($target in $targets) {
            Write-Utf8Atomic $target.Path $target.Content
        }
    } catch {
        # Restore every target, including the target whose atomic move raised:
        # an interrupted replacement may have changed it before reporting failure.
        Restore-Transaction $targets
        throw
    }

    Write-Info "已安装全局扩展脚本，之后每次加载或刷新订阅都会自动应用补丁。"
    Write-Info "已开启 TUN，并让全局脚本接管 DNS 配置。请在 Clash Verge Rev 中重新加载当前订阅或重启内核。"
    Write-Info "AI 规则会优先选择台湾家宽，其次选择日本家宽；如果两者都没有，不会替你改成其他地区。"
    exit 0
} catch {
    [Console]::Error.WriteLine("[Clash 补丁] 安装失败：$($_.Exception.Message)")
    exit 1
}
