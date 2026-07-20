param(
    [Parameter(Mandatory = $true)]
    [string]$PowerShellPath
)

$ErrorActionPreference = "Stop"
$root = Split-Path -Parent $PSScriptRoot
$installer = Join-Path (Join-Path $root "clash-patch/scripts") "install_windows.ps1"
$uninstaller = Join-Path (Join-Path $root "clash-patch/scripts") "uninstall_windows.ps1"
$sandbox = Join-Path ([System.IO.Path]::GetTempPath()) ("clash-patch-windows-test-" + [System.Guid]::NewGuid().ToString("N"))

$tokens = $null
$parseErrors = $null
$ast = [System.Management.Automation.Language.Parser]::ParseFile($installer, [ref]$tokens, [ref]$parseErrors)
if ($parseErrors.Count -gt 0) { throw ($parseErrors | Out-String) }
$ast.FindAll({ param($node) $node -is [System.Management.Automation.Language.FunctionDefinitionAst] }, $true) | ForEach-Object {
    . ([scriptblock]::Create($_.Extent.Text))
}

function Assert-True([bool]$Condition, [string]$Message) {
    if (-not $Condition) { throw $Message }
}

function Invoke-Installer([string]$AppHome) {
    $output = & $PowerShellPath -NoLogo -NoProfile -File $installer -AppHome $AppHome 2>&1 | Out-String
    if ($LASTEXITCODE -ne 0) { throw "Windows installer returned $LASTEXITCODE`n$output" }
}

function Invoke-Uninstaller([string]$AppHome) {
    $output = & $PowerShellPath -NoLogo -NoProfile -File $uninstaller -AppHome $AppHome 2>&1 | Out-String
    if ($LASTEXITCODE -ne 0) { throw "Windows uninstaller returned $LASTEXITCODE`n$output" }
}

try {
    New-Item -ItemType Directory -Path $sandbox -Force | Out-Null

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

    $transactionDir = Join-Path $sandbox "transaction"
    New-Item -ItemType Directory -Path $transactionDir -Force | Out-Null
    $existingPath = Join-Path $transactionDir "existing.txt"
    $newPath = Join-Path $transactionDir "new.txt"
    [System.IO.File]::WriteAllText($existingPath, "original")
    [System.IO.File]::WriteAllText($existingPath, "changed")
    [System.IO.File]::WriteAllText($newPath, "created")
    Restore-Transaction @(
        [pscustomobject]@{ Path = $existingPath; Existed = $true; Original = "original" },
        [pscustomobject]@{ Path = $newPath; Existed = $false; Original = "" }
    )
    Assert-True ((Get-Content -LiteralPath $existingPath -Raw) -eq "original") "transaction did not restore original content"
    Assert-True (-not (Test-Path -LiteralPath $newPath)) "transaction did not remove newly created file"

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
    [System.IO.File]::WriteAllText((Join-Path $composeCase "config.yaml"), "ipv6: true`ntun: null`n")
    [System.IO.File]::WriteAllText((Join-Path $composeCase "verge.yaml"), "enable_tun_mode: false`n")
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
