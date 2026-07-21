param(
    [Parameter(Mandatory = $true)]
    [string]$PowerShellPath
)

$ErrorActionPreference = "Stop"
$root = Split-Path -Parent $PSScriptRoot
$installer = Join-Path (Join-Path $root "clash-patch/scripts") "install_windows.ps1"
$uninstaller = Join-Path (Join-Path $root "clash-patch/scripts") "uninstall_windows.ps1"
$sandbox = Join-Path ([System.IO.Path]::GetTempPath()) ("clash-patch-windows-test-" + [System.Guid]::NewGuid().ToString("N"))
$onWindows = [Environment]::OSVersion.Platform -eq [PlatformID]::Win32NT
$fakeCore = Join-Path $sandbox $(if ($onWindows) { "mihomo-test.cmd" } else { "mihomo-test.sh" })
$hangingCore = Join-Path $sandbox $(if ($onWindows) { "mihomo-hang.cmd" } else { "mihomo-hang.sh" })

$tokens = $null
$parseErrors = $null
$ast = [System.Management.Automation.Language.Parser]::ParseFile($installer, [ref]$tokens, [ref]$parseErrors)
if ($parseErrors.Count -gt 0) { throw ($parseErrors | Out-String) }
$ast.FindAll({ param($node) $node -is [System.Management.Automation.Language.FunctionDefinitionAst] }, $true) | ForEach-Object {
    . ([scriptblock]::Create($_.Extent.Text))
}
$uninstallTokens = $null
$uninstallParseErrors = $null
$uninstallAst = [System.Management.Automation.Language.Parser]::ParseFile($uninstaller, [ref]$uninstallTokens, [ref]$uninstallParseErrors)
if ($uninstallParseErrors.Count -gt 0) { throw ($uninstallParseErrors | Out-String) }
$uninstallAst.FindAll({
    param($node)
    $node -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq "New-UninstallBackup"
}, $true) | ForEach-Object {
    . ([scriptblock]::Create($_.Extent.Text))
}

function Assert-True([bool]$Condition, [string]$Message) {
    if (-not $Condition) { throw $Message }
}

function Invoke-Installer([string]$AppHome) {
    $output = & $PowerShellPath -NoLogo -NoProfile -File $installer -AppHome $AppHome -MihomoPath $fakeCore 2>&1 | Out-String
    if ($LASTEXITCODE -ne 0) { throw "Windows installer returned $LASTEXITCODE`n$output" }
}

function Invoke-Uninstaller([string]$AppHome) {
    $output = & $PowerShellPath -NoLogo -NoProfile -File $uninstaller -AppHome $AppHome 2>&1 | Out-String
    if ($LASTEXITCODE -ne 0) { throw "Windows uninstaller returned $LASTEXITCODE`n$output" }
}

function Assert-InstallerRejectsScript([string]$Name, [string]$Script, [string]$MessageFragment) {
    $case = Join-Path $sandbox $Name
    $profiles = Join-Path $case "profiles"
    New-Item -ItemType Directory -Path $profiles -Force | Out-Null
    [System.IO.File]::WriteAllText((Join-Path $case "config.yaml"), "ipv6: true`ntun: null`n")
    [System.IO.File]::WriteAllText((Join-Path $case "verge.yaml"), "enable_tun_mode: false`n")
    $scriptPath = Join-Path $profiles "Script.js"
    [System.IO.File]::WriteAllText($scriptPath, $Script)
    $output = & $PowerShellPath -NoLogo -NoProfile -File $installer -AppHome $case -MihomoPath $fakeCore 2>&1 | Out-String
    Assert-True ($LASTEXITCODE -eq 1) "$Name was accepted"
    Assert-True ($output.Contains($MessageFragment)) "$Name rejection did not explain the problem: $output"
    Assert-True ((Get-Content -LiteralPath $scriptPath -Raw) -eq $Script) "$Name rejection changed Script.js"
}

