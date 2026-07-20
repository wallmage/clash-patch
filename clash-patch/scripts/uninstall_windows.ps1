param(
    [string]$AppHome = ""
)

$ErrorActionPreference = "Stop"

function Write-Info([string]$Message) {
    Write-Host "[Clash 补丁] $Message"
}

function Protect-BackupAcl([string]$Path) {
    if ([Environment]::OSVersion.Platform -ne [PlatformID]::Win32NT) { return }

    $security = Get-Acl -LiteralPath $Path
    $security.SetAccessRuleProtection($true, $false)
    @($security.Access) | Where-Object { -not $_.IsInherited } | ForEach-Object {
        $security.RemoveAccessRuleSpecific($_)
    }
    $sidValues = @(
        [System.Security.Principal.WindowsIdentity]::GetCurrent().User.Value,
        "S-1-5-18",
        "S-1-5-32-544"
    ) | Select-Object -Unique
    foreach ($sidValue in $sidValues) {
        $sid = New-Object System.Security.Principal.SecurityIdentifier($sidValue)
        $rule = New-Object System.Security.AccessControl.FileSystemAccessRule(
            $sid,
            [System.Security.AccessControl.FileSystemRights]::FullControl,
            [System.Security.AccessControl.AccessControlType]::Allow
        )
        $security.AddAccessRule($rule) | Out-Null
    }
    Set-Acl -LiteralPath $Path -AclObject $security
}

function New-UninstallBackup([string]$Path) {
    $stamp = Get-Date -Format "yyyyMMdd-HHmmss-fff"
    $nonce = [System.Guid]::NewGuid().ToString("N").Substring(0, 12)
    $destination = "$Path.clash-patch-uninstall.$stamp-$nonce.backup"
    [System.IO.File]::Copy($Path, $destination, $false)
    try {
        Protect-BackupAcl $destination
    } catch {
        if (Test-Path -LiteralPath $destination -PathType Leaf) {
            Remove-Item -LiteralPath $destination -Force
        }
        throw
    }
    return $destination
}

function Write-BytesAtomic([string]$Path, [byte[]]$Bytes) {
    if (Test-Path -LiteralPath $Path -PathType Container) { throw "目标路径是目录，不能写入：$Path" }
    $directory = Split-Path -Parent $Path
    $temporary = Join-Path $directory (".clash-patch-uninstall-" + [System.IO.Path]::GetRandomFileName())
    try {
        [System.IO.File]::WriteAllBytes($temporary, $Bytes)
        Move-Item -LiteralPath $temporary -Destination $Path -Force
    } finally {
        if (Test-Path -LiteralPath $temporary) { Remove-Item -LiteralPath $temporary -Force }
    }
}

function Write-Utf8Atomic([string]$Path, [string]$Content) {
    $bytes = (New-Object System.Text.UTF8Encoding($false)).GetBytes($Content)
    Write-BytesAtomic $Path $bytes
}

function Get-BytesSha256([byte[]]$Bytes) {
    $sha = [System.Security.Cryptography.SHA256]::Create()
    try {
        return ([System.BitConverter]::ToString($sha.ComputeHash($Bytes))).Replace("-", "").ToLowerInvariant()
    } finally {
        $sha.Dispose()
    }
}

function Get-FileSha256([string]$Path) {
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { return "" }
    return (Get-BytesSha256 ([System.IO.File]::ReadAllBytes($Path)))
}

function Restore-InstalledSetting([object]$Entry, [string]$Path, [string]$Label) {
    if ($null -eq $Entry) { return $true }
    $expected = [string]$Entry.InstalledSha256
    $current = Get-FileSha256 $Path
    if ([bool]$Entry.Existed) {
        $originalBytes = [Convert]::FromBase64String([string]$Entry.OriginalBase64)
        if ($current -eq (Get-BytesSha256 $originalBytes)) { return $true }
    } elseif ([string]::IsNullOrEmpty($current)) {
        return $true
    }
    if ($current -ne $expected) {
        Write-Info "$Label 在安装后有新改动，未自动覆盖；安装状态文件将保留。"
        return $false
    }
    if ([bool]$Entry.Existed) {
        Write-BytesAtomic $Path $originalBytes
    } elseif (Test-Path -LiteralPath $Path) {
        Remove-Item -LiteralPath $Path -Force
    }
    return $true
}

