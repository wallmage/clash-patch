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

function Get-InstallStateEntry([object]$State, [string]$Name) {
    if ($null -eq $State) { return $null }
    $property = $State.PSObject.Properties[$Name]
    if ($null -eq $property) { return $null }
    return $property.Value
}

function Assert-InstallStateEntry([object]$Entry, [string]$Label) {
    if ($null -eq $Entry) { throw "安装状态文件无效：缺少 $Label。" }
    if (-not ($Entry.Existed -is [bool])) { throw "安装状态文件无效：$Label.Existed 不是布尔值。" }
    if (-not ($Entry.OriginalBase64 -is [string])) { throw "安装状态文件无效：$Label.OriginalBase64 不是字符串。" }
    if (-not ($Entry.InstalledSha256 -is [string]) -or [string]$Entry.InstalledSha256 -notmatch '^[0-9a-fA-F]{64}$') {
        throw "安装状态文件无效：$Label.InstalledSha256 不是 SHA-256。"
    }
    $encoded = [string]$Entry.OriginalBase64
    try {
        $decoded = [Convert]::FromBase64String($encoded)
    } catch {
        throw "安装状态文件无效：$Label.OriginalBase64 不是 Base64。"
    }
    if ([Convert]::ToBase64String($decoded) -cne $encoded) {
        throw "安装状态文件无效：$Label.OriginalBase64 不是规范 Base64。"
    }
    if (-not [bool]$Entry.Existed -and $encoded.Length -ne 0) {
        throw "安装状态文件无效：$Label 不存在却保存了原始内容。"
    }
}

function Assert-InstallState([object]$State) {
    if ($null -eq $State) { throw "安装状态文件无效。" }
    $version = $State.Version
    $numericVersion = $version -is [int] -or $version -is [long]
    if (-not $numericVersion -or [long]$version -ne 1) { throw "安装状态文件无效：版本不受支持。" }
    Assert-InstallStateEntry (Get-InstallStateEntry $State "VergeYaml") "VergeYaml"
    Assert-InstallStateEntry (Get-InstallStateEntry $State "ConfigYaml") "ConfigYaml"
}

function Get-JavaScriptAnalysis([string]$Text) {
    $mask = New-Object System.Text.StringBuilder
    $markers = @()
    $state = "code"
    $index = 0
    while ($index -lt $Text.Length) {
        $character = [string]$Text[$index]
        $next = if ($index + 1 -lt $Text.Length) { [string]$Text[$index + 1] } else { "" }
        if ($state -eq "code") {
            if ($character -eq "/" -and $next -eq "/") {
                $finish = $index + 2
                while ($finish -lt $Text.Length -and $Text[$finish] -ne "`r" -and $Text[$finish] -ne "`n") { $finish++ }
                $comment = $Text.Substring($index, $finish - $index).Trim()
                if ($comment -eq "// CLASH PATCH BEGIN") {
                    $markers += [pscustomobject]@{ Kind = "begin"; Start = $index; End = $finish }
                } elseif ($comment -eq "// CLASH PATCH END") {
                    $markers += [pscustomobject]@{ Kind = "end"; Start = $index; End = $finish }
                }
                while ($index -lt $finish) { [void]$mask.Append(" "); $index++ }
                continue
            }
            if ($character -eq "/" -and $next -eq "*") {
                $finish = $index + 2
                while ($finish + 1 -lt $Text.Length -and -not ($Text[$finish] -eq "*" -and $Text[$finish + 1] -eq "/")) { $finish++ }
                if ($finish + 1 -ge $Text.Length) { throw "JavaScript 块注释没有结束，原脚本未修改。" }
                $finish += 2
                while ($index -lt $finish) {
                    $masked = [string]$Text[$index]
                    [void]$mask.Append($(if ($masked -eq "`r" -or $masked -eq "`n") { $masked } else { " " }))
                    $index++
                }
                continue
            }
            if ($character -eq "'") { $state = "single"; [void]$mask.Append(" "); $index++; continue }
            if ($character -eq '"') { $state = "double"; [void]$mask.Append(" "); $index++; continue }
            if ($character -eq '`') { $state = "template"; [void]$mask.Append(" "); $index++; continue }
            [void]$mask.Append($character)
            $index++
            continue
        }
        if ($character -eq "\") {
            [void]$mask.Append(" ")
            $index++
            if ($index -lt $Text.Length) {
                $escaped = [string]$Text[$index]
                [void]$mask.Append($(if ($escaped -eq "`r" -or $escaped -eq "`n") { $escaped } else { " " }))
                $index++
            }
            continue
        }
        if (($state -eq "single" -and $character -eq "'") -or
            ($state -eq "double" -and $character -eq '"') -or
            ($state -eq "template" -and $character -eq '`')) {
            $state = "code"
            [void]$mask.Append(" ")
            $index++
            continue
        }
        if (($state -eq "single" -or $state -eq "double") -and ($character -eq "`r" -or $character -eq "`n")) {
            throw "JavaScript 字符串没有结束，原脚本未修改。"
        }
        [void]$mask.Append($(if ($character -eq "`r" -or $character -eq "`n") { $character } else { " " }))
        $index++
    }
    if ($state -ne "code") { throw "JavaScript 字符串没有结束，原脚本未修改。" }
    return [pscustomobject]@{ Code = $mask.ToString(); Markers = @($markers) }
}

