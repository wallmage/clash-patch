function Write-Info([string]$Message) {
    if ($Json) {
        [void]$script:ClashPatchMessages.Add((Protect-ClashPatchResultText $Message))
        return
    }
    Write-Host "[Clash 补丁] $Message"
}

function Complete-InstallResult(
    [int]$ExitCode,
    [string]$Status,
    [string]$Code,
    [string]$SummaryZh,
    [object[]]$Changes = @(),
    [object[]]$Checks = @(),
    [object[]]$Items = @(),
    [object[]]$Warnings = @()
) {
    if ($Json) {
        $result = New-ClashPatchResult -Command "install" -Operation $script:ClashPatchOperation -Ok ($ExitCode -eq 0) -Status $Status -Code $Code -ExitCode $ExitCode -SummaryZh $SummaryZh -Profile $script:ClashPatchProfile -Changes $Changes -Checks $Checks -Items $Items -Messages @($script:ClashPatchMessages) -Warnings $Warnings
        Write-ClashPatchResult $result
    }
    exit $ExitCode
}

function Get-SavedUsageProfile([string]$Path) {
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { return 0 }
    try {
        $state = Get-Content -LiteralPath $Path -Raw -Encoding UTF8 | ConvertFrom-Json
    } catch {
        throw "用途档位文件无效，无法确认之前的选择。"
    }
    $version = $state.Version
    $profile = $state.Profile
    $numericVersion = $version -is [int] -or $version -is [long]
    $numericProfile = $profile -is [int] -or $profile -is [long]
    if (-not $numericVersion -or [long]$version -ne 1 -or -not $numericProfile -or [long]$profile -notin @(1, 2, 3)) {
        throw "用途档位文件无效，无法确认之前的选择。"
    }
    return [int]$profile
}

function Save-UsageProfile([string]$Path, [int]$Profile) {
    $state = [ordered]@{ Version = 1; Profile = $Profile }
    Write-Utf8Atomic $Path (($state | ConvertTo-Json -Compress) + "`r`n")
}
