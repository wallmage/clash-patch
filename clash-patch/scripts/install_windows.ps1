param(
    [string]$AppHome = "",
    [string]$MihomoPath = "",
    [int]$UsageProfile = 0,
    [switch]$ShowUsageProfile,
    [switch]$SnapshotProfiles,
    [switch]$VerifySafeUpdate,
    [switch]$ListBackups,
    [string]$CompareBackup = "",
    [string]$RestoreBackup = "",
    [string]$ExpectedCurrentSha256 = "",
    [switch]$Json
)

$ErrorActionPreference = "Stop"
$resultContractPath = Join-Path (Join-Path $PSScriptRoot "windows") "result_contract.ps1"
if (-not (Test-Path -LiteralPath $resultContractPath -PathType Leaf)) {
    if ($Json) {
        [Console]::Out.WriteLine('{"schema":"clash-patch.result","version":1,"command":"install","platform":"windows","client":"clash-verge-rev","operation":"load","ok":false,"status":"failed","code":"incomplete_package","exit_code":6,"summary_zh":"安装包不完整。","profile":null,"changes":[],"checks":[],"items":[],"messages":[],"warnings":[]}')
    } else {
        [Console]::Error.WriteLine("[Clash 补丁] 安装包不完整。")
    }
    exit 6
}
. $resultContractPath
$script:ClashPatchMessages = New-Object System.Collections.ArrayList
$script:ClashPatchOperation = if ($SnapshotProfiles) { "snapshot_profiles" } elseif ($VerifySafeUpdate) { "verify_safe_update" } elseif ($ListBackups) { "list_backups" } elseif (-not [string]::IsNullOrWhiteSpace($CompareBackup)) { "compare_backup" } elseif (-not [string]::IsNullOrWhiteSpace($RestoreBackup)) { "restore_backup" } elseif ($ShowUsageProfile) { "show_usage_profile" } else { "install" }
$script:ClashPatchProfile = $null

$installerModuleRoot = Join-Path (Join-Path $PSScriptRoot "windows") "install_windows"
$installerModules = @(
    "common.ps1",
    "yaml.ps1",
    "profiles.ps1",
    "mihomo.ps1",
    "transaction.ps1",
    "script_js.ps1",
    "safe_update.ps1"
)
try {
    foreach ($installerModule in $installerModules) {
        $installerModulePath = Join-Path $installerModuleRoot $installerModule
        if (-not (Test-Path -LiteralPath $installerModulePath -PathType Leaf)) {
            throw "安装包不完整：缺少 Windows 安装模块。"
        }
        . $installerModulePath
    }
} catch {
    if ($Json) {
        Write-ClashPatchResult (New-ClashPatchResult -Command "install" -Operation "load" -Ok $false -Status "failed" -Code "incomplete_package" -ExitCode 6 -SummaryZh "安装包不完整。")
    } else {
        [Console]::Error.WriteLine("[Clash 补丁] 安装包不完整。")
    }
    exit 6
}

if ([string]::IsNullOrWhiteSpace($AppHome)) {
    $candidates = @(
        (Join-Path $env:APPDATA "io.github.clash-verge-rev.clash-verge-rev"),
        (Join-Path $env:LOCALAPPDATA "io.github.clash-verge-rev.clash-verge-rev")
    )
    $AppHome = $candidates | Where-Object { Test-Path -LiteralPath $_ -PathType Container } | Select-Object -First 1
}

if ([string]::IsNullOrWhiteSpace($AppHome) -or -not (Test-Path -LiteralPath $AppHome -PathType Container)) {
    if (-not $Json) { [Console]::Error.WriteLine("[Clash 补丁] 没有找到受支持的 Clash Verge Rev。请安装最新版 Clash Verge Rev，打开一次后再运行 Clash 补丁。") }
    Complete-InstallResult 2 "unsupported" "client_not_found" "没有找到受支持的 Clash Verge Rev。"
    exit 2
}

