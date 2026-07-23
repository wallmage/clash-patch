param(
    [Parameter(Mandatory = $true)]
    [string]$PowerShellPath
)

$ErrorActionPreference = "Stop"
$root = Split-Path -Parent $PSScriptRoot
$installer = Join-Path (Join-Path $root "clash-patch/scripts") "install_windows.ps1"
$uninstaller = Join-Path (Join-Path $root "clash-patch/scripts") "uninstall_windows.ps1"
$installWrapper = Join-Path (Join-Path $root "clash-patch/scripts") "install_windows.cmd"
$uninstallWrapper = Join-Path (Join-Path $root "clash-patch/scripts") "uninstall_windows.cmd"
$routeVerifier = Join-Path (Join-Path $root "clash-patch/scripts/windows") "verify_routes.ps1"
$resultContract = Join-Path (Join-Path $root "clash-patch/scripts/windows") "result_contract.ps1"
$installerModuleRoot = Join-Path (Join-Path $root "clash-patch/scripts/windows") "install_windows"
$installerModules = @(
    "common.ps1", "yaml.ps1", "profiles.ps1", "mihomo.ps1",
    "transaction.ps1", "script_js.ps1", "safe_update.ps1"
) | ForEach-Object { Join-Path $installerModuleRoot $_ }
$sandbox = Join-Path ([System.IO.Path]::GetTempPath()) ("clash-patch-windows-test-" + [System.Guid]::NewGuid().ToString("N"))
$onWindows = [Environment]::OSVersion.Platform -eq [PlatformID]::Win32NT
$previousUsageProfile = $env:CLASH_PATCH_USAGE_PROFILE
$env:CLASH_PATCH_USAGE_PROFILE = "3"
$fakeCore = Join-Path $sandbox $(if ($onWindows) { "mihomo-test.cmd" } else { "mihomo-test.sh" })
$hangingCore = Join-Path $sandbox $(if ($onWindows) { "mihomo-hang.cmd" } else { "mihomo-hang.sh" })

function Get-ProtectedAutomaticVariableNames {
    $automaticCandidates = @(
        "ConsoleFileName", "EnabledExperimentalFeatures", "ExecutionContext",
        "HOME", "Host", "IsCoreCLR", "IsLinux", "IsMacOS", "IsWindows",
        "MyInvocation", "NestedPromptLevel", "PID", "PROFILE",
        "PSBoundParameters", "PSCmdlet", "PSCommandPath", "PSCulture",
        "PSDebugContext", "PSEdition", "PSHOME", "PSScriptRoot",
        "PSSenderInfo", "PSUICulture", "PSVersionTable", "PWD",
        "ShellId", "StackTrace"
    )
    $names = @{}
    foreach ($variable in @(Get-Variable)) {
        if ($variable.Name -in @("null", "true", "false")) { continue }
        if (($variable.Options -band [System.Management.Automation.ScopedItemOptions]::ReadOnly) -or
            ($variable.Options -band [System.Management.Automation.ScopedItemOptions]::Constant)) {
            $names[$variable.Name] = $true
        }
    }
    foreach ($name in $automaticCandidates) {
        $variable = Get-Variable -Name $name -ErrorAction SilentlyContinue
        if ($null -eq $variable) { continue }
        if (($variable.Options -band [System.Management.Automation.ScopedItemOptions]::ReadOnly) -or
            ($variable.Options -band [System.Management.Automation.ScopedItemOptions]::Constant)) {
            $names[$name] = $true
        }
    }
    return $names
}

function Get-AutomaticVariableBaseName([System.Management.Automation.Language.VariableExpressionAst]$Variable) {
    $parts = $Variable.VariablePath.UserPath.Split(":")
    return $parts[$parts.Count - 1]
}

function Test-IsDirectVariableTarget(
    [System.Management.Automation.Language.VariableExpressionAst]$Variable,
    [System.Management.Automation.Language.Ast]$Target
) {
    if ($Variable -eq $Target) { return $true }
    $current = $Variable.Parent
    while ($null -ne $current -and $current -ne $Target) {
        if ($current -is [System.Management.Automation.Language.MemberExpressionAst] -or
            $current -is [System.Management.Automation.Language.IndexExpressionAst]) {
            return $false
        }
        $current = $current.Parent
    }
    return $current -eq $Target
}

function Assert-NoReadOnlyAutomaticVariableWrites(
    [System.Management.Automation.Language.ScriptBlockAst]$Ast,
    [string]$DisplayName
) {
    $protectedNames = Get-ProtectedAutomaticVariableNames
    $violations = New-Object System.Collections.ArrayList
    $recordName = {
        param([string]$Name, [System.Management.Automation.Language.Ast]$Write)
        $parts = $Name.Split(":")
        $baseName = $parts[$parts.Count - 1]
        if ($protectedNames.ContainsKey($baseName)) {
            [void]$violations.Add(("{0}:{1}: ${2} is read-only or constant" -f $DisplayName, $Write.Extent.StartLineNumber, $baseName))
        }
    }
    $record = {
        param(
            [System.Management.Automation.Language.VariableExpressionAst]$Variable,
            [System.Management.Automation.Language.Ast]$Write
        )
        & $recordName (Get-AutomaticVariableBaseName $Variable) $Write
    }

    foreach ($assignment in @($Ast.FindAll({
        param($node)
        $node -is [System.Management.Automation.Language.AssignmentStatementAst]
    }, $true))) {
        foreach ($variable in @($assignment.Left.FindAll({
            param($node)
            $node -is [System.Management.Automation.Language.VariableExpressionAst]
        }, $true))) {
            if (Test-IsDirectVariableTarget $variable $assignment.Left) {
                & $record $variable $assignment
            }
        }
    }

    foreach ($parameter in @($Ast.FindAll({
        param($node)
        $node -is [System.Management.Automation.Language.ParameterAst]
    }, $true))) {
        & $record $parameter.Name $parameter
    }

    foreach ($loop in @($Ast.FindAll({
        param($node)
        $node -is [System.Management.Automation.Language.ForEachStatementAst]
    }, $true))) {
        & $record $loop.Variable $loop
    }

    $mutationTokens = @("PlusPlus", "MinusMinus", "PostfixPlusPlus", "PostfixMinusMinus")
    foreach ($unary in @($Ast.FindAll({
        param($node)
        $node -is [System.Management.Automation.Language.UnaryExpressionAst]
    }, $true))) {
        if ($unary.TokenKind.ToString() -notin $mutationTokens) { continue }
        if ($unary.Child -is [System.Management.Automation.Language.VariableExpressionAst]) {
            & $record $unary.Child $unary
        }
    }

    $variableMutationCommands = @("Set-Variable", "New-Variable", "Clear-Variable", "Remove-Variable")
    foreach ($command in @($Ast.FindAll({
        param($node)
        $node -is [System.Management.Automation.Language.CommandAst]
    }, $true))) {
        $commandName = $command.GetCommandName()
        if ($commandName -notin $variableMutationCommands) { continue }
        $expectName = $false
        $sawPositionalName = $false
        for ($index = 1; $index -lt $command.CommandElements.Count; $index++) {
            $element = $command.CommandElements[$index]
            if ($element -is [System.Management.Automation.Language.CommandParameterAst]) {
                $expectName = $element.ParameterName -eq "Name"
                if ($expectName -and $null -ne $element.Argument -and
                    $element.Argument -is [System.Management.Automation.Language.StringConstantExpressionAst]) {
                    & $recordName $element.Argument.Value $command
                    $expectName = $false
                }
                continue
            }
            if ($element -isnot [System.Management.Automation.Language.StringConstantExpressionAst]) {
                if ($expectName) { $expectName = $false }
                continue
            }
            if ($expectName -or -not $sawPositionalName) {
                & $recordName $element.Value $command
                $sawPositionalName = $true
                $expectName = $false
            }
        }
    }

    if ($violations.Count -gt 0) { throw ($violations -join "`n") }
}

