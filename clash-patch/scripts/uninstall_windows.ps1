param(
    [string]$AppHome = ""
)

$ErrorActionPreference = "Stop"

function Write-Info([string]$Message) {
    Write-Host "[Clash 补丁] $Message"
}

function Write-Utf8Atomic([string]$Path, [string]$Content) {
    $directory = Split-Path -Parent $Path
    $temporary = Join-Path $directory (".clash-patch-uninstall-" + [System.IO.Path]::GetRandomFileName())
    try {
        [System.IO.File]::WriteAllText($temporary, $Content, (New-Object System.Text.UTF8Encoding($false)))
        Move-Item -LiteralPath $temporary -Destination $Path -Force
    } finally {
        if (Test-Path -LiteralPath $temporary) { Remove-Item -LiteralPath $temporary -Force }
    }
}

if ([string]::IsNullOrWhiteSpace($AppHome)) {
    $candidates = @(
        (Join-Path $env:APPDATA "io.github.clash-verge-rev.clash-verge-rev"),
        (Join-Path $env:LOCALAPPDATA "io.github.clash-verge-rev.clash-verge-rev")
    )
    $AppHome = $candidates | Where-Object { Test-Path -LiteralPath $_ -PathType Container } | Select-Object -First 1
}

if ([string]::IsNullOrWhiteSpace($AppHome)) {
    [Console]::Error.WriteLine("[Clash 补丁] 没有找到 Clash Verge Rev 配置目录。")
    exit 2
}

$target = Join-Path (Join-Path $AppHome "profiles") "Script.js"
if (-not (Test-Path -LiteralPath $target -PathType Leaf)) {
    Write-Info "没有发现已安装的全局自动补丁，无需移除。"
    exit 0
}

$begin = "// CLASH PATCH BEGIN"
$end = "// CLASH PATCH END"
$current = Get-Content -LiteralPath $target -Raw -Encoding UTF8
$beginIndex = $current.IndexOf($begin)
$endIndex = $current.IndexOf($end)
if ($beginIndex -lt 0 -and $endIndex -lt 0) {
    Write-Info "Script.js 中没有 Clash 补丁标记，原文件未修改。"
    exit 0
}
if ($beginIndex -lt 0 -or $endIndex -lt $beginIndex -or
    $current.IndexOf($begin, $beginIndex + $begin.Length) -ge 0 -or
    $current.IndexOf($end, $endIndex + $end.Length) -ge 0) {
    [Console]::Error.WriteLine("[Clash 补丁] Script.js 标记不完整或重复，已停止，原文件未修改。")
    exit 1
}

$stamp = Get-Date -Format "yyyyMMdd-HHmmss"
Copy-Item -LiteralPath $target -Destination "$target.clash-patch-uninstall.$stamp.backup"
$prefix = $current.Substring(0, $beginIndex).TrimEnd()
$suffixStart = $endIndex + $end.Length
$suffix = $current.Substring($suffixStart).Trim()

if (-not [string]::IsNullOrWhiteSpace($prefix)) {
    $matches = [regex]::Matches($prefix, '(?m)^\s*function\s+clashPatchPreviousMain\s*\(')
    if ($matches.Count -ne 1) {
        [Console]::Error.WriteLine("[Clash 补丁] 无法确认原始 main 函数，已停止，原文件未修改。")
        exit 1
    }
    $prefix = [regex]::Replace($prefix, '(?m)^\s*function\s+clashPatchPreviousMain\s*\(', 'function main(', 1).TrimEnd()
}

$remaining = @($prefix, $suffix) | Where-Object { -not [string]::IsNullOrWhiteSpace($_) }
if ($remaining.Count -eq 0) {
    Remove-Item -LiteralPath $target -Force
} else {
    Write-Utf8Atomic $target (($remaining -join "`r`n`r`n") + "`r`n")
}

Write-Info "全局自动补丁已移除。现有备份没有删除。"
Write-Info "已经写入 config.yaml 的 TUN 设置不会自动撤销。"
exit 0
