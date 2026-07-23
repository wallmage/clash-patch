function Get-BackupTarget([string]$BackupId) {
    if ([string]::IsNullOrWhiteSpace($BackupId) -or $BackupId -ne (Split-Path -Leaf $BackupId) -or $BackupId -notlike "*.backup") {
        throw "备份编号无效。"
    }
    $backupPath = Join-Path $backupRoot $BackupId
    if (-not (Test-Path -LiteralPath $backupPath -PathType Leaf)) { throw "找不到指定备份。" }
    if ($BackupId -notmatch '--([0-9a-f]{16})--(.+)\.backup$') { throw "备份编号无效。" }
    $key = $Matches[1]
    $basename = $Matches[2]
    $candidates = @($targetScript, $profilesIndexPath, $vergePath, $configPath)
    if (Test-Path -LiteralPath $profilesDirectory -PathType Container) {
        $candidates += @(Get-ChildItem -LiteralPath $profilesDirectory -File | ForEach-Object { $_.FullName })
    }
    $matches = @($candidates | Select-Object -Unique | Where-Object {
        (Test-Path -LiteralPath $_ -PathType Leaf) -and
        (Split-Path -Leaf $_) -eq $basename -and
        (Get-PathKey $_) -eq $key
    })
    if ($matches.Count -ne 1) { throw "备份无法对应到唯一的当前配置。" }
    return [pscustomobject]@{ BackupPath = $backupPath; TargetPath = $matches[0] }
}

function Test-RestoreCandidate([string]$TargetPath, [byte[]]$Bytes) {
    $leaf = Split-Path -Leaf $TargetPath
    $extension = [System.IO.Path]::GetExtension($TargetPath).ToLowerInvariant()
    $text = (New-Object System.Text.UTF8Encoding($false, $true)).GetString($Bytes)
    if ($extension -eq ".json") {
        throw "内部状态文件不能通过单文件备份恢复。"
    }
    if ($extension -notin @(".yaml", ".yml")) { return }

    Test-GeneratedYaml $text $leaf | Out-Null
    if ($TargetPath -eq $profilesIndexPath -or $TargetPath -eq $vergePath) { return }
    $core = Find-MihomoCore $MihomoPath
    Test-MihomoCandidate $core $text (Split-Path -Parent $TargetPath)
}

function Get-SafeUpdateRecoveryItems([object]$Manifest, [string]$Directory, [string]$BackupDirectory) {
    $items = @()
    foreach ($item in @($Manifest.Profiles)) {
        $properties = @($item.PSObject.Properties.Name | Sort-Object)
        if (($properties -join ",") -cne "Backup,BeforeSha256,File,Uid" -or
            -not ($item.Uid -is [string]) -or
            -not ($item.File -is [string]) -or
            -not ($item.Backup -is [string]) -or
            -not ($item.BeforeSha256 -is [string])) {
            throw "安全更新准备记录包含无效订阅项。"
        }
        $uid = [string]$item.Uid
        $file = [string]$item.File
        $backup = [string]$item.Backup
        $beforeSha = ([string]$item.BeforeSha256).ToLowerInvariant()
        if ($uid -notmatch '^[A-Za-z0-9._-]+$' -or $file -notin @("$uid.yaml", "$uid.yml")) {
            throw "安全更新准备记录包含无效订阅标识。"
        }
        if ($backup -ne (Split-Path -Leaf $backup) -or $backup -notlike "*.backup" -or $beforeSha -notmatch '^[0-9a-f]{64}$') {
            throw "安全更新准备记录包含无效备份信息。"
        }
        $targetPath = Join-Path $Directory $file
        $expectedSuffix = "--$(Get-PathKey $targetPath)--$file.backup"
        if (-not $backup.EndsWith($expectedSuffix)) { throw "安全更新准备记录中的备份与订阅不匹配。" }
        $backupPath = Join-Path $BackupDirectory $backup
        if (-not (Test-Path -LiteralPath $backupPath -PathType Leaf) -or (Get-FileSha256 $backupPath) -ne $beforeSha) {
            throw "安全更新前备份缺失或哈希不匹配。"
        }
        $items += [pscustomobject]@{ Uid = $uid; File = $file; TargetPath = $targetPath; BackupPath = $backupPath; BeforeSha256 = $beforeSha }
    }
    if ($items.Count -eq 0 -or @($items.TargetPath | Sort-Object -Unique).Count -ne $items.Count) {
        throw "安全更新准备记录中的订阅清单无效。"
    }
    return @($items)
}

function Restore-SafeUpdateFiles([object[]]$RecoveryItems, [hashtable]$ObservedHashes) {
    $failures = @()
    $conflicts = @()
    $targets = @()
    foreach ($recovery in $RecoveryItems) {
        try {
            if (-not $ObservedHashes.ContainsKey($recovery.TargetPath)) {
                $conflicts += $recovery.File
                continue
            }
            $backupSnapshot = Get-OptionalFileSnapshot $recovery.BackupPath "安全更新备份"
            if (-not $backupSnapshot.Exists -or
                (Get-BytesSha256 $backupSnapshot.Bytes) -ne [string]$recovery.BeforeSha256) {
                throw "安全更新备份在恢复前发生变化。"
            }
            $targetSnapshot = Get-OptionalFileSnapshot $recovery.TargetPath "更新后的订阅"
            if (-not $targetSnapshot.Exists -or
                (Get-BytesSha256 $targetSnapshot.Bytes) -ne [string]$ObservedHashes[$recovery.TargetPath]) {
                $conflicts += $recovery.File
                continue
            }
            $targets += [pscustomobject]@{
                Path = $recovery.TargetPath
                Bytes = $backupSnapshot.Bytes
                Existed = $true
                OriginalBytes = $targetSnapshot.Bytes
                OriginalIdentity = $targetSnapshot.Identity
            }
        } catch {
            $failures += $recovery.File
        }
    }
    if ($failures.Count -eq 0 -and $conflicts.Count -eq 0) {
        try {
            Invoke-VerifiedFileTransaction $targets
        } catch {
            $failures = @($RecoveryItems | ForEach-Object { $_.File })
        }
    }
    return [pscustomobject]@{ Failures = @($failures); Conflicts = @($conflicts) }
}
