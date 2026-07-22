function Get-BackupTarget([string]$BackupId) {
    if ([string]::IsNullOrWhiteSpace($BackupId) -or $BackupId -ne (Split-Path -Leaf $BackupId) -or $BackupId -notlike "*.backup") {
        throw "备份编号无效。"
    }
    $backupPath = Join-Path $backupRoot $BackupId
    if (-not (Test-Path -LiteralPath $backupPath -PathType Leaf)) { throw "找不到指定备份。" }
    if ($BackupId -notmatch '--([0-9a-f]{16})--(.+)\.backup$') { throw "备份编号无效。" }
    $key = $Matches[1]
    $basename = $Matches[2]
    $candidates = @($targetScript, $profilesIndexPath, $vergePath, $configPath, $statePath, $usageStatePath, $safeUpdateStatePath)
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
    $text = [System.Text.Encoding]::UTF8.GetString($Bytes)
    if ($extension -eq ".json") {
        $null = $text | ConvertFrom-Json
        return
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
    foreach ($recovery in $RecoveryItems) {
        try {
            if (-not $ObservedHashes.ContainsKey($recovery.TargetPath) -or -not (Test-Path -LiteralPath $recovery.TargetPath -PathType Leaf)) {
                $conflicts += $recovery.File
                continue
            }
            $backupBytes = [System.IO.File]::ReadAllBytes($recovery.BackupPath)
            $stream = [System.IO.File]::Open(
                $recovery.TargetPath,
                [System.IO.FileMode]::Open,
                [System.IO.FileAccess]::ReadWrite,
                [System.IO.FileShare]::None
            )
            try {
                $hasher = [System.Security.Cryptography.SHA256]::Create()
                try { $currentSha = ([System.BitConverter]::ToString($hasher.ComputeHash($stream))).Replace("-", "").ToLowerInvariant() } finally { $hasher.Dispose() }
                if ($currentSha -ne [string]$ObservedHashes[$recovery.TargetPath]) {
                    $conflicts += $recovery.File
                    continue
                }
                $stream.Position = 0
                $stream.SetLength(0)
                $stream.Write($backupBytes, 0, $backupBytes.Length)
                $stream.Flush($true)
                $stream.Position = 0
                $hasher = [System.Security.Cryptography.SHA256]::Create()
                try { $restoredSha = ([System.BitConverter]::ToString($hasher.ComputeHash($stream))).Replace("-", "").ToLowerInvariant() } finally { $hasher.Dispose() }
                if ($restoredSha -ne $recovery.BeforeSha256) { throw "恢复后哈希不匹配。" }
            } finally {
                $stream.Dispose()
            }
        } catch {
            $failures += $recovery.File
        }
    }
    return [pscustomobject]@{ Failures = @($failures); Conflicts = @($conflicts) }
}