$automaticVariableGuardCases = @(
    '$host = "blocked"',
    'param([string]$HOST)',
    'foreach ($Host in @("blocked")) { }',
    '++$global:Host',
    '${script:HOST}--',
    '$safe, $Host = @("safe", "blocked")',
    'Set-Variable -Name Host -Value "blocked"'
)
foreach ($guardCase in $automaticVariableGuardCases) {
    $guardTokens = $null
    $guardErrors = $null
    $guardAst = [System.Management.Automation.Language.Parser]::ParseInput($guardCase, [ref]$guardTokens, [ref]$guardErrors)
    if ($guardErrors.Count -gt 0) { throw ($guardErrors | Out-String) }
    $guardRejected = $false
    try { Assert-NoReadOnlyAutomaticVariableWrites $guardAst "automatic-variable-guard-fixture" } catch { $guardRejected = $true }
    if (-not $guardRejected) { throw "automatic-variable guard accepted: $guardCase" }
}
$safeGuardTokens = $null
$safeGuardErrors = $null
$safeGuardAst = [System.Management.Automation.Language.Parser]::ParseInput(
    '$connectionHost = "safe"; $Host.UI.RawUI.BackgroundColor = "Red"',
    [ref]$safeGuardTokens,
    [ref]$safeGuardErrors
)
if ($safeGuardErrors.Count -gt 0) { throw ($safeGuardErrors | Out-String) }
Assert-NoReadOnlyAutomaticVariableWrites $safeGuardAst "automatic-variable-safe-fixture"

$productionPowerShellFiles = @(Get-ChildItem -LiteralPath (Join-Path $root "clash-patch/scripts") -Filter "*.ps1" -File -Recurse)
foreach ($productionPowerShellFile in $productionPowerShellFiles) {
    $productionTokens = $null
    $productionParseErrors = $null
    $productionAst = [System.Management.Automation.Language.Parser]::ParseFile(
        $productionPowerShellFile.FullName,
        [ref]$productionTokens,
        [ref]$productionParseErrors
    )
    if ($productionParseErrors.Count -gt 0) { throw ($productionParseErrors | Out-String) }
    Assert-NoReadOnlyAutomaticVariableWrites $productionAst $productionPowerShellFile.FullName
}

$tokens = $null
$parseErrors = $null
$ast = [System.Management.Automation.Language.Parser]::ParseFile($installer, [ref]$tokens, [ref]$parseErrors)
if ($parseErrors.Count -gt 0) { throw ($parseErrors | Out-String) }
$entryFunctions = @($ast.FindAll({ param($node) $node -is [System.Management.Automation.Language.FunctionDefinitionAst] }, $true))
if ($entryFunctions.Count -ne 0) { throw "install_windows.ps1 still contains library functions" }
$loadedFunctions = @{}
foreach ($modulePath in $installerModules) {
    if (-not (Test-Path -LiteralPath $modulePath -PathType Leaf)) { throw "missing installer module: $modulePath" }
    $moduleTokens = $null
    $moduleParseErrors = $null
    $moduleAst = [System.Management.Automation.Language.Parser]::ParseFile($modulePath, [ref]$moduleTokens, [ref]$moduleParseErrors)
    if ($moduleParseErrors.Count -gt 0) { throw ($moduleParseErrors | Out-String) }
    foreach ($statement in @($moduleAst.EndBlock.Statements)) {
        if (-not ($statement -is [System.Management.Automation.Language.FunctionDefinitionAst])) {
            throw "installer module has a load-time side effect: $modulePath"
        }
    }
    foreach ($functionAst in @($moduleAst.FindAll({ param($node) $node -is [System.Management.Automation.Language.FunctionDefinitionAst] }, $true))) {
        if ($loadedFunctions.ContainsKey($functionAst.Name)) { throw "duplicate installer function: $($functionAst.Name)" }
        $loadedFunctions[$functionAst.Name] = $true
    }
    . $modulePath
}
$routeTokens = $null
$routeParseErrors = $null
$routeAst = [System.Management.Automation.Language.Parser]::ParseFile($routeVerifier, [ref]$routeTokens, [ref]$routeParseErrors)
if ($routeParseErrors.Count -gt 0) { throw ($routeParseErrors | Out-String) }
$routeAst.FindAll({
    param($node)
    $node -is [System.Management.Automation.Language.FunctionDefinitionAst] -and
        $node.Name -in @("Find-Group", "Test-RouteChains")
}, $true) | ForEach-Object { . ([scriptblock]::Create($_.Extent.Text)) }
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

function Assert-JsonResult([object]$Invocation, [string]$Command, [int]$ExitCode) {
    $text = $Invocation.Output.Trim()
    Assert-True ($text.StartsWith("{") -and $text.EndsWith("}")) "JSON mode did not emit exactly one object: $text"
    try { $result = $text | ConvertFrom-Json } catch { throw "JSON mode emitted invalid JSON: $text" }
    foreach ($field in @("schema", "version", "command", "platform", "client", "operation", "ok", "status", "code", "exit_code", "summary_zh", "profile", "changes", "checks", "items", "messages", "warnings")) {
        Assert-True ($null -ne $result.PSObject.Properties[$field]) "JSON result omitted $field"
    }
    Assert-True ($result.schema -eq "clash-patch.result") "JSON result schema mismatch"
    Assert-True ([int]$result.version -eq 1) "JSON result version mismatch"
    Assert-True ($result.command -eq $Command) "JSON result command mismatch"
    Assert-True ($result.platform -eq "windows") "JSON result platform mismatch"
    Assert-True ($result.client -eq "clash-verge-rev") "JSON result client mismatch"
    Assert-True ([int]$result.exit_code -eq $ExitCode) "JSON result exit_code disagrees with process exit"
    Assert-True ($Invocation.ExitCode -eq $ExitCode) "process exit mismatch"
    Assert-True ($text -notmatch '(?i)https?://|Bearer\s+|password\s*[:=]|secret\s*[:=]') "JSON result leaked a secret or URL"
    return $result
}

function Invoke-TestPowerShell([string]$ScriptPath, [string[]]$ScriptArguments) {
    $previousPreference = $ErrorActionPreference
    try {
        $ErrorActionPreference = "Continue"
        $output = & $PowerShellPath -NoLogo -NoProfile -File $ScriptPath @ScriptArguments 2>&1 | Out-String
        $exitCode = $LASTEXITCODE
        return [pscustomobject]@{ Output = $output; ExitCode = $exitCode }
    } finally {
        $ErrorActionPreference = $previousPreference
    }
}

function Invoke-Installer([string]$AppHome) {
    $result = Invoke-TestPowerShell $installer @("-AppHome", $AppHome, "-MihomoPath", $fakeCore)
    if ($result.ExitCode -ne 0) { throw "Windows installer returned $($result.ExitCode)`n$($result.Output)" }
}

function Invoke-Uninstaller([string]$AppHome) {
    $result = Invoke-TestPowerShell $uninstaller @("-AppHome", $AppHome)
    if ($result.ExitCode -ne 0) { throw "Windows uninstaller returned $($result.ExitCode)`n$($result.Output)" }
}

function Assert-InstallerRejectsScript([string]$Name, [string]$Script, [string]$MessageFragment) {
    $case = Join-Path $sandbox $Name
    $profiles = Join-Path $case "profiles"
    New-Item -ItemType Directory -Path $profiles -Force | Out-Null
    [System.IO.File]::WriteAllText((Join-Path $case "config.yaml"), "ipv6: true`ntun: null`n")
    [System.IO.File]::WriteAllText((Join-Path $case "verge.yaml"), "enable_tun_mode: false`n")
    [System.IO.File]::WriteAllText((Join-Path $case "profiles.yaml"), "items:`n- uid: R-test`n  type: remote`n  option:`n    allow_auto_update: true`n")
    $scriptPath = Join-Path $profiles "Script.js"
    [System.IO.File]::WriteAllText($scriptPath, $Script)
    $result = Invoke-TestPowerShell $installer @("-AppHome", $case, "-MihomoPath", $fakeCore)
    Assert-True ($result.ExitCode -eq 1) "$Name was accepted"
    Assert-True ($result.Output.Contains($MessageFragment)) "$Name rejection did not explain the problem: $($result.Output)"
    Assert-True ((Get-Content -LiteralPath $scriptPath -Raw) -eq $Script) "$Name rejection changed Script.js"
}

