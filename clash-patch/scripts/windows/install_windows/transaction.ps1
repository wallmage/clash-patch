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
function Get-PathKey([string]$Path) {
    $absolute = [System.IO.Path]::GetFullPath($Path)
    $bytes = [System.Text.Encoding]::UTF8.GetBytes($absolute)
    $sha = [System.Security.Cryptography.SHA256]::Create()
    try {
        return (($sha.ComputeHash($bytes) | ForEach-Object { $_.ToString("x2") }) -join '').Substring(0, 16)
    } finally {
        $sha.Dispose()
    }
}

function Backup-Versioned([string]$Path, [string]$BackupRoot, [string]$Reason = "prewrite") {
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { return }
    if ($Reason -notmatch '^[a-z][a-z0-9-]{0,31}$') { throw "备份原因无效。" }
    if (-not (Test-Path -LiteralPath $BackupRoot -PathType Container)) {
        New-Item -ItemType Directory -Path $BackupRoot -Force | Out-Null
    }
    $key = Get-PathKey $Path
    $basename = Split-Path -Leaf $Path
    $stamp = (Get-Date).ToString("yyyy-MM-dd_HH-mm-ss.fffffffzzz").Replace(":", "")
    $destination = Join-Path $BackupRoot ("$stamp--$Reason--$key--$basename.backup")
    $sourceStream = $null
    $backupStream = $null
    $created = $false
    $failure = $null
    try {
        $sourceStream = [System.IO.File]::Open($Path, [System.IO.FileMode]::Open, [System.IO.FileAccess]::Read, [System.IO.FileShare]::Read)
        $backupStream = [System.IO.File]::Open($destination, [System.IO.FileMode]::CreateNew, [System.IO.FileAccess]::Write, [System.IO.FileShare]::None)
        $created = $true
        $sourceStream.CopyTo($backupStream)
        $backupStream.Flush()
    } catch {
        $failure = $_
    } finally {
        if ($null -ne $backupStream) { $backupStream.Dispose() }
        if ($null -ne $sourceStream) { $sourceStream.Dispose() }
    }
    if ($null -ne $failure) {
        if ($created -and (Test-Path -LiteralPath $destination -PathType Leaf)) {
            Remove-Item -LiteralPath $destination -Force
        }
        throw $failure
    }
    try {
        Protect-BackupAcl $destination
    } catch {
        if ($created -and (Test-Path -LiteralPath $destination -PathType Leaf)) {
            Remove-Item -LiteralPath $destination -Force
        }
        throw
    }
    return $destination
}

function Backup-InitialOnce([string]$Path, [string]$BackupRoot) {
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { return }
    $key = Get-PathKey $Path
    $basename = Split-Path -Leaf $Path
    if (Test-Path -LiteralPath $BackupRoot -PathType Container) {
        $existing = Get-ChildItem -LiteralPath $BackupRoot -File | Where-Object {
            $_.Name -like "*--initial--$key--$basename.backup"
        } | Select-Object -First 1
        if ($null -ne $existing) { return }
    }
    return (Backup-Versioned $Path $BackupRoot "initial")
}

function Write-BytesAtomic([string]$Path, [byte[]]$Bytes) {
    if (Test-Path -LiteralPath $Path -PathType Container) { throw "目标路径是目录，不能写入：$Path" }
    $directory = Split-Path -Parent $Path
    $temporary = Join-Path $directory (".clash-patch-" + [System.IO.Path]::GetRandomFileName())
    try {
        [System.IO.File]::WriteAllBytes($temporary, $Bytes)
        Move-Item -LiteralPath $temporary -Destination $Path -Force
    } finally {
        if (Test-Path -LiteralPath $temporary) { Remove-Item -LiteralPath $temporary -Force }
    }
}

function ConvertTo-Utf8Bytes([string]$Content) {
    return (New-Object System.Text.UTF8Encoding($false)).GetBytes($Content)
}

function Write-Utf8Atomic([string]$Path, [string]$Content) {
    Write-BytesAtomic $Path (ConvertTo-Utf8Bytes $Content)
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


function Restore-Transaction([object[]]$Targets) {
    $failures = @()
    for ($i = $Targets.Count - 1; $i -ge 0; $i--) {
        $target = $Targets[$i]
        try {
            if ($target.Existed) {
                Write-BytesAtomic $target.Path $target.OriginalBytes
            } elseif (Test-Path -LiteralPath $target.Path) {
                Remove-Item -LiteralPath $target.Path -Force
            }
        } catch {
            $failures += "$($target.Path)：$($_.Exception.Message)"
        }
    }
    if ($failures.Count -gt 0) { throw ("回滚未能恢复所有文件：" + ($failures -join "；")) }
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

function Assert-StateTargetUnchanged([object]$Entry, [string]$Path, [string]$Label) {
    if ($null -eq $Entry) { return }
    $expected = [string]$Entry.InstalledSha256
    $actual = Get-FileSha256 $Path
    if ($actual -ne $expected) {
        throw "$Label 在上次安装后被其他程序修改。为避免覆盖这些改动，请先卸载补丁或备份并手动处理该文件。"
    }
}

function New-InstallStateEntry([object]$Previous, [string]$Path, [byte[]]$InstalledBytes) {
    if ($null -ne $Previous) {
        $existed = [bool]$Previous.Existed
        $originalBase64 = [string]$Previous.OriginalBase64
    } else {
        $existed = Test-Path -LiteralPath $Path -PathType Leaf
        $originalBase64 = if ($existed) { [Convert]::ToBase64String([System.IO.File]::ReadAllBytes($Path)) } else { "" }
    }
    return [ordered]@{
        Existed = $existed
        OriginalBase64 = $originalBase64
        InstalledSha256 = (Get-BytesSha256 $InstalledBytes)
    }
}