function Test-ClashVergeRunning {
    foreach ($name in @("clash-verge", "clash-verge-rev", "Clash Verge", "Clash Verge Rev")) {
        if ($null -ne (Get-Process -Name $name -ErrorAction SilentlyContinue | Select-Object -First 1)) { return $true }
    }
    return $false
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
$vergePath = Join-Path $AppHome "verge.yaml"
$configPath = Join-Path $AppHome "config.yaml"
$statePath = Join-Path $AppHome "clash-patch-install-state.json"
$state = $null

try {
    if (Test-ClashVergeRunning) { throw "Clash Verge Rev 仍在运行。请先从托盘菜单完全退出客户端，再重新卸载。" }
    if (Test-Path -LiteralPath $statePath -PathType Leaf) {
        $state = Get-Content -LiteralPath $statePath -Raw -Encoding UTF8 | ConvertFrom-Json
        if ($null -eq $state -or [int]$state.Version -ne 1) { throw "安装状态文件无效，无法安全恢复原始设置。" }
    }

    $scriptChanged = $false
    if (Test-Path -LiteralPath $target -PathType Leaf) {
        $begin = "// CLASH PATCH BEGIN"
        $end = "// CLASH PATCH END"
        $current = Get-Content -LiteralPath $target -Raw -Encoding UTF8
        $beginIndex = $current.IndexOf($begin)
        $endIndex = $current.IndexOf($end)
        if ($beginIndex -ge 0 -or $endIndex -ge 0) {
            if ($beginIndex -lt 0 -or $endIndex -lt $beginIndex -or
                $current.IndexOf($begin, $beginIndex + $begin.Length) -ge 0 -or
                $current.IndexOf($end, $endIndex + $end.Length) -ge 0) {
                throw "Script.js 标记不完整或重复，原文件未修改。"
            }

            $prefix = $current.Substring(0, $beginIndex).TrimEnd()
            $suffix = $current.Substring($endIndex + $end.Length).Trim()
            if (-not [string]::IsNullOrWhiteSpace($prefix)) {
                $matches = [regex]::Matches($prefix, '(?m)^\s*function\s+clashPatchPreviousMain\s*\(')
                if ($matches.Count -ne 1) { throw "无法确认原始 main 函数，原文件未修改。" }
                $prefix = [regex]::Replace($prefix, '(?m)^\s*function\s+clashPatchPreviousMain\s*\(', 'function main(', 1).TrimEnd()
            }
            $remaining = @($prefix, $suffix) | Where-Object { -not [string]::IsNullOrWhiteSpace($_) }
            New-UninstallBackup $target | Out-Null
            if ($remaining.Count -eq 0) {
                Remove-Item -LiteralPath $target -Force
            } else {
                Write-Utf8Atomic $target (($remaining -join "`r`n`r`n") + "`r`n")
            }
            $scriptChanged = $true
        }
    }

    $settingsRestored = $true
    if ($null -ne $state) {
        $settingTargets = @(
            [pscustomobject]@{ Entry = $state.ConfigYaml; Path = $configPath; Label = "config.yaml" },
            [pscustomobject]@{ Entry = $state.VergeYaml; Path = $vergePath; Label = "verge.yaml" }
        )
        foreach ($settingTarget in $settingTargets) {
            try {
                if (-not (Restore-InstalledSetting $settingTarget.Entry $settingTarget.Path $settingTarget.Label)) {
                    $settingsRestored = $false
                }
            } catch {
                Write-Info "$($settingTarget.Label) 恢复失败：$($_.Exception.Message)"
                $settingsRestored = $false
            }
        }
        if ($settingsRestored) { Remove-Item -LiteralPath $statePath -Force }
    }

    if (-not $scriptChanged -and $null -eq $state) {
        Write-Info "没有发现已安装的自动补丁，无需移除。"
        exit 0
    }
    if (-not $settingsRestored) { throw "部分设置在安装后有新改动，未自动覆盖；请根据保留的安装状态文件手动处理。" }

    Write-Info "全局自动补丁已移除，config.yaml 与 verge.yaml 已恢复到安装前状态。现有备份没有删除。"
    exit 0
} catch {
    [Console]::Error.WriteLine("[Clash 补丁] 卸载失败：$($_.Exception.Message)")
    exit 1
}