try {
    New-Item -ItemType Directory -Path $sandbox -Force | Out-Null
    if ($onWindows) {
        $fakeCoreText = "@echo off`r`necho %*>>`"%~dp0mihomo-arguments.log`"`r`nif `"%1`"==`"-v`" (`r`n  echo Mihomo Meta v1.19.27 windows amd64`r`n  exit /b 0`r`n)`r`nexit /b 0`r`n"
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

    if ($onWindows) {
        $wrapperCase = Join-Path $sandbox "cmd-wrapper-case"
        New-Item -ItemType Directory -Path $wrapperCase -Force | Out-Null
        $wrapperOutput = & $installWrapper -ShowUsageProfile -AppHome $wrapperCase 2>&1 | Out-String
        Assert-True ($LASTEXITCODE -eq 0) "install_windows.cmd did not propagate a successful exit: $wrapperOutput"
        Assert-True ($wrapperOutput.Contains("unset")) "install_windows.cmd did not forward PowerShell output"

        $wrapperJsonOutput = & $installWrapper -ShowUsageProfile -AppHome $wrapperCase -Json 2>&1 | Out-String
        Assert-True ($LASTEXITCODE -eq 0) "install_windows.cmd did not propagate JSON-mode success: $wrapperJsonOutput"
        $wrapperJson = $wrapperJsonOutput.Trim() | ConvertFrom-Json
        Assert-True ($wrapperJson.schema -eq "clash-patch.result") "install_windows.cmd did not pass -Json through"

        $invalidWrapperOutput = & $installWrapper -UsageProfile 9 -AppHome $wrapperCase -Json 2>&1 | Out-String
        $invalidWrapperExit = $LASTEXITCODE
        Assert-True ($invalidWrapperExit -eq 64) "install_windows.cmd swallowed an installer failure: $invalidWrapperOutput"
        $invalidWrapperJson = $invalidWrapperOutput.Trim() | ConvertFrom-Json
        Assert-True ([int]$invalidWrapperJson.exit_code -eq $invalidWrapperExit) "install_windows.cmd changed the JSON failure exit code"

        $wrapperBackup = Join-Path (Join-Path $wrapperCase "clash-patch-backups") "keep.backup"
        New-Item -ItemType Directory -Path (Split-Path -Parent $wrapperBackup) -Force | Out-Null
        [System.IO.File]::WriteAllText($wrapperBackup, "keep")
        $uninstallWrapperOutput = & $uninstallWrapper -AppHome $wrapperCase 2>&1 | Out-String
        Assert-True ($LASTEXITCODE -eq 0) "uninstall_windows.cmd did not propagate a successful exit: $uninstallWrapperOutput"
        Assert-True (Test-Path -LiteralPath $wrapperBackup -PathType Leaf) "uninstall_windows.cmd deleted configuration history"
    }
    [System.IO.File]::WriteAllText($hangingCore, $hangingCoreText, [System.Text.Encoding]::ASCII)
    if (-not $onWindows) { & /bin/chmod 700 $hangingCore }

    . $resultContract
    $contractResult = New-ClashPatchResult -Command "install" -Operation "test" -Ok $true -Status "ok" -Code "ok" -ExitCode 0 -SummaryZh "完成"
    foreach ($field in @("schema", "version", "command", "platform", "client", "operation", "ok", "status", "code", "exit_code", "summary_zh", "profile", "changes", "checks", "items", "messages", "warnings")) {
        Assert-True ($null -ne $contractResult.PSObject.Properties[$field]) "result contract omitted $field"
    }
    $invalidContractCommandRejected = $false
    try { New-ClashPatchResult -Command "contract-test" -Operation "test" -Ok $true -Status "ok" -Code "ok" -ExitCode 0 -SummaryZh "完成" | Out-Null } catch { $invalidContractCommandRejected = $true }
    Assert-True $invalidContractCommandRejected "result contract accepted an unstable command name"
    $nestedSecretResult = New-ClashPatchResult -Command "install" -Operation "test" -Ok $true -Status "ok" -Code "ok" -ExitCode 0 -SummaryZh "完成" -Checks @([pscustomobject]@{ nested = [ordered]@{ url = "https://secret.invalid/path"; path = "C:\Users\friend\secret.yaml"; token = "token=private"; uuid = "11111111-2222-3333-4444-555555555555" } })
    $nestedSecretJson = $nestedSecretResult | ConvertTo-Json -Depth 8 -Compress
    Assert-True ($nestedSecretJson -notmatch 'secret\.invalid|C:\\Users\\friend|token=private|11111111-2222-3333-4444-555555555555') "result contract leaked nested sensitive text"

    $jsonShowCase = Join-Path $sandbox "json-show-case"
    New-Item -ItemType Directory -Path $jsonShowCase -Force | Out-Null
    $jsonShow = Invoke-TestPowerShell $installer @("-AppHome", $jsonShowCase, "-ShowUsageProfile", "-Json")
    $jsonShowResult = Assert-JsonResult $jsonShow "install" 0
    Assert-True ($jsonShowResult.operation -eq "show_usage_profile") "show-profile operation mismatch"
    Assert-True ($jsonShowResult.profile -eq $null) "unset profile was not represented as null"

    $jsonInvalid = Invoke-TestPowerShell $installer @("-AppHome", $jsonShowCase, "-UsageProfile", "9", "-Json")
    $jsonInvalidResult = Assert-JsonResult $jsonInvalid "install" 64
    Assert-True (-not [bool]$jsonInvalidResult.ok) "invalid request was reported as successful"
    Assert-True ($jsonInvalidResult.status -eq "invalid_request") "invalid request status mismatch"

    $jsonUninstall = Invoke-TestPowerShell $uninstaller @("-AppHome", $jsonShowCase, "-Json")
    $jsonUninstallResult = Assert-JsonResult $jsonUninstall "uninstall" 0
    Assert-True ($jsonUninstallResult.status -eq "no_change") "empty uninstall was not no_change"

    $jsonRouteFailure = Invoke-TestPowerShell $routeVerifier @("-ObservationSeconds", "0", "-Secret", "fixture-secret", "-Json")
    $jsonRouteFailureResult = Assert-JsonResult $jsonRouteFailure "verify_routes" 1
    Assert-True ($jsonRouteFailureResult.code -eq "verification_failed") "route verifier did not structure its parameter failure"

    $routeHarnessPath = Join-Path $sandbox "verify-route-observer.ps1"
    $routeFunctionSources = $routeAst.FindAll({
        param($node)
        $node -is [System.Management.Automation.Language.FunctionDefinitionAst] -and
            $node.Name -in @("Test-RouteChains", "Observe-Route")
    }, $true) | ForEach-Object { $_.Extent.Text }
    $routeHarnessMocks = @'
$ErrorActionPreference = "Stop"
$ObservationSeconds = 1
$Json = $true
$script:ClashPatchChecks = New-Object System.Collections.ArrayList
function Get-ConnectionIds { return @{} }
function Start-TestTraffic([string]$Url) {
    $process = [pscustomobject]@{ HasExited = $true }
    $process | Add-Member -MemberType ScriptMethod -Name Dispose -Value {}
    return $process
}
function Start-Sleep { }
function Invoke-ControllerJson([string]$Endpoint) {
    return [pscustomobject]@{
        connections = @(
            [pscustomobject]@{
                id = "new-google-connection"
                metadata = [pscustomobject]@{ host = "www.google.com" }
                chains = @("Fixture Node", "Main")
            }
        )
    }
}
$proxies = [pscustomobject]@{
    Main = [pscustomobject]@{ type = "Selector"; now = "Fixture Node" }
}
$passed = Observe-Route "Google" "https://www.google.com/" "google" "Main" "Fixture Node" $proxies "AI" $true
if (-not $passed) { throw "Observe-Route rejected a matching routed connection." }
'@
    $routeHarness = (@($routeFunctionSources) + $routeHarnessMocks) -join "`r`n"
    [System.IO.File]::WriteAllText($routeHarnessPath, $routeHarness, (New-Object System.Text.UTF8Encoding($true)))
    $routeObservation = Invoke-TestPowerShell $routeHarnessPath @()
    Assert-True ($routeObservation.ExitCode -eq 0) "Observe-Route crashed on a matching connection: $($routeObservation.Output)"

    if ($onWindows) {
        $controllerReadyPath = Join-Path $sandbox "route-controller-ready"
        $portProbe = [System.Net.Sockets.TcpListener]::new([System.Net.IPAddress]::Loopback, 0)
        $portProbe.Start()
        $routeControllerPort = ([System.Net.IPEndPoint]$portProbe.LocalEndpoint).Port
        $portProbe.Stop()
        $routeControllerJob = Start-Job -ArgumentList @($routeControllerPort, $controllerReadyPath) -ScriptBlock {
            param([int]$Port, [string]$ReadyPath)
            $listener = [System.Net.Sockets.TcpListener]::new([System.Net.IPAddress]::Loopback, $Port)
            $listener.Start()
            [System.IO.File]::WriteAllText($ReadyPath, "ready")
            $connectionRequest = 0
            try {
                for ($requestNumber = 0; $requestNumber -lt 9; $requestNumber++) {
                    $client = $listener.AcceptTcpClient()
                    try {
                        $stream = $client.GetStream()
                        $reader = [System.IO.StreamReader]::new($stream, [System.Text.Encoding]::ASCII, $false, 1024, $true)
                        $requestLine = $reader.ReadLine()
                        $headers = @{}
                        while ($true) {
                            $line = $reader.ReadLine()
                            if ([string]::IsNullOrEmpty($line)) { break }
                            $separator = $line.IndexOf(":")
                            if ($separator -gt 0) {
                                $headers[$line.Substring(0, $separator).Trim()] = $line.Substring($separator + 1).Trim()
                            }
                        }
                        $path = $requestLine.Split(" ")[1]
                        $status = "200 OK"
                        if ($headers["Authorization"] -ne "Bearer fixture-secret") {
                            $status = "401 Unauthorized"
                            $body = '{"error":"unauthorized"}'
                        } elseif ($path -eq "/proxies") {
                            $body = @{
                                proxies = @{
                                    Proxy = @{ type = "Selector"; now = "Main Node" }
                                    AI = @{ type = "Selector"; now = "AI Node" }
                                }
                            } | ConvertTo-Json -Depth 6 -Compress
                        } elseif ($path -eq "/connections") {
                            $connectionRequest += 1
                            if (($connectionRequest % 2) -eq 1) {
                                $connections = @()
                            } else {
                                $routeIndex = [int]($connectionRequest / 2) - 1
                                $hosts = @("www.google.com", "openai.com", "www.anthropic.com", "claude.ai")
                                $groups = @("Proxy", "AI", "AI", "AI")
                                $nodes = @("Main Node", "AI Node", "AI Node", "AI Node")
                                $connections = @(@{
                                    id = "route-$routeIndex"
                                    metadata = @{ host = $hosts[$routeIndex] }
                                    chains = @($nodes[$routeIndex], $groups[$routeIndex])
                                })
                            }
                            $body = @{ connections = $connections } | ConvertTo-Json -Depth 6 -Compress
                        } else {
                            $status = "404 Not Found"
                            $body = '{"error":"not_found"}'
                        }
                        $bodyBytes = [System.Text.Encoding]::UTF8.GetBytes($body)
                        $responseHead = "HTTP/1.1 $status`r`nContent-Type: application/json`r`nContent-Length: $($bodyBytes.Length)`r`nConnection: close`r`n`r`n"
                        $headBytes = [System.Text.Encoding]::ASCII.GetBytes($responseHead)
                        $stream.Write($headBytes, 0, $headBytes.Length)
                        $stream.Write($bodyBytes, 0, $bodyBytes.Length)
                        $stream.Flush()
                        $reader.Dispose()
                    } finally {
                        $client.Dispose()
                    }
                }
            } finally {
                $listener.Stop()
            }
        }
        $fakeCurlDirectory = Join-Path $sandbox "fake-curl"
        New-Item -ItemType Directory -Path $fakeCurlDirectory -Force | Out-Null
        Copy-Item -LiteralPath (Join-Path (Join-Path $env:SystemRoot "System32") "where.exe") -Destination (Join-Path $fakeCurlDirectory "curl.exe")
        $previousPath = $env:PATH
        try {
            $readyDeadline = [DateTime]::UtcNow.AddSeconds(10)
            while (-not (Test-Path -LiteralPath $controllerReadyPath) -and [DateTime]::UtcNow -lt $readyDeadline) {
                Start-Sleep -Milliseconds 100
            }
            Assert-True (Test-Path -LiteralPath $controllerReadyPath) "route success controller did not start: $(Receive-Job $routeControllerJob -Keep | Out-String)"
            $env:PATH = $fakeCurlDirectory + [System.IO.Path]::PathSeparator + $previousPath
            $routeSuccess = Invoke-TestPowerShell $routeVerifier @(
                "-ControllerUrl", "http://127.0.0.1:$routeControllerPort",
                "-Secret", "fixture-secret",
                "-ObservationSeconds", "2",
                "-Json"
            )
            $routeSuccessResult = Assert-JsonResult $routeSuccess "verify_routes" 0
            Assert-True ($routeSuccessResult.code -eq "routes_verified") "route verifier success code mismatch"
            Assert-True (@($routeSuccessResult.checks).Count -eq 4) "route verifier did not report all four route checks"
            Assert-True (@($routeSuccessResult.checks | Where-Object { -not [bool]$_.ok }).Count -eq 0) "route verifier reported a failed check on its success path"
        } finally {
            $env:PATH = $previousPath
            if ($null -ne $routeControllerJob) {
                Stop-Job $routeControllerJob -ErrorAction SilentlyContinue
                Remove-Job $routeControllerJob -Force -ErrorAction SilentlyContinue
            }
        }
    }

    $brokenPackageRoot = Join-Path $sandbox "broken-package"
    New-Item -ItemType Directory -Path $brokenPackageRoot -Force | Out-Null
    $brokenInstaller = Join-Path $brokenPackageRoot "install_windows.ps1"
    Copy-Item -LiteralPath $installer -Destination $brokenInstaller
    $missingContract = Invoke-TestPowerShell $brokenInstaller @("-AppHome", $jsonShowCase, "-Json")
    $missingContractResult = Assert-JsonResult $missingContract "install" 6
    Assert-True ($missingContractResult.code -eq "incomplete_package") "missing result contract was not structured"

    $brokenWindows = Join-Path $brokenPackageRoot "windows"
    New-Item -ItemType Directory -Path $brokenWindows -Force | Out-Null
    Copy-Item -LiteralPath $resultContract -Destination (Join-Path $brokenWindows "result_contract.ps1")
    $missingModules = Invoke-TestPowerShell $brokenInstaller @("-AppHome", $jsonShowCase, "-Json")
    $missingModulesResult = Assert-JsonResult $missingModules "install" 6
    Assert-True ($missingModulesResult.code -eq "incomplete_package") "missing installer modules were not structured"

    $brokenUninstaller = Join-Path $brokenPackageRoot "uninstall_windows.ps1"
    $brokenVerifier = Join-Path $brokenPackageRoot "verify_routes.ps1"
    Copy-Item -LiteralPath $uninstaller -Destination $brokenUninstaller
    Copy-Item -LiteralPath $routeVerifier -Destination $brokenVerifier
    Remove-Item -LiteralPath (Join-Path $brokenWindows "result_contract.ps1") -Force
    Assert-JsonResult (Invoke-TestPowerShell $brokenUninstaller @("-AppHome", $jsonShowCase, "-Json")) "uninstall" 6 | Out-Null
    Assert-JsonResult (Invoke-TestPowerShell $brokenVerifier @("-ObservationSeconds", "0", "-Json")) "verify_routes" 6 | Out-Null

    $lightCase = Join-Path $sandbox "light-profile-case"
    New-Item -ItemType Directory -Path $lightCase -Force | Out-Null
    $lightConfig = "ipv6: true`ntun:`n  enable: false`n"
    $lightVerge = "enable_tun_mode: false`n"
    [System.IO.File]::WriteAllText((Join-Path $lightCase "config.yaml"), $lightConfig)
    [System.IO.File]::WriteAllText((Join-Path $lightCase "verge.yaml"), $lightVerge)
    $profileOne = Invoke-TestPowerShell $installer @("-AppHome", $lightCase, "-UsageProfile", "1", "-MihomoPath", $fakeCore)
    Assert-True ($profileOne.ExitCode -eq 0) "profile 1 installer failed: $($profileOne.Output)"
    Assert-True ((Get-Content -LiteralPath (Join-Path $lightCase "config.yaml") -Raw) -eq $lightConfig) "profile 1 modified config.yaml"
    Assert-True ((Get-Content -LiteralPath (Join-Path $lightCase "verge.yaml") -Raw) -eq $lightVerge) "profile 1 modified verge.yaml"
    $lightScript = Join-Path (Join-Path $lightCase "profiles") "Script.js"
    Assert-True (Test-Path -LiteralPath $lightScript -PathType Leaf) "profile 1 did not install the shared subscription patch"
    $profileOneScript = Get-Content -LiteralPath $lightScript -Raw
    Assert-True ($profileOneScript.Contains("const CLASH_PATCH_USAGE_PROFILE = 1;")) "profile 1 script has the wrong usage profile"
    Assert-True ($profileOneScript.Contains("cnDomainProvider")) "profile 1 script omitted the China-domain provider"
    $savedProfileOne = Get-Content -LiteralPath (Join-Path $lightCase "clash-patch-usage-profile.json") -Raw | ConvertFrom-Json
    Assert-True ([int]$savedProfileOne.Profile -eq 1) "profile 1 was not saved"
    $profileTwo = Invoke-TestPowerShell $installer @("-AppHome", $lightCase, "-UsageProfile", "2", "-MihomoPath", $fakeCore)
    Assert-True ($profileTwo.ExitCode -eq 0) "profile 2 installer failed: $($profileTwo.Output)"
    Assert-True ((Get-Content -LiteralPath (Join-Path $lightCase "config.yaml") -Raw) -eq $lightConfig) "profile 2 modified config.yaml"
    Assert-True (Test-Path -LiteralPath $lightScript -PathType Leaf) "profile 2 removed the shared subscription patch"
    $profileTwoScript = Get-Content -LiteralPath $lightScript -Raw
    Assert-True ($profileTwoScript.Contains("const CLASH_PATCH_USAGE_PROFILE = 2;")) "profile 2 script has the wrong usage profile"
    Assert-True ($profileTwoScript.Contains("cnDomainProvider")) "profile 2 script omitted the China-domain provider"
    $savedProfileTwo = Get-Content -LiteralPath (Join-Path $lightCase "clash-patch-usage-profile.json") -Raw | ConvertFrom-Json
    Assert-True ([int]$savedProfileTwo.Profile -eq 2) "profile 2 was not saved"

    $downgradeCase = Join-Path $sandbox "downgrade-without-uninstall-case"
    New-Item -ItemType Directory -Path $downgradeCase -Force | Out-Null
    $downgradeStatePath = Join-Path $downgradeCase "clash-patch-usage-profile.json"
    $downgradeState = '{"Version":1,"Profile":3}' + "`r`n"
    [System.IO.File]::WriteAllText($downgradeStatePath, $downgradeState)
    $downgradeResult = Invoke-TestPowerShell $installer @("-AppHome", $downgradeCase, "-UsageProfile", "1", "-MihomoPath", $fakeCore)
    Assert-True ($downgradeResult.ExitCode -eq 1) "profile 3 downgrade proceeded without the required safe uninstall"
    Assert-True ($downgradeResult.Output.Contains("先运行安全卸载")) "profile 3 downgrade rejection did not explain the required safe uninstall"
    Assert-True ((Get-Content -LiteralPath $downgradeStatePath -Raw) -eq $downgradeState) "rejected downgrade changed the saved usage profile"
    Assert-True (-not (Test-Path -LiteralPath (Join-Path (Join-Path $downgradeCase "profiles") "Script.js"))) "rejected downgrade changed the global script"

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

    $profilesIndexInput = @'
current: R-first
items:
- uid: R-first
  type: remote
  name: First
  option:
    update_interval: 1440
    allow_auto_update: true
- uid: L-local
  type: local
  name: Local
- uid: R-second
  type: remote
  name: Second
  option: null
'@
    $profilesIndexOutput = Set-RemoteSubscriptionAutoUpdateDisabled $profilesIndexInput
    Assert-True ([regex]::Matches($profilesIndexOutput, '(?m)^\s+allow_auto_update:\s+false\s*$').Count -eq 2) "not every remote subscription was disabled"
    Assert-True ($profilesIndexOutput.Contains("type: local")) "local profile was removed"
    Assert-True ($profilesIndexOutput.Contains("update_interval: 1440")) "unrelated remote option was removed"
    Assert-True ((Set-RemoteSubscriptionAutoUpdateDisabled $profilesIndexOutput) -eq $profilesIndexOutput) "profiles.yaml transform is not idempotent"
    Assert-RemoteSubscriptionAutoUpdateDisabled $profilesIndexOutput

    $flowProfilesRejected = $false
    try { Set-RemoteSubscriptionAutoUpdateDisabled "items: [{ type: remote }]`n" | Out-Null } catch { $flowProfilesRejected = $true }
    Assert-True $flowProfilesRejected "inline profiles list was modified instead of rejected"

    $safeUpdateCase = Join-Path $sandbox "safe-update-case"
    $safeUpdateProfiles = Join-Path $safeUpdateCase "profiles"
    New-Item -ItemType Directory -Path $safeUpdateProfiles -Force | Out-Null
    [System.IO.File]::WriteAllText((Join-Path $safeUpdateCase "profiles.yaml"), $profilesIndexInput)
    $firstSafeOriginal = "proxies: []`nrules: []`n"
    $secondSafeOriginal = "proxies: []`nproxy-groups: []`n"
    [System.IO.File]::WriteAllText((Join-Path $safeUpdateProfiles "R-first.yaml"), $firstSafeOriginal)
    [System.IO.File]::WriteAllText((Join-Path $safeUpdateProfiles "R-second.yml"), $secondSafeOriginal)
    [System.IO.File]::WriteAllText((Join-Path $safeUpdateProfiles "L-local.yaml"), "local: true`n")
    $remoteTargets = @(Get-RemoteSubscriptionTargets $profilesIndexInput $safeUpdateProfiles)
    Assert-True ($remoteTargets.Count -eq 2) "two distinct remote subscriptions were not mapped independently"
    Assert-True ((@($remoteTargets | ForEach-Object { $_.Path } | Sort-Object -Unique)).Count -eq 2) "distinct remote subscriptions were mapped to one file"
    if ($onWindows) {
        $caseAliasIndex = "items:`n- uid: Case-Alias`n  type: remote`n- uid: case-alias`n  type: remote`n"
        [System.IO.File]::WriteAllText((Join-Path $safeUpdateProfiles "case-alias.yaml"), "proxies: []`n")
        $caseAliasRejected = $false
        try { Get-RemoteSubscriptionTargets $caseAliasIndex $safeUpdateProfiles | Out-Null } catch { $caseAliasRejected = $_.Exception.Message.Contains("多个远程订阅") }
        Assert-True $caseAliasRejected "case-alias remote subscriptions were allowed to share one file"
    }
    $snapshotResult = Invoke-TestPowerShell $installer @("-AppHome", $safeUpdateCase, "-SnapshotProfiles")
    Assert-True ($snapshotResult.ExitCode -eq 0) "safe update snapshot failed: $($snapshotResult.Output)"
    $safeBackups = @(Get-ChildItem -LiteralPath (Join-Path $safeUpdateCase "clash-patch-backups") -File | Where-Object { $_.Name -like "*--pre-update--*" })
    Assert-True ($safeBackups.Count -eq 2) "snapshot did not back up exactly the two remote subscriptions"
    [System.IO.File]::WriteAllText((Join-Path $safeUpdateProfiles "R-first.yaml"), "changed: true`n")
    [System.IO.File]::WriteAllText((Join-Path $safeUpdateProfiles "R-second.yml"), "first: true`n---`nsecond: true`n")
    $verifyResult = Invoke-TestPowerShell $installer @("-AppHome", $safeUpdateCase, "-VerifySafeUpdate", "-MihomoPath", $fakeCore)
    Assert-True ($verifyResult.ExitCode -eq 1) "invalid safe update was accepted"
    Assert-True ((Get-Content -LiteralPath (Join-Path $safeUpdateProfiles "R-first.yaml") -Raw) -eq $firstSafeOriginal) "failed safe update did not restore first remote subscription"
    Assert-True ((Get-Content -LiteralPath (Join-Path $safeUpdateProfiles "R-second.yml") -Raw) -eq $secondSafeOriginal) "failed safe update did not restore second remote subscription"
    Assert-True (-not (Test-Path -LiteralPath (Join-Path $safeUpdateCase "clash-patch-safe-update.json"))) "completed rollback left a reusable stale safe-update manifest"

    $successSnapshot = Invoke-TestPowerShell $installer @("-AppHome", $safeUpdateCase, "-SnapshotProfiles")
    Assert-True ($successSnapshot.ExitCode -eq 0) "second safe update snapshot failed: $($successSnapshot.Output)"
    $firstSafeUpdated = "mode: rule`nproxies: []`n"
    $secondSafeUpdated = "mode: global`nproxy-groups: []`n"
    [System.IO.File]::WriteAllText((Join-Path $safeUpdateProfiles "R-first.yaml"), $firstSafeUpdated)
    [System.IO.File]::WriteAllText((Join-Path $safeUpdateProfiles "R-second.yml"), $secondSafeUpdated)
    $successVerify = Invoke-TestPowerShell $installer @("-AppHome", $safeUpdateCase, "-VerifySafeUpdate", "-MihomoPath", $fakeCore)
    Assert-True ($successVerify.ExitCode -eq 0) "valid safe update was rejected: $($successVerify.Output)"
    Assert-True ((Get-Content -LiteralPath (Join-Path $safeUpdateProfiles "R-first.yaml") -Raw) -eq $firstSafeUpdated) "valid safe update incorrectly restored first remote subscription"
    Assert-True ((Get-Content -LiteralPath (Join-Path $safeUpdateProfiles "R-second.yml") -Raw) -eq $secondSafeUpdated) "valid safe update incorrectly restored second remote subscription"
    Assert-True (-not (Test-Path -LiteralPath (Join-Path $safeUpdateCase "clash-patch-safe-update.json"))) "accepted safe update left a stale manifest"

    $concurrentTarget = Join-Path $safeUpdateProfiles "concurrent.yaml"
    $concurrentBackup = Join-Path $safeUpdateProfiles "concurrent.backup"
    [System.IO.File]::WriteAllText($concurrentTarget, "observed: true`n")
    [System.IO.File]::WriteAllText($concurrentBackup, "before: true`n")
    $observedHashes = @{ $concurrentTarget = (Get-FileSha256 $concurrentTarget) }
    [System.IO.File]::WriteAllText($concurrentTarget, "newer: true`n")
    $concurrentRecovery = [pscustomobject]@{
        File = "concurrent.yaml"
        TargetPath = $concurrentTarget
        BackupPath = $concurrentBackup
        BeforeSha256 = (Get-FileSha256 $concurrentBackup)
    }
    $concurrentRestore = Restore-SafeUpdateFiles @($concurrentRecovery) $observedHashes
    Assert-True ($concurrentRestore.Conflicts.Count -eq 1) "safe update rollback did not detect a concurrent subscription change"
    Assert-True ((Get-Content -LiteralPath $concurrentTarget -Raw) -eq "newer: true`n") "safe update rollback overwrote a concurrent subscription change"

    $beforeComparison = "dns:`n  nameserver:`n    - https://old-secret.invalid/dns-query`nrules:`n  - MATCH,OldSecret`nipv6: true`n"
    $afterComparison = "dns:`n  nameserver:`n    - https://new-secret.invalid/dns-query`nrules:`n  - MATCH,NewSecret`n  - GEOSITE,CN,DIRECT`ninvalid-key: kept`n"
    $changedFields = @(Get-RedactedYamlChangedPaths $beforeComparison $afterComparison)
    Assert-True ($changedFields -contains "dns.nameserver") "Windows comparison did not identify dns.nameserver"
    Assert-True ($changedFields -contains "rules") "Windows comparison did not identify the rules section"
    Assert-True ($changedFields -contains "ipv6") "Windows comparison did not identify a removed field"
    Assert-True ($changedFields -contains "invalid-key") "Windows comparison did not identify an added field"
    Assert-True (-not (($changedFields -join " ").Contains("Secret"))) "Windows comparison exposed a configuration value"
    $arrayBefore = "proxies:`n  - name: SecretOne`n    type: ss`n  - name: SecretTwo`n    type: vmess`n"
    $arrayAfter = "proxies:`n  - name: SecretOne`n    type: ss`n  - name: SecretTwo`n    type: trojan`n"
    $arrayChanges = @(Get-RedactedYamlChangedPaths $arrayBefore $arrayAfter)
    Assert-True ($arrayChanges -contains "proxies") "Windows comparison did not safely summarize a changed mapping array"
    Assert-True (-not (($arrayChanges -join " ").Contains("Secret"))) "Windows array comparison exposed a configuration value"
    $routeGroups = [pscustomobject]@{
        "Proxy" = [pscustomobject]@{ type = "Selector"; now = "Taiwan" }
        "🤖 AI · Clash Patch" = [pscustomobject]@{ type = "Selector"; now = "Taiwan" }
    }
    Assert-True ((Find-Group $routeGroups @("AI") "" "AI 分组") -eq "🤖 AI · Clash Patch") "Windows route verifier did not recognize its managed AI group"
    $routeChains = [pscustomobject]@{
        Main = [pscustomobject]@{ type = "Selector"; now = "Taiwan" }
        AI = [pscustomobject]@{ type = "Selector"; now = "Japan" }
        Google = [pscustomobject]@{ type = "Selector"; now = "Singapore" }
    }
    Assert-True (Test-RouteChains $routeChains @("Singapore", "Google") "Main" "Taiwan" "AI" $true) "Windows route verifier rejected a user Google proxy group"
    Assert-True (-not (Test-RouteChains $routeChains @("Japan", "AI", "Google") "Main" "Taiwan" "AI" $true)) "Windows route verifier accepted the AI group for ordinary Google traffic"
    Assert-True (Test-RouteChains $routeChains @("Japan", "AI") "AI" "Japan" "AI" $false) "Windows route verifier rejected the required AI group"

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
    $versionedBackupRoot = Join-Path $sandbox "versioned-backups"
    $backupBytes = [byte[]](0xEF, 0xBB, 0xBF, 0x66, 0x69, 0x72, 0x73, 0x74)
    [System.IO.File]::WriteAllBytes($backupSource, $backupBytes)
    $firstVersionedBackup = Backup-Versioned $backupSource $versionedBackupRoot "prewrite"
    [System.IO.File]::WriteAllText($backupSource, "second")
    $secondVersionedBackup = Backup-Versioned $backupSource $versionedBackupRoot "prewrite"
    Assert-True ($firstVersionedBackup -ne $secondVersionedBackup) "versioned backups collided"
    Assert-True ((Split-Path -Leaf $firstVersionedBackup) -match '^\d{4}-\d{2}-\d{2}_\d{2}-\d{2}-\d{2}\.\d{7}[+-]\d{4}--prewrite--[0-9a-f]{16}--backup-source\.txt\.backup$') "versioned backup name lacks a date: $firstVersionedBackup"
    $savedBackup = [System.IO.File]::ReadAllBytes($firstVersionedBackup)
    Assert-True (([Convert]::ToBase64String($savedBackup)) -eq ([Convert]::ToBase64String($backupBytes))) "first versioned backup changed"
    Assert-True ((Get-Content -LiteralPath $secondVersionedBackup -Raw) -eq "second") "second versioned backup did not capture the next write"
    $initialOne = Backup-InitialOnce $backupSource $versionedBackupRoot
    $initialTwo = Backup-InitialOnce $backupSource $versionedBackupRoot
    Assert-True (-not [string]::IsNullOrWhiteSpace($initialOne)) "initial backup was not created"
    Assert-True ([string]::IsNullOrWhiteSpace($initialTwo)) "initial backup was duplicated"
    $emptyHashFile = Join-Path $sandbox "empty-hash.bin"
    [System.IO.File]::WriteAllBytes($emptyHashFile, [byte[]]@())
    Assert-True ((Get-FileSha256 $emptyHashFile) -eq "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855") "empty content did not hash as the empty SHA-256"
    if ($onWindows) {
        $backupAcl = Get-Acl -LiteralPath $firstVersionedBackup
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

    if ($onWindows) {
        $rejectingCore = Join-Path $sandbox "mihomo-reject.cmd"
        $rejectingCoreText = "@echo off`r`nif `"%1`"==`"-v`" (`r`n  echo Mihomo Meta v1.19.27 windows amd64`r`n  exit /b 0`r`n)`r`nexit /b 17`r`n"
        [System.IO.File]::WriteAllText($rejectingCore, $rejectingCoreText, [System.Text.Encoding]::ASCII)
        $validationFailureCase = Join-Path $sandbox "mihomo-validation-failure-case"
        New-Item -ItemType Directory -Path $validationFailureCase -Force | Out-Null
        $validationConfig = "ipv6: true`ntun: null`n"
        $validationVerge = "enable_tun_mode: false`n"
        $validationProfiles = "items:`n- uid: R-test`n  type: remote`n  option:`n    allow_auto_update: true`n"
        $validationUsage = '{"Version":1,"Profile":1}' + "`r`n"
        [System.IO.File]::WriteAllText((Join-Path $validationFailureCase "config.yaml"), $validationConfig)
        [System.IO.File]::WriteAllText((Join-Path $validationFailureCase "verge.yaml"), $validationVerge)
        [System.IO.File]::WriteAllText((Join-Path $validationFailureCase "profiles.yaml"), $validationProfiles)
        [System.IO.File]::WriteAllText((Join-Path $validationFailureCase "clash-patch-usage-profile.json"), $validationUsage)

        $validationFailure = Invoke-TestPowerShell $installer @(
            "-AppHome", $validationFailureCase, "-UsageProfile", "3", "-MihomoPath", $rejectingCore
        )

        Assert-True ($validationFailure.ExitCode -eq 1) "installer ignored a failed Mihomo candidate validation"
        Assert-True ((Get-Content -LiteralPath (Join-Path $validationFailureCase "config.yaml") -Raw) -eq $validationConfig) "failed Mihomo validation changed config.yaml"
        Assert-True ((Get-Content -LiteralPath (Join-Path $validationFailureCase "verge.yaml") -Raw) -eq $validationVerge) "failed Mihomo validation changed verge.yaml"
        Assert-True ((Get-Content -LiteralPath (Join-Path $validationFailureCase "profiles.yaml") -Raw) -eq $validationProfiles) "failed Mihomo validation changed profiles.yaml"
        Assert-True ((Get-Content -LiteralPath (Join-Path $validationFailureCase "clash-patch-usage-profile.json") -Raw) -eq $validationUsage) "failed Mihomo validation changed the usage profile"
        Assert-True (-not (Test-Path -LiteralPath (Join-Path (Join-Path $validationFailureCase "profiles") "Script.js"))) "failed Mihomo validation created Script.js"
    }

    $nullCase = Join-Path $sandbox "null-case"
    New-Item -ItemType Directory -Path $nullCase -Force | Out-Null
    [System.IO.File]::WriteAllText((Join-Path $nullCase "profiles.yaml"), "items:`n- uid: R-test`n  type: remote`n  option:`n    allow_auto_update: true`n")
    [System.IO.File]::WriteAllText((Join-Path $nullCase "config.yaml"), "ipv6 : true`ntun: null`n")
    [System.IO.File]::WriteAllText((Join-Path $nullCase "verge.yaml"), "enable_tun_mode: false`n")
    Invoke-Installer $nullCase
    $nullOutput = Get-Content -LiteralPath (Join-Path $nullCase "config.yaml") -Raw
    Assert-True ([regex]::Matches($nullOutput, '(?m)^tun\s*:').Count -eq 1) "tun: null produced duplicate tun keys"
    Assert-True ([regex]::Matches($nullOutput, '(?m)^ipv6\s*:').Count -eq 1) "spaced ipv6 produced duplicate ipv6 keys"
    Assert-True ($nullOutput.Contains("dns-hijack:`n") -or $nullOutput.Contains("dns-hijack:`r`n")) "dns-hijack block missing"
    $nullProfilesIndex = Get-Content -LiteralPath (Join-Path $nullCase "profiles.yaml") -Raw
    Assert-True ($nullProfilesIndex -match '(?m)^\s+allow_auto_update:\s+false\s*$') "profile 3 did not disable subscription auto-update"
    $profilesBackups = @(Get-ChildItem -LiteralPath (Join-Path $nullCase "clash-patch-backups") -File | Where-Object { $_.Name -like "*--profiles.yaml.backup" })
    Assert-True ($profilesBackups.Count -ge 1) "profiles.yaml was changed without a dated backup"
    $nullCaseJson = Invoke-TestPowerShell $installer @("-AppHome", $nullCase, "-MihomoPath", $fakeCore, "-Json")
    Assert-JsonResult $nullCaseJson "install" 0 | Out-Null
    if ($onWindows) {
        $mihomoArguments = Get-Content -LiteralPath (Join-Path $sandbox "mihomo-arguments.log") -Raw
        Assert-True ($mihomoArguments -match '(?m)(^| )-t( |$)') "installer never asked Mihomo to test a generated candidate"
        Assert-True ($mihomoArguments -match '(?m)(^| )-f( |$)') "installer never passed the generated candidate to Mihomo"
    }

    if ($onWindows) {
        $runningCase = Join-Path $sandbox "running-client-case"
        $runningProfiles = Join-Path $runningCase "profiles"
        New-Item -ItemType Directory -Path $runningProfiles -Force | Out-Null
        $runningConfig = "ipv6: true`ntun: null`n"
        $runningVerge = "enable_tun_mode: false`n"
        [System.IO.File]::WriteAllText((Join-Path $runningCase "profiles.yaml"), "items:`n- uid: R-test`n  type: remote`n  option:`n    allow_auto_update: true`n")
        [System.IO.File]::WriteAllText((Join-Path $runningProfiles "R-test.yaml"), "proxies: []`n")
        [System.IO.File]::WriteAllText((Join-Path $runningCase "config.yaml"), $runningConfig)
        [System.IO.File]::WriteAllText((Join-Path $runningCase "verge.yaml"), $runningVerge)
        $runningClientPath = Join-Path $sandbox "clash-verge.exe"
        Copy-Item -LiteralPath (Join-Path (Join-Path $env:SystemRoot "System32") "ping.exe") -Destination $runningClientPath
        $runningClient = Start-Process -FilePath $runningClientPath -ArgumentList @("-n", "20", "127.0.0.1") -PassThru
        try {
            Start-Sleep -Milliseconds 100
            $runningResult = Invoke-TestPowerShell $installer @("-AppHome", $runningCase, "-MihomoPath", $fakeCore)
            Assert-True ($runningResult.ExitCode -eq 0) "installer did not use the running-client boundary: $($runningResult.Output)"
            Assert-True (Test-Path -LiteralPath (Join-Path $runningProfiles "Script.js") -PathType Leaf) "running client did not receive the global script"
            Assert-True ((Get-Content -LiteralPath (Join-Path $runningCase "profiles.yaml") -Raw) -match '(?m)^\s+allow_auto_update:\s+false\s*$') "running client did not disable remote auto-update"
            Assert-True ((Get-Content -LiteralPath (Join-Path $runningCase "config.yaml") -Raw) -eq $runningConfig) "running client changed config.yaml"
            Assert-True ((Get-Content -LiteralPath (Join-Path $runningCase "verge.yaml") -Raw) -eq $runningVerge) "running client changed verge.yaml"
            Assert-True (-not (Test-Path -LiteralPath (Join-Path $runningCase "clash-patch-install-state.json"))) "running client created an offline install state"
        } finally {
            if (-not $runningClient.HasExited) { Stop-Process -Id $runningClient.Id -Force }
        }
    }

    $blockCase = Join-Path $sandbox "block-case"
    New-Item -ItemType Directory -Path $blockCase -Force | Out-Null
    [System.IO.File]::WriteAllText((Join-Path $blockCase "profiles.yaml"), "items:`n- uid: R-test`n  type: remote`n  option:`n    allow_auto_update: true`n")
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
    [System.IO.File]::WriteAllText((Join-Path $composeCase "profiles.yaml"), "items:`n- uid: R-test`n  type: remote`n  option:`n    allow_auto_update: true`n")
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
    if ($onWindows) {
        $generatedScriptHarness = Join-Path $sandbox "run-generated-script.js"
        $generatedScriptHarnessSource = @'
const fs = require("node:fs");
const vm = require("node:vm");
const generatedPath = process.argv[2];
const context = {};
vm.createContext(context);
vm.runInContext(fs.readFileSync(generatedPath, "utf8"), context, { filename: generatedPath });
const result = context.main({
  proxies: [{ name: "Node", type: "ss", server: "proxy.invalid", password: "fixture-secret" }],
  "proxy-groups": [{ name: "Main", type: "select", proxies: ["Node"] }],
  dns: { enable: true, nameserver: ["223.5.5.5"], "nameserver-policy": {} },
  rules: ["MATCH,Main"]
});
if (!result || result.friend !== true) throw new Error("previous main did not run");
if (!result["rule-providers"] || !Object.keys(result["rule-providers"]).some((name) => name.indexOf("clash-patch-cn-domain") === 0)) {
  throw new Error("Clash Patch transform did not run");
}
'@
        [System.IO.File]::WriteAllText($generatedScriptHarness, $generatedScriptHarnessSource, (New-Object System.Text.UTF8Encoding($false)))
        $node = Get-Command node.exe -ErrorAction Stop
        $generatedScriptOutput = & $node.Source $generatedScriptHarness $composedPath 2>&1 | Out-String
        Assert-True ($LASTEXITCODE -eq 0) "generated Script.js failed syntax or execution: $generatedScriptOutput"
    }
    Invoke-Uninstaller $composeCase
    $restoredScript = Get-Content -LiteralPath (Join-Path $composeProfiles "Script.js") -Raw
    Assert-True ($restoredScript.Contains($originalScript.Trim())) "uninstaller did not restore the composed script"
    Assert-True ($restoredScript.Contains("const friendAfterPatch = true;")) "uninstaller discarded code after the managed block"
    Assert-True ((Get-Content -LiteralPath (Join-Path $composeCase "config.yaml") -Raw) -eq $composeConfigOriginal) "uninstaller did not restore config.yaml"
    Assert-True ((Get-Content -LiteralPath (Join-Path $composeCase "verge.yaml") -Raw) -eq $composeVergeOriginal) "uninstaller did not restore verge.yaml"

    $asyncCase = Join-Path $sandbox "async-case"
    $asyncProfiles = Join-Path $asyncCase "profiles"
    New-Item -ItemType Directory -Path $asyncProfiles -Force | Out-Null
    [System.IO.File]::WriteAllText((Join-Path $asyncCase "profiles.yaml"), "items:`n- uid: R-test`n  type: remote`n  option:`n    allow_auto_update: true`n")
    $asyncConfig = "ipv6: true`ntun: null`n"
    $asyncVerge = "enable_tun_mode: false`n"
    $asyncScript = "async function main(config) { return config; }`n"
    [System.IO.File]::WriteAllText((Join-Path $asyncCase "config.yaml"), $asyncConfig)
    [System.IO.File]::WriteAllText((Join-Path $asyncCase "verge.yaml"), $asyncVerge)
    $asyncScriptPath = Join-Path $asyncProfiles "Script.js"
    [System.IO.File]::WriteAllText($asyncScriptPath, $asyncScript)
    $asyncUsageStatePath = Join-Path $asyncCase "clash-patch-usage-profile.json"
    $asyncUsageState = '{"Version":1,"Profile":1}' + "`r`n"
    [System.IO.File]::WriteAllText($asyncUsageStatePath, $asyncUsageState)
    $asyncResult = Invoke-TestPowerShell $installer @("-AppHome", $asyncCase, "-UsageProfile", "3", "-MihomoPath", $fakeCore)
    Assert-True ($asyncResult.ExitCode -eq 1) "installer accepted an async main that Clash Verge Rev cannot await"
    Assert-True ($asyncResult.Output.Contains("异步 main")) "async main rejection did not explain the incompatibility"
    Assert-True ((Get-Content -LiteralPath $asyncScriptPath -Raw) -eq $asyncScript) "async main rejection changed Script.js"
    Assert-True ((Get-Content -LiteralPath (Join-Path $asyncCase "config.yaml") -Raw) -eq $asyncConfig) "async main rejection changed config.yaml"
    Assert-True ((Get-Content -LiteralPath (Join-Path $asyncCase "verge.yaml") -Raw) -eq $asyncVerge) "async main rejection changed verge.yaml"
    Assert-True ((Get-Content -LiteralPath $asyncUsageStatePath -Raw) -eq $asyncUsageState) "failed install changed the saved usage profile"

    $templateMarkerCase = Join-Path $sandbox "template-marker-case"
    $templateMarkerProfiles = Join-Path $templateMarkerCase "profiles"
    New-Item -ItemType Directory -Path $templateMarkerProfiles -Force | Out-Null
    [System.IO.File]::WriteAllText((Join-Path $templateMarkerCase "profiles.yaml"), "items:`n- uid: R-test`n  type: remote`n  option:`n    allow_auto_update: true`n")
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
    [System.IO.File]::WriteAllText((Join-Path $invalidStateCase "profiles.yaml"), "items:`n- uid: R-test`n  type: remote`n  option:`n    allow_auto_update: true`n")
    $invalidStateConfig = "ipv6: true`ntun: null`n"
    $invalidStateVerge = "enable_tun_mode: false`n"
    [System.IO.File]::WriteAllText((Join-Path $invalidStateCase "config.yaml"), $invalidStateConfig)
    [System.IO.File]::WriteAllText((Join-Path $invalidStateCase "verge.yaml"), $invalidStateVerge)
    [System.IO.File]::WriteAllText((Join-Path $invalidStateCase "clash-patch-install-state.json"), '{"Version":1}')
    $invalidStateResult = Invoke-TestPowerShell $installer @("-AppHome", $invalidStateCase, "-MihomoPath", $fakeCore)
    Assert-True ($invalidStateResult.ExitCode -eq 1) "installer accepted incomplete state"
    Assert-True ($invalidStateResult.Output.Contains("安装状态文件无效")) "incomplete state rejection was unclear"
    Assert-True ((Get-Content -LiteralPath (Join-Path $invalidStateCase "config.yaml") -Raw) -eq $invalidStateConfig) "invalid state changed config.yaml"
    Assert-True ((Get-Content -LiteralPath (Join-Path $invalidStateCase "verge.yaml") -Raw) -eq $invalidStateVerge) "invalid state changed verge.yaml"

    $badMarkerCase = Join-Path $sandbox "bad-marker-case"
    $badMarkerProfiles = Join-Path $badMarkerCase "profiles"
    New-Item -ItemType Directory -Path $badMarkerProfiles -Force | Out-Null
    $badMarkerPath = Join-Path $badMarkerProfiles "Script.js"
    $badMarkerScript = "// CLASH PATCH BEGIN`nfunction main(config) { return config; }`n// CLASH PATCH END`n// CLASH PATCH END`n"
    [System.IO.File]::WriteAllText($badMarkerPath, $badMarkerScript)
    $badMarkerResult = Invoke-TestPowerShell $uninstaller @("-AppHome", $badMarkerCase)
    Assert-True ($badMarkerResult.ExitCode -eq 1) "uninstaller accepted duplicate end markers"
    Assert-True ((Get-Content -LiteralPath $badMarkerPath -Raw) -eq $badMarkerScript) "uninstaller modified an ambiguously marked script"

    Write-Host "Windows installer behavioral cases passed"
} finally {
    $env:CLASH_PATCH_USAGE_PROFILE = $previousUsageProfile
    if (Test-Path -LiteralPath $sandbox) { Remove-Item -LiteralPath $sandbox -Recurse -Force }
}

exit 0