# Clash Verge Rev 的全局扩展脚本位置：profiles/Script.js。
$profilesDirectory = Join-Path $AppHome "profiles"
$backupRoot = Join-Path $AppHome "clash-patch-backups"
$profilesIndexPath = Join-Path $AppHome "profiles.yaml"
$vergePath = Join-Path $AppHome "verge.yaml"
$configPath = Join-Path $AppHome "config.yaml"
$statePath = Join-Path $AppHome "clash-patch-install-state.json"
$usageStatePath = Join-Path $AppHome "clash-patch-usage-profile.json"
$safeUpdateStatePath = Join-Path $AppHome "clash-patch-safe-update.json"
$targetScript = Join-Path $profilesDirectory "Script.js"

try {
if ($SnapshotProfiles) {
    if (Test-Path -LiteralPath $safeUpdateStatePath -PathType Leaf) {
        throw "发现尚未验收的安全更新；请先运行 -VerifySafeUpdate，不能覆盖更新前清单。"
    }
    if (-not (Test-Path -LiteralPath $profilesIndexPath -PathType Leaf)) { throw "找不到远程订阅清单。" }
    $indexText = Get-Content -LiteralPath $profilesIndexPath -Raw -Encoding UTF8
    $profiles = @(Get-RemoteSubscriptionTargets $indexText $profilesDirectory)
    $manifestItems = @()
    foreach ($profile in $profiles) {
        Backup-InitialOnce $profile.Path $backupRoot | Out-Null
        $backup = Backup-Versioned $profile.Path $backupRoot "pre-update"
        $manifestItems += [ordered]@{
            Uid = $profile.Uid
            File = (Split-Path -Leaf $profile.Path)
            BeforeSha256 = (Get-FileSha256 $profile.Path)
            Backup = (Split-Path -Leaf $backup)
        }
    }
    $manifest = [ordered]@{ Version = 1; CreatedAt = [DateTimeOffset]::Now.ToString("o"); Profiles = $manifestItems }
    $manifestBytes = ConvertTo-Utf8Bytes (($manifest | ConvertTo-Json -Depth 5) + "`r`n")
    Write-BytesAtomic $safeUpdateStatePath $manifestBytes
    Write-Info "已核对远程清单，并为 $($profiles.Count) 份订阅创建安全更新前备份。"
    foreach ($profile in $profiles) { Write-Info ("待更新：" + $(if ([string]::IsNullOrWhiteSpace($profile.Name)) { $profile.Uid } else { $profile.Name })) }
    Complete-InstallResult 0 "ok" "snapshot_created" "已创建全部远程订阅的安全更新前备份。" @("profile_backups")
}

if ($VerifySafeUpdate) {
    if (-not (Test-Path -LiteralPath $safeUpdateStatePath -PathType Leaf)) { throw "没有找到本次安全更新的准备记录。" }
    $manifest = Get-Content -LiteralPath $safeUpdateStatePath -Raw -Encoding UTF8 | ConvertFrom-Json
    if ([int]$manifest.Version -ne 1 -or @($manifest.Profiles).Count -eq 0) { throw "安全更新准备记录无效。" }
    $recoveryItems = @(Get-SafeUpdateRecoveryItems $manifest $profilesDirectory $backupRoot)
    $validated = @()
    $observedCurrentHashes = @{}
    try {
        foreach ($recovery in $recoveryItems) {
            if (-not (Test-Path -LiteralPath $recovery.TargetPath -PathType Leaf)) { throw "更新后的订阅文件缺失。" }
            $observedCurrentHashes[$recovery.TargetPath] = Get-FileSha256 $recovery.TargetPath
        }
        $indexText = Get-Content -LiteralPath $profilesIndexPath -Raw -Encoding UTF8
        $currentTargets = @(Get-RemoteSubscriptionTargets $indexText $profilesDirectory)
        if ($currentTargets.Count -ne $recoveryItems.Count) { throw "远程订阅清单在更新期间发生变化。" }
        $core = Find-MihomoCore $MihomoPath
        foreach ($item in @($manifest.Profiles)) {
            $target = @($currentTargets | Where-Object { $_.Uid -eq [string]$item.Uid -and (Split-Path -Leaf $_.Path) -eq [string]$item.File })
            if ($target.Count -ne 1) { throw "远程订阅清单在更新期间发生变化。" }
            $text = Get-Content -LiteralPath $target[0].Path -Raw -Encoding UTF8
            Test-GeneratedYaml $text ([string]$item.File) | Out-Null
            Test-MihomoCandidate $core $text $profilesDirectory
            $validated += [pscustomobject]@{ Target = $target[0]; Manifest = $item }
        }
        $savedProfile = Get-SavedUsageProfile $usageStatePath
        if ($savedProfile -eq 3) { Assert-RemoteSubscriptionAutoUpdateDisabled $indexText | Out-Null }
    } catch {
        $restoreResult = Restore-SafeUpdateFiles $recoveryItems $observedCurrentHashes
        if ($restoreResult.Conflicts.Count -gt 0) {
            throw "更新验收失败；检测到订阅同时发生变化，未覆盖新内容：$($restoreResult.Conflicts -join '、')。安全更新记录已保留。"
        }
        if ($restoreResult.Failures.Count -gt 0) { throw "更新验收失败，且部分订阅未能恢复：$($restoreResult.Failures -join '、')。安全更新记录已保留。" }
        Remove-Item -LiteralPath $safeUpdateStatePath -Force
        throw "更新验收失败，全部订阅文件已恢复到更新前版本。"
    }
    foreach ($entry in $validated) {
        $changed = (Get-FileSha256 $entry.Target.Path) -ne [string]$entry.Manifest.BeforeSha256
        Write-Info ($(if ($changed) { "已更新并通过检查：" } else { "内容未变化并通过检查：" }) + $(if ([string]::IsNullOrWhiteSpace($entry.Target.Name)) { $entry.Target.Uid } else { $entry.Target.Name }))
    }
    Remove-Item -LiteralPath $safeUpdateStatePath -Force
    Write-Info "全部远程订阅已逐份通过 YAML 与 Mihomo 检查。"
    Complete-InstallResult 0 "ok" "safe_update_verified" "全部远程订阅已逐份通过检查。" @() @("yaml", "mihomo", "auto_update")
}

if ($ListBackups) {
    $backupItems = @()
    if (Test-Path -LiteralPath $backupRoot -PathType Container) {
        Get-ChildItem -LiteralPath $backupRoot -File -Filter "*.backup" | Sort-Object Name -Descending | ForEach-Object {
            if ($Json) { $backupItems += $_.Name } else { $_.Name }
        }
    }
    $backupStatus = if ($backupItems.Count -eq 0) { "no_change" } else { "ok" }
    Complete-InstallResult 0 $backupStatus "backups_listed" "备份清单已读取。" @() @() $backupItems
}

if (-not [string]::IsNullOrWhiteSpace($CompareBackup)) {
    $resolved = Get-BackupTarget $CompareBackup
    $backupHash = (Get-FileHash -LiteralPath $resolved.BackupPath -Algorithm SHA256).Hash.ToLowerInvariant()
    $currentHash = (Get-FileHash -LiteralPath $resolved.TargetPath -Algorithm SHA256).Hash.ToLowerInvariant()
    $same = ($backupHash -eq $currentHash)
    $changedFields = @()
    if (-not $same) {
        if ([System.IO.Path]::GetExtension($resolved.TargetPath) -match '^\.ya?ml$') {
            $backupText = [System.Text.Encoding]::UTF8.GetString([System.IO.File]::ReadAllBytes($resolved.BackupPath))
            $currentText = [System.Text.Encoding]::UTF8.GetString([System.IO.File]::ReadAllBytes($resolved.TargetPath))
            $changedFields = @(Get-RedactedYamlChangedPaths $backupText $currentText)
        } else {
            $changedFields = @("文件内容")
        }
    }
    $comparison = [pscustomobject]@{
        Backup = $CompareBackup
        Profile = (Split-Path -Leaf $resolved.TargetPath)
        Same = $same
        BackupSha256 = $backupHash
        CurrentSha256 = $currentHash
        ChangedFields = $changedFields
        ConfigurationDifference = $(if ($same) { "无配置差异" } else { "存在配置差异；为保护隐私只输出发生变化的字段名" })
    }
    if (-not $Json) { $comparison | ConvertTo-Json }
    Complete-InstallResult 0 $(if ($same) { "no_change" } else { "ok" }) "backup_compared" "备份比较已完成。" @($changedFields) @($comparison)
}

if (-not [string]::IsNullOrWhiteSpace($RestoreBackup)) {
    if (Test-ClashVergeRunning) { throw "Clash Verge Rev 正在运行，不能安全恢复配置；未修改任何文件。" }
    if ($ExpectedCurrentSha256 -notmatch '^[0-9a-fA-F]{64}$') { throw "恢复时必须提供预期 SHA-256。" }
    $resolved = Get-BackupTarget $RestoreBackup
    $currentHash = (Get-FileHash -LiteralPath $resolved.TargetPath -Algorithm SHA256).Hash
    if ($currentHash -ne $ExpectedCurrentSha256) { throw "当前配置已变化，拒绝覆盖。" }
    $restoreBytes = [System.IO.File]::ReadAllBytes($resolved.BackupPath)
    $currentBytes = [System.IO.File]::ReadAllBytes($resolved.TargetPath)
    Test-RestoreCandidate $resolved.TargetPath $restoreBytes
    Backup-Versioned $resolved.TargetPath $backupRoot "pre-restore" | Out-Null
    try {
        Write-BytesAtomic $resolved.TargetPath $restoreBytes
        if ((Get-FileSha256 $resolved.TargetPath) -ne (Get-BytesSha256 $restoreBytes)) {
            throw "恢复后的文件与已验证备份不一致。"
        }
    } catch {
        Write-BytesAtomic $resolved.TargetPath $currentBytes
        throw
    }
    Write-Info "备份已恢复；恢复前版本已经另行备份。"
    Complete-InstallResult 0 "ok" "backup_restored" "备份已恢复；恢复前版本已经另行备份。" @("configuration")
}
} catch {
    if ($Json) {
        $operationStatus = if ($_.Exception.Message -match "已恢复") { "rolled_back" } else { "failed" }
        Complete-InstallResult 1 $operationStatus "operation_failed" ("操作失败：" + $_.Exception.Message)
    }
    throw
}
$enginePath = Join-Path (Join-Path $PSScriptRoot "windows") "clash_verge_global.js"