function Rename-JavaScriptMain([string]$Text, [string]$From, [string]$To) {
    $analysis = Get-JavaScriptAnalysis $Text
    $pattern = '(?m)^\s*function\s+' + [regex]::Escape($From) + '\s*\('
    $matches = [regex]::Matches($analysis.Code, $pattern)
    if ($matches.Count -ne 1) { throw "无法确认原始 main 函数，原文件未修改。" }
    $relative = $matches[0].Value.IndexOf($From, [StringComparison]::Ordinal)
    $nameIndex = $matches[0].Index + $relative
    return $Text.Substring(0, $nameIndex) + $To + $Text.Substring($nameIndex + $From.Length)
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
    $clientRunning = Test-ClashVergeRunning
    if (Test-Path -LiteralPath $statePath -PathType Leaf) {
        $state = Get-Content -LiteralPath $statePath -Raw -Encoding UTF8 | ConvertFrom-Json
        Assert-InstallState $state
    }

    $scriptChanged = $false
    if (Test-Path -LiteralPath $target -PathType Leaf) {
        $begin = "// CLASH PATCH BEGIN"
        $end = "// CLASH PATCH END"
        $current = Get-Content -LiteralPath $target -Raw -Encoding UTF8
        $analysis = Get-JavaScriptAnalysis $current
        $beginMarkers = @($analysis.Markers | Where-Object { $_.Kind -eq "begin" })
        $endMarkers = @($analysis.Markers | Where-Object { $_.Kind -eq "end" })
        if ($beginMarkers.Count -gt 0 -or $endMarkers.Count -gt 0) {
            if ($beginMarkers.Count -ne 1 -or $endMarkers.Count -ne 1 -or $endMarkers[0].Start -lt $beginMarkers[0].Start) {
                throw "Script.js 标记不完整或重复，原文件未修改。"
            }
            $managedBlock = $current.Substring($beginMarkers[0].Start, $endMarkers[0].End - $beginMarkers[0].Start)
            if (-not $managedBlock.Contains("CLASH PATCH POLICY BEGIN") -or -not $managedBlock.Contains("function clashPatchTransform")) {
                throw "Script.js 中的同名标记不是本工具创建的，原文件未修改。"
            }

            $prefix = $current.Substring(0, $beginMarkers[0].Start).TrimEnd()
            $suffix = $current.Substring($endMarkers[0].End).Trim()
            if (-not [string]::IsNullOrWhiteSpace($prefix)) {
                $prefix = (Rename-JavaScriptMain $prefix "clashPatchPreviousMain" "main").TrimEnd()
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
    if ($null -ne $state -and -not $clientRunning) {
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
    } elseif ($null -ne $state) {
        $settingsRestored = $false
        Write-Info "Clash Verge Rev 保持运行；config.yaml 与 verge.yaml 未改动，安装状态文件继续保留。"
    }

    if (-not $scriptChanged -and $null -eq $state) {
        Write-Info "没有发现已安装的自动补丁，无需移除。"
        exit 0
    }
    if (-not $settingsRestored -and -not $clientRunning) { throw "部分设置在安装后有新改动，未自动覆盖；请根据保留的安装状态文件手动处理。" }

    if ($clientRunning) {
        Write-Info "全局自动补丁已移除；客户端保持运行，应用设置和现有备份均未改动。"
    } else {
        Write-Info "全局自动补丁已移除，config.yaml 与 verge.yaml 已恢复到安装前状态。现有备份没有删除。"
    }
    exit 0
} catch {
    [Console]::Error.WriteLine("[Clash 补丁] 卸载失败：$($_.Exception.Message)")
    exit 1
}