try {
    New-Item -ItemType Directory -Path $sandbox -Force | Out-Null
    if ($onWindows) {
        $fakeCoreText = "@echo off`r`nif `"%1`"==`"-v`" (`r`n  echo Mihomo Meta v1.19.27 windows amd64`r`n  exit /b 0`r`n)`r`nexit /b 0`r`n"
    } else {
        $fakeCoreText = "#!/bin/sh`nif [ `"`${1:-}`" = `"-v`" ]; then`n  echo 'Mihomo Meta v1.19.27 test arm64'`nfi`nexit 0`n"
    }
    [System.IO.File]::WriteAllText($fakeCore, $fakeCoreText, [System.Text.Encoding]::ASCII)
    if (-not $onWindows) { & /bin/chmod 700 $fakeCore }
    if ($onWindows) {
        $hangingCoreText = "@echo off`r`nping 127.0.0.1 -n 6 >nul`r`nexit /b 0`r`n"
    } else {
        $hangingCoreText = "#!/bin/sh`nsleep 5`nexit 0`n"
    }
    [System.IO.File]::WriteAllText($hangingCore, $hangingCoreText, [System.Text.Encoding]::ASCII)
    if (-not $onWindows) { & /bin/chmod 700 $hangingCore }

    $unitStage = Set-YamlTopLevelScalar "ipv6 : true`ntun: null`n" "ipv6" "false"
    Assert-True ($unitStage -match '(?m)^tun:') "scalar transform lost tun node: $($unitStage | ConvertTo-Json -Compress)"
    $unitBlock = @(New-ManagedTunBlock)
    Assert-True ($unitBlock.Count -gt 2) "managed tun block collapsed: $($unitBlock | ConvertTo-Json -Compress)"
    $unitLines = @(Split-YamlLines $unitStage)
    Assert-True ($unitLines.Count -gt 1) "line splitter collapsed: $($unitLines | ConvertTo-Json -Compress)"
    $unitJoined = Join-YamlLines -Lines @($unitLines + $unitBlock)
    Assert-True ($unitJoined -match '(?m)^tun:') "line joiner collapsed: $($unitJoined | ConvertTo-Json -Compress)"
    $unitReplaced = @(Replace-YamlRange -Lines $unitLines -Start 1 -End 2 -Replacement $unitBlock)
    Assert-True ($unitReplaced.Count -gt 2) "range replacement collapsed: $($unitReplaced | ConvertTo-Json -Compress)"
    $unitOutput = Set-YamlTunMapping $unitStage
    $unitDebug = $unitOutput | ConvertTo-Json -Compress
    Assert-True ($unitOutput -match '(?m)^tun:') "unit transform lost tun node: type=$($unitOutput.GetType().FullName) count=$($unitOutput.Count) json=$unitDebug"
    Test-GeneratedYaml $unitOutput "config.yaml" | Out-Null

    $quotedInput = "`"ipv6`" : true`n`"tun`": null`n"
    $quotedOutput = Set-YamlTunMapping (Set-YamlTopLevelScalar $quotedInput "ipv6" "false")
    Assert-True ([regex]::Matches($quotedOutput, '(?m)^["'']?tun["'']?\s*:').Count -eq 1) "quoted tun key was duplicated"
    Assert-True ([regex]::Matches($quotedOutput, '(?m)^["'']?ipv6["'']?\s*:').Count -eq 1) "quoted ipv6 key was duplicated"

    $commented = Set-YamlTopLevelScalar "ipv6: true # keep this note`n" "ipv6" "false"
    Assert-True ($commented.Contains("# keep this note")) "top-level scalar edit discarded an inline comment"
    $anchorRejected = $false
    try { Set-YamlTunMapping "tun: &defaults`n  enable: false`n" | Out-Null } catch { $anchorRejected = $true }
    Assert-True $anchorRejected "anchored tun mapping was modified instead of rejected"
    $scalarAnchorRejected = $false
    try { Set-YamlTopLevelScalar "enable_tun_mode: &shared false`nfriend: *shared`n" "enable_tun_mode" "true" | Out-Null } catch { $scalarAnchorRejected = $true }
    Assert-True $scalarAnchorRejected "anchored top-level scalar was modified and left a dangling alias"
    $commentedDocumentRejected = $false
    try { Test-GeneratedYaml "friend: true`n--- # second document`nother: false`n" "verge.yaml" | Out-Null } catch { $commentedDocumentRejected = $true }
    Assert-True $commentedDocumentRejected "commented YAML document marker was ignored"

    Assert-True (Test-MihomoVersionText "Mihomo Meta v1.19.27") "minimum Mihomo version was rejected"
    Assert-True (-not (Test-MihomoVersionText "Mihomo Meta v1.19.26")) "old Mihomo version was accepted"
    $timeoutCore = $hangingCore
    $timeoutArguments = @("-v")
    if ($onWindows) {
        $timeoutCore = Join-Path (Join-Path $env:SystemRoot "System32") "ping.exe"
        $timeoutArguments = @("-n", "6", "127.0.0.1")
    }
    $timeoutRaised = $false
    $timeoutError = ""
    $timeoutWatch = [System.Diagnostics.Stopwatch]::StartNew()
    try { Invoke-Mihomo $timeoutCore $timeoutArguments 1 | Out-Null } catch {
        $timeoutError = $_.Exception.Message
        $timeoutRaised = $timeoutError.Contains("超过 1 秒")
    }
    $timeoutWatch.Stop()
    Assert-True $timeoutRaised "hanging Mihomo process did not fail closed after one second: $timeoutError"
    Assert-True ($timeoutWatch.Elapsed.TotalSeconds -lt 4) "hanging Mihomo process was not terminated promptly"

    $backupSource = Join-Path $sandbox "backup-source.txt"
    $backupBytes = [byte[]](0xEF, 0xBB, 0xBF, 0x66, 0x69, 0x72, 0x73, 0x74)
    [System.IO.File]::WriteAllBytes($backupSource, $backupBytes)
    Backup-Once $backupSource
    [System.IO.File]::WriteAllText($backupSource, "second")
    Backup-Once $backupSource
    $savedBackup = [System.IO.File]::ReadAllBytes("$backupSource.clash-patch.original.backup")
    Assert-True (([Convert]::ToBase64String($savedBackup)) -eq ([Convert]::ToBase64String($backupBytes))) "exclusive backup was overwritten"
    if ($onWindows) {
        $backupAcl = Get-Acl -LiteralPath "$backupSource.clash-patch.original.backup"
        Assert-True $backupAcl.AreAccessRulesProtected "backup ACL still inherits permissions"
        $currentSid = [System.Security.Principal.WindowsIdentity]::GetCurrent().User.Value
        $hasCurrentUser = @($backupAcl.Access | Where-Object {
            $_.IdentityReference.Translate([System.Security.Principal.SecurityIdentifier]).Value -eq $currentSid -and
            $_.AccessControlType -eq [System.Security.AccessControl.AccessControlType]::Allow
        }).Count -gt 0
        Assert-True $hasCurrentUser "backup ACL does not allow the current user"
    }

    $uninstallBackupSource = Join-Path $sandbox "uninstall-script.js"
    [System.IO.File]::WriteAllBytes($uninstallBackupSource, $backupBytes)
    $uninstallBackupOne = New-UninstallBackup $uninstallBackupSource
    $uninstallBackupTwo = New-UninstallBackup $uninstallBackupSource
    Assert-True ($uninstallBackupOne -ne $uninstallBackupTwo) "same-second uninstall backups collided"
    Assert-True (([Convert]::ToBase64String([System.IO.File]::ReadAllBytes($uninstallBackupOne))) -eq ([Convert]::ToBase64String($backupBytes))) "first uninstall backup changed bytes"
    Assert-True (([Convert]::ToBase64String([System.IO.File]::ReadAllBytes($uninstallBackupTwo))) -eq ([Convert]::ToBase64String($backupBytes))) "second uninstall backup changed bytes"

    $transactionDir = Join-Path $sandbox "transaction"
    New-Item -ItemType Directory -Path $transactionDir -Force | Out-Null
    $existingPath = Join-Path $transactionDir "existing.txt"
    $newPath = Join-Path $transactionDir "new.txt"
    $originalBytes = [byte[]](0xEF, 0xBB, 0xBF, 0x6F, 0x72, 0x69, 0x67, 0x69, 0x6E, 0x61, 0x6C)
    [System.IO.File]::WriteAllBytes($existingPath, $originalBytes)
    [System.IO.File]::WriteAllText($existingPath, "changed")
    [System.IO.File]::WriteAllText($newPath, "created")
    Restore-Transaction @(
        [pscustomobject]@{ Path = $existingPath; Existed = $true; OriginalBytes = $originalBytes },
        [pscustomobject]@{ Path = $newPath; Existed = $false; OriginalBytes = $null }
    )
    Assert-True (([Convert]::ToBase64String([System.IO.File]::ReadAllBytes($existingPath))) -eq ([Convert]::ToBase64String($originalBytes))) "transaction did not restore exact original bytes"
    Assert-True (-not (Test-Path -LiteralPath $newPath)) "transaction did not remove newly created file"

    $continuePath = Join-Path $transactionDir "continue.txt"
    [System.IO.File]::WriteAllText($continuePath, "changed")
    $restoreFailed = $false
    try {
        Restore-Transaction @(
            [pscustomobject]@{ Path = $continuePath; Existed = $true; OriginalBytes = [System.Text.Encoding]::UTF8.GetBytes("restored") },
            [pscustomobject]@{ Path = $transactionDir; Existed = $true; OriginalBytes = [byte[]](1, 2, 3) }
        )
    } catch { $restoreFailed = $true }
    Assert-True $restoreFailed "rollback did not report a restore failure"
    Assert-True ((Get-Content -LiteralPath $continuePath -Raw) -eq "restored") "rollback stopped before restoring earlier targets"

    $nullCase = Join-Path $sandbox "null-case"
    New-Item -ItemType Directory -Path $nullCase -Force | Out-Null
    [System.IO.File]::WriteAllText((Join-Path $nullCase "config.yaml"), "ipv6 : true`ntun: null`n")
    [System.IO.File]::WriteAllText((Join-Path $nullCase "verge.yaml"), "enable_tun_mode: false`n")
    Invoke-Installer $nullCase
    $nullOutput = Get-Content -LiteralPath (Join-Path $nullCase "config.yaml") -Raw
    Assert-True ([regex]::Matches($nullOutput, '(?m)^tun\s*:').Count -eq 1) "tun: null produced duplicate tun keys"
    Assert-True ([regex]::Matches($nullOutput, '(?m)^ipv6\s*:').Count -eq 1) "spaced ipv6 produced duplicate ipv6 keys"
    Assert-True ($nullOutput.Contains("dns-hijack:`n") -or $nullOutput.Contains("dns-hijack:`r`n")) "dns-hijack block missing"

    $blockCase = Join-Path $sandbox "block-case"
    New-Item -ItemType Directory -Path $blockCase -Force | Out-Null
    $blockInput = "ipv6: true`ntun:`n  enable: false`n  dns-hijack:`n    - 0.0.0.0:53`n  device: Clash`n"
    [System.IO.File]::WriteAllText((Join-Path $blockCase "config.yaml"), $blockInput)
    [System.IO.File]::WriteAllText((Join-Path $blockCase "verge.yaml"), "enable_dns_settings: true`n")
    Invoke-Installer $blockCase
    Invoke-Installer $blockCase
    $blockOutput = Get-Content -LiteralPath (Join-Path $blockCase "config.yaml") -Raw
    Assert-True (-not $blockOutput.Contains("0.0.0.0:53")) "old dns-hijack child survived"
    Assert-True ($blockOutput.Contains("device: Clash")) "unmanaged tun setting was removed"
    Assert-True ([regex]::Matches($blockOutput, '(?m)^  dns-hijack\s*:').Count -eq 1) "dns-hijack was duplicated"

    $composeCase = Join-Path $sandbox "compose-case"
    $composeProfiles = Join-Path $composeCase "profiles"
    New-Item -ItemType Directory -Path $composeProfiles -Force | Out-Null
    $composeConfigOriginal = "ipv6: true`ntun: null`n"
    $composeVergeOriginal = "enable_tun_mode: false`nenable_dns_settings: true`n"
    [System.IO.File]::WriteAllText((Join-Path $composeCase "config.yaml"), $composeConfigOriginal)
    [System.IO.File]::WriteAllText((Join-Path $composeCase "verge.yaml"), $composeVergeOriginal)
    $originalScript = "function main(config) { config.friend = true; return config; }`n"
    [System.IO.File]::WriteAllText((Join-Path $composeProfiles "Script.js"), $originalScript)
    Invoke-Installer $composeCase
    $composedPath = Join-Path $composeProfiles "Script.js"
    $composedWithSuffix = (Get-Content -LiteralPath $composedPath -Raw) + "const friendAfterPatch = true;`r`n"
    [System.IO.File]::WriteAllText($composedPath, $composedWithSuffix)
    Invoke-Installer $composeCase
    Assert-True ((Get-Content -LiteralPath $composedPath -Raw).Contains("const friendAfterPatch = true;")) "reinstall discarded code after the managed block"
    Invoke-Uninstaller $composeCase
    $restoredScript = Get-Content -LiteralPath (Join-Path $composeProfiles "Script.js") -Raw
    Assert-True ($restoredScript.Contains($originalScript.Trim())) "uninstaller did not restore the composed script"
    Assert-True ($restoredScript.Contains("const friendAfterPatch = true;")) "uninstaller discarded code after the managed block"
    Assert-True ((Get-Content -LiteralPath (Join-Path $composeCase "config.yaml") -Raw) -eq $composeConfigOriginal) "uninstaller did not restore config.yaml"
    Assert-True ((Get-Content -LiteralPath (Join-Path $composeCase "verge.yaml") -Raw) -eq $composeVergeOriginal) "uninstaller did not restore verge.yaml"

    $asyncCase = Join-Path $sandbox "async-case"
    $asyncProfiles = Join-Path $asyncCase "profiles"
    New-Item -ItemType Directory -Path $asyncProfiles -Force | Out-Null
    $asyncConfig = "ipv6: true`ntun: null`n"
    $asyncVerge = "enable_tun_mode: false`n"
    $asyncScript = "async function main(config) { return config; }`n"
    [System.IO.File]::WriteAllText((Join-Path $asyncCase "config.yaml"), $asyncConfig)
    [System.IO.File]::WriteAllText((Join-Path $asyncCase "verge.yaml"), $asyncVerge)
    $asyncScriptPath = Join-Path $asyncProfiles "Script.js"
    [System.IO.File]::WriteAllText($asyncScriptPath, $asyncScript)
    $asyncOutput = & $PowerShellPath -NoLogo -NoProfile -File $installer -AppHome $asyncCase -MihomoPath $fakeCore 2>&1 | Out-String
    Assert-True ($LASTEXITCODE -eq 1) "installer accepted an async main that Clash Verge Rev cannot await"
    Assert-True ($asyncOutput.Contains("异步 main")) "async main rejection did not explain the incompatibility"
    Assert-True ((Get-Content -LiteralPath $asyncScriptPath -Raw) -eq $asyncScript) "async main rejection changed Script.js"
    Assert-True ((Get-Content -LiteralPath (Join-Path $asyncCase "config.yaml") -Raw) -eq $asyncConfig) "async main rejection changed config.yaml"
    Assert-True ((Get-Content -LiteralPath (Join-Path $asyncCase "verge.yaml") -Raw) -eq $asyncVerge) "async main rejection changed verge.yaml"

    $templateMarkerCase = Join-Path $sandbox "template-marker-case"
    $templateMarkerProfiles = Join-Path $templateMarkerCase "profiles"
    New-Item -ItemType Directory -Path $templateMarkerProfiles -Force | Out-Null
    [System.IO.File]::WriteAllText((Join-Path $templateMarkerCase "config.yaml"), "ipv6: true`ntun: null`n")
    [System.IO.File]::WriteAllText((Join-Path $templateMarkerCase "verge.yaml"), "enable_tun_mode: false`n")
    $templateScript = @'
function main(config) {
  const markerPayload = `
// CLASH PATCH BEGIN
friend payload
// CLASH PATCH END
`;
  config.markerPayload = markerPayload;
  return config;
}
'@
    $templateScriptPath = Join-Path $templateMarkerProfiles "Script.js"
    [System.IO.File]::WriteAllText($templateScriptPath, $templateScript)
    Invoke-Installer $templateMarkerCase
    $templateComposed = Get-Content -LiteralPath $templateScriptPath -Raw
    Assert-True ($templateComposed.Contains("friend payload")) "marker text inside a template literal was treated as a managed boundary"
    Invoke-Uninstaller $templateMarkerCase
    Assert-True ((Get-Content -LiteralPath $templateScriptPath -Raw).Contains("friend payload")) "uninstaller discarded marker text inside a template literal"

    Assert-InstallerRejectsScript "reserved-symbol-case" "const clashPatchTransform = 1;`nfunction main(config) { return config; }`n" "保留标识符"
    Assert-InstallerRejectsScript "recursive-main-case" "function main(config) { return config.retry ? main(config) : config; }`n" "递归"

    $invalidStateCase = Join-Path $sandbox "invalid-state-case"
    New-Item -ItemType Directory -Path $invalidStateCase -Force | Out-Null
    $invalidStateConfig = "ipv6: true`ntun: null`n"
    $invalidStateVerge = "enable_tun_mode: false`n"
    [System.IO.File]::WriteAllText((Join-Path $invalidStateCase "config.yaml"), $invalidStateConfig)
    [System.IO.File]::WriteAllText((Join-Path $invalidStateCase "verge.yaml"), $invalidStateVerge)
    [System.IO.File]::WriteAllText((Join-Path $invalidStateCase "clash-patch-install-state.json"), '{"Version":1}')
    $invalidStateOutput = & $PowerShellPath -NoLogo -NoProfile -File $installer -AppHome $invalidStateCase -MihomoPath $fakeCore 2>&1 | Out-String
    Assert-True ($LASTEXITCODE -eq 1) "installer accepted incomplete state"
    Assert-True ($invalidStateOutput.Contains("安装状态文件无效")) "incomplete state rejection was unclear"
    Assert-True ((Get-Content -LiteralPath (Join-Path $invalidStateCase "config.yaml") -Raw) -eq $invalidStateConfig) "invalid state changed config.yaml"
    Assert-True ((Get-Content -LiteralPath (Join-Path $invalidStateCase "verge.yaml") -Raw) -eq $invalidStateVerge) "invalid state changed verge.yaml"

    $badMarkerCase = Join-Path $sandbox "bad-marker-case"
    $badMarkerProfiles = Join-Path $badMarkerCase "profiles"
    New-Item -ItemType Directory -Path $badMarkerProfiles -Force | Out-Null
    $badMarkerPath = Join-Path $badMarkerProfiles "Script.js"
    $badMarkerScript = "// CLASH PATCH BEGIN`nfunction main(config) { return config; }`n// CLASH PATCH END`n// CLASH PATCH END`n"
    [System.IO.File]::WriteAllText($badMarkerPath, $badMarkerScript)
    & $PowerShellPath -NoLogo -NoProfile -File $uninstaller -AppHome $badMarkerCase *> $null
    Assert-True ($LASTEXITCODE -eq 1) "uninstaller accepted duplicate end markers"
    Assert-True ((Get-Content -LiteralPath $badMarkerPath -Raw) -eq $badMarkerScript) "uninstaller modified an ambiguously marked script"

    Write-Host "Windows installer behavioral cases passed"
} finally {
    if (Test-Path -LiteralPath $sandbox) { Remove-Item -LiteralPath $sandbox -Recurse -Force }
}