try {
    $savedUsageProfile = Get-SavedUsageProfile $usageStatePath
} catch {
    if (-not $Json) { [Console]::Error.WriteLine("[Clash 补丁] $($_.Exception.Message)") }
    Complete-InstallResult 1 "failed" "usage_profile_read_failed" ("读取用途档位失败：" + $_.Exception.Message)
}

if ($ShowUsageProfile) {
    if ($savedUsageProfile -ne 0) { $script:ClashPatchProfile = $savedUsageProfile }
    if (-not $Json) { if ($savedUsageProfile -eq 0) { Write-Output "unset" } else { Write-Output $savedUsageProfile } }
    Complete-InstallResult 0 "ok" "usage_profile_shown" "用途档位已读取。"
}

$profileSource = "saved"
$resolvedUsageProfile = $UsageProfile
if ($resolvedUsageProfile -eq 0 -and -not [string]::IsNullOrWhiteSpace($env:CLASH_PATCH_USAGE_PROFILE)) {
    $parsedUsageProfile = 0
    if (-not [int]::TryParse($env:CLASH_PATCH_USAGE_PROFILE, [ref]$parsedUsageProfile)) {
        if (-not $Json) { [Console]::Error.WriteLine("[Clash 补丁] 用途档位无效，只能是 1、2 或 3。") }
        Complete-InstallResult 64 "invalid_request" "invalid_usage_profile" "用途档位无效，只能是 1、2 或 3。"
    }
    $resolvedUsageProfile = $parsedUsageProfile
    $profileSource = "environment"
} elseif ($resolvedUsageProfile -ne 0) {
    $profileSource = "argument"
}
if ($resolvedUsageProfile -eq 0) {
    $resolvedUsageProfile = $savedUsageProfile
}
if ($resolvedUsageProfile -eq 0) {
    if (-not $Json) { [Console]::Error.WriteLine("[Clash 补丁] 还没有选择用途档位。请先在 skill 中选择：1 普通浏览、2 海外 AI、3 Claude/Claude Code。") }
    Complete-InstallResult 10 "invalid_request" "usage_profile_required" "还没有选择用途档位。"
}
if ($resolvedUsageProfile -notin @(1, 2, 3)) {
    if (-not $Json) { [Console]::Error.WriteLine("[Clash 补丁] 用途档位无效，只能是 1、2 或 3。") }
    Complete-InstallResult 64 "invalid_request" "invalid_usage_profile" "用途档位无效，只能是 1、2 或 3。"
}
$script:ClashPatchProfile = $resolvedUsageProfile

if (-not (Test-Path -LiteralPath $enginePath -PathType Leaf)) {
    if (-not $Json) { [Console]::Error.WriteLine("[Clash 补丁] 安装包不完整：缺少 Windows 全局扩展脚本。") }
    Complete-InstallResult 3 "failed" "package_incomplete" "安装包不完整：缺少 Windows 全局扩展脚本。"
    exit 3
}

try {
    $clientRunning = Test-ClashVergeRunning
    $corePath = Find-MihomoCore $MihomoPath
    Test-MihomoVersion $corePath | Out-Null
    if ($savedUsageProfile -eq 3 -and $resolvedUsageProfile -ne 3 -and $profileSource -ne "saved") {
        throw "从档位 3 改为轻量档位前，必须先运行安全卸载。"
    }
    $usageProfileTarget = $null
    if ($profileSource -ne "saved") {
        $usageProfileBytes = ConvertTo-Utf8Bytes ((([ordered]@{
            Version = 1
            Profile = $resolvedUsageProfile
        }) | ConvertTo-Json -Compress) + "`r`n")
        $usageProfileTarget = [pscustomobject]@{
            Path = $usageStatePath
            Bytes = $usageProfileBytes
            Existed = (Test-Path -LiteralPath $usageStatePath)
            OriginalBytes = $(if (Test-Path -LiteralPath $usageStatePath) { [System.IO.File]::ReadAllBytes($usageStatePath) } else { $null })
        }
    }
    if ($resolvedUsageProfile -ne 3) {
        New-Item -ItemType Directory -Path $profilesDirectory -Force | Out-Null
        $scriptOutput = Build-GlobalScript $enginePath $targetScript $resolvedUsageProfile
        $scriptBytes = ConvertTo-Utf8Bytes $scriptOutput
        $scriptTarget = [pscustomobject]@{
            Path = $targetScript
            Bytes = $scriptBytes
            Existed = (Test-Path -LiteralPath $targetScript)
            OriginalBytes = $(if (Test-Path -LiteralPath $targetScript) { [System.IO.File]::ReadAllBytes($targetScript) } else { $null })
        }
        Backup-InitialOnce $scriptTarget.Path $backupRoot | Out-Null
        Backup-Versioned $scriptTarget.Path $backupRoot "prewrite" | Out-Null
        $lightTargets = @($scriptTarget)
        if ($null -ne $usageProfileTarget) { $lightTargets += $usageProfileTarget }
        try {
            foreach ($target in $lightTargets) { Write-BytesAtomic $target.Path $target.Bytes }
        } catch {
            Restore-Transaction $lightTargets
            throw
        }
        if ($null -ne $usageProfileTarget) { Write-Info "已保存用途档位 $resolvedUsageProfile。" }
        Write-Info "已为全部订阅安装共享国内域名直连规则；未修改 TUN、IPv6 或订阅自动更新。"
        Complete-InstallResult 0 "ok" "installed_common_baseline" "已安装全部订阅共用的国内域名直连规则。" @("global_script", "cn_domain_baseline")
    }
    if (-not (Test-Path -LiteralPath $profilesIndexPath -PathType Leaf)) {
        throw "找不到 Clash Verge Rev 的 profiles.yaml，无法自动关闭订阅更新。"
    }
    $profilesIndexInput = Get-Content -LiteralPath $profilesIndexPath -Raw -Encoding UTF8
    $profilesIndexOutput = Set-RemoteSubscriptionAutoUpdateDisabled $profilesIndexInput
    Assert-RemoteSubscriptionAutoUpdateDisabled $profilesIndexOutput | Out-Null
    $profilesIndexBytes = ConvertTo-Utf8Bytes $profilesIndexOutput

    if ($clientRunning) {
        New-Item -ItemType Directory -Path $profilesDirectory -Force | Out-Null
        $scriptOutput = Build-GlobalScript $enginePath $targetScript $resolvedUsageProfile
        $scriptBytes = ConvertTo-Utf8Bytes $scriptOutput
        $runningTargets = @(
            [pscustomobject]@{ Path = $targetScript; Bytes = $scriptBytes; Existed = (Test-Path -LiteralPath $targetScript); OriginalBytes = $(if (Test-Path -LiteralPath $targetScript) { [System.IO.File]::ReadAllBytes($targetScript) } else { $null }) },
            [pscustomobject]@{ Path = $profilesIndexPath; Bytes = $profilesIndexBytes; Existed = $true; OriginalBytes = [System.IO.File]::ReadAllBytes($profilesIndexPath) }
        )
        if ($null -ne $usageProfileTarget) { $runningTargets += $usageProfileTarget }
        foreach ($target in $runningTargets) {
            if ($target.Path -eq $usageStatePath) { continue }
            Backup-InitialOnce $target.Path $backupRoot | Out-Null
            Backup-Versioned $target.Path $backupRoot "prewrite" | Out-Null
        }
        try {
            foreach ($target in $runningTargets) { Write-BytesAtomic $target.Path $target.Bytes }
            Assert-RemoteSubscriptionAutoUpdateDisabled (Get-Content -LiteralPath $profilesIndexPath -Raw -Encoding UTF8) | Out-Null
        } catch {
            Restore-Transaction $runningTargets
            throw
        }
        if ($null -ne $usageProfileTarget) { Write-Info "已保存用途档位 $resolvedUsageProfile。" }
        Write-Info "Clash Verge Rev 保持运行；已更新全局扩展脚本，并自动关闭全部远程订阅的自动更新。"
        Write-Info "config.yaml、verge.yaml 和当前运行配置均未修改。下次订阅刷新时应用补丁。"
        Complete-InstallResult 0 "ok" "installed_running_client" "客户端保持运行；全局扩展脚本与自动更新设置已更新。" @("global_script", "auto_update")
        exit 0
    }

    $installState = $null
    if (Test-Path -LiteralPath $statePath -PathType Leaf) {
        $installState = Get-Content -LiteralPath $statePath -Raw -Encoding UTF8 | ConvertFrom-Json
        Assert-InstallState $installState
    }
    $previousVerge = Get-InstallStateEntry $installState "VergeYaml"
    $previousConfig = Get-InstallStateEntry $installState "ConfigYaml"
    Assert-StateTargetUnchanged $previousVerge $vergePath "verge.yaml"
    Assert-StateTargetUnchanged $previousConfig $configPath "config.yaml"

    New-Item -ItemType Directory -Path $profilesDirectory -Force | Out-Null
    $scriptOutput = Build-GlobalScript $enginePath $targetScript $resolvedUsageProfile
    $vergeInput = if (Test-Path -LiteralPath $vergePath) { Get-Content -LiteralPath $vergePath -Raw -Encoding UTF8 } else { "" }
    $vergeOutput = Set-YamlTopLevelScalar $vergeInput "enable_tun_mode" "true"
    $vergeOutput = Set-YamlTopLevelScalar $vergeOutput "enable_dns_settings" "false"
    $configInput = if (Test-Path -LiteralPath $configPath) { Get-Content -LiteralPath $configPath -Raw -Encoding UTF8 } else { "" }
    $configOutput = Set-YamlTopLevelScalar $configInput "ipv6" "false"
    $configOutput = Set-YamlTunMapping $configOutput

    Test-GeneratedYaml $vergeOutput "verge.yaml" | Out-Null
    Test-GeneratedYaml $configOutput "config.yaml" | Out-Null
    Test-MihomoCandidate $corePath $configOutput $AppHome

    $scriptBytes = ConvertTo-Utf8Bytes $scriptOutput
    $vergeBytes = ConvertTo-Utf8Bytes $vergeOutput
    $configBytes = ConvertTo-Utf8Bytes $configOutput
    $stateObject = [ordered]@{
        Version = 1
        VergeYaml = (New-InstallStateEntry $previousVerge $vergePath $vergeBytes)
        ConfigYaml = (New-InstallStateEntry $previousConfig $configPath $configBytes)
    }
    $stateBytes = ConvertTo-Utf8Bytes (($stateObject | ConvertTo-Json -Depth 5) + "`r`n")

    $targets = @(
        [pscustomobject]@{ Path = $targetScript; Bytes = $scriptBytes; Existed = (Test-Path -LiteralPath $targetScript); OriginalBytes = $(if (Test-Path -LiteralPath $targetScript) { [System.IO.File]::ReadAllBytes($targetScript) } else { $null }) },
        [pscustomobject]@{ Path = $profilesIndexPath; Bytes = $profilesIndexBytes; Existed = $true; OriginalBytes = [System.IO.File]::ReadAllBytes($profilesIndexPath) },
        [pscustomobject]@{ Path = $vergePath; Bytes = $vergeBytes; Existed = (Test-Path -LiteralPath $vergePath); OriginalBytes = $(if (Test-Path -LiteralPath $vergePath) { [System.IO.File]::ReadAllBytes($vergePath) } else { $null }) },
        [pscustomobject]@{ Path = $configPath; Bytes = $configBytes; Existed = (Test-Path -LiteralPath $configPath); OriginalBytes = $(if (Test-Path -LiteralPath $configPath) { [System.IO.File]::ReadAllBytes($configPath) } else { $null }) },
        [pscustomobject]@{ Path = $statePath; Bytes = $stateBytes; Existed = (Test-Path -LiteralPath $statePath); OriginalBytes = $(if (Test-Path -LiteralPath $statePath) { [System.IO.File]::ReadAllBytes($statePath) } else { $null }) }
    )
    if ($null -ne $usageProfileTarget) { $targets += $usageProfileTarget }
    foreach ($target in $targets) {
        if ($target.Path -eq $usageStatePath) { continue }
        Backup-InitialOnce $target.Path $backupRoot | Out-Null
        Backup-Versioned $target.Path $backupRoot "prewrite" | Out-Null
    }

    try {
        if (Test-ClashVergeRunning) { throw "检测到 Clash Verge Rev 在安装期间启动；已撤销本次文件修改。" }
        foreach ($target in $targets) {
            Write-BytesAtomic $target.Path $target.Bytes
        }
    } catch {
        # Restore every target, including the target whose atomic move raised:
        # an interrupted replacement may have changed it before reporting failure.
        Restore-Transaction $targets
        throw
    }

    if ($null -ne $usageProfileTarget) { Write-Info "已保存用途档位 $resolvedUsageProfile。" }
    Write-Info "已安装全局扩展脚本，之后每次加载或刷新订阅都会自动应用补丁。"
    Write-Info "已自动关闭全部远程订阅的自动更新，并回读确认 profiles.yaml。"
    Write-Info "已开启 TUN，并让全局脚本接管 DNS 配置。下次订阅刷新时应用补丁。"
    Write-Info "安装程序从未退出、停止或重启 Clash Verge Rev。"
    Write-Info "已有 AI 分组只补全规则；没有时创建包含全部可用节点和代理提供者的独立选择器。安装程序不会替你选择节点。"
    Complete-InstallResult 0 "ok" "installed" "Windows Clash 补丁已安装。" @("global_script", "auto_update", "tun", "dns", "ipv6")
    exit 0
} catch {
    if (-not $Json) { [Console]::Error.WriteLine("[Clash 补丁] 安装失败：$($_.Exception.Message)") }
    Complete-InstallResult 1 $(if ($_.Exception.Message -match "已撤销|恢复") { "rolled_back" } else { "failed" }) "install_failed" ("安装失败：" + $_.Exception.Message)
    exit 1
}
