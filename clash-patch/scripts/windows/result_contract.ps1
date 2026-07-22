$script:ClashPatchResultSchema = "clash-patch.result"
$script:ClashPatchResultVersion = 1
$script:ClashPatchResultCommands = @("install", "uninstall", "patch", "verify_routes")

function Protect-ClashPatchResultText([object]$Value) {
    if ($null -eq $Value) { return $null }
    $text = [string]$Value
    $text = [regex]::Replace($text, '(?i)\b(?:https?|socks5?)://\S+', '[已隐藏地址]')
    $text = [regex]::Replace($text, '(?i)\bBearer\s+\S+', 'Bearer [已隐藏]')
    $text = [regex]::Replace($text, '(?i)\b(password|passwd|secret|token|uuid|private[-_ ]?key|controller[-_ ]?key)\s*[:=]\s*\S+', '$1=[已隐藏]')
    $text = [regex]::Replace($text, '(?i)\b[0-9a-f]{8}(?:-[0-9a-f]{4}){3}-[0-9a-f]{12}\b', '[已隐藏]')
    $text = [regex]::Replace($text, '(?i)(?:[A-Z]:\\|\\\\)[^\r\n；，。]+', '[已隐藏路径]')
    $text = [regex]::Replace($text, '(?<![A-Za-z0-9])/(?:Users|home|private|tmp|var|etc)/[^\r\n；，。]+', '[已隐藏路径]')
    return $text
}

function ConvertTo-ClashPatchResultArray([object[]]$Values) {
    $result = @()
    foreach ($value in @($Values)) {
        if ($null -eq $value) { continue }
        $result += (Protect-ClashPatchResultValue $value)
    }
    return @($result)
}

function Protect-ClashPatchResultValue([object]$Value) {
    if ($null -eq $Value) { return $null }
    if ($Value -is [string]) { return (Protect-ClashPatchResultText $Value) }
    if ($Value -is [System.Collections.IDictionary]) {
        $result = [ordered]@{}
        foreach ($key in $Value.Keys) {
            $result[(Protect-ClashPatchResultText $key)] = Protect-ClashPatchResultValue $Value[$key]
        }
        return $result
    }
    if ($Value -is [System.Management.Automation.PSCustomObject]) {
        $result = [ordered]@{}
        foreach ($property in $Value.PSObject.Properties) {
            $result[(Protect-ClashPatchResultText $property.Name)] = Protect-ClashPatchResultValue $property.Value
        }
        return $result
    }
    if ($Value -is [System.Collections.IEnumerable]) {
        $result = @()
        foreach ($entry in $Value) { $result += (Protect-ClashPatchResultValue $entry) }
        return @($result)
    }
    return $Value
}

function New-ClashPatchResult(
    [Parameter(Mandatory = $true)][string]$Command,
    [Parameter(Mandatory = $true)][string]$Operation,
    [Parameter(Mandatory = $true)][bool]$Ok,
    [Parameter(Mandatory = $true)][string]$Status,
    [Parameter(Mandatory = $true)][string]$Code,
    [Parameter(Mandatory = $true)][int]$ExitCode,
    [Parameter(Mandatory = $true)][string]$SummaryZh,
    [object]$Profile = $null,
    [object[]]$Changes = @(),
    [object[]]$Checks = @(),
    [object[]]$Items = @(),
    [object[]]$Messages = @(),
    [object[]]$Warnings = @()
) {
    if ($Command -notin $script:ClashPatchResultCommands) { throw "结果命令无效。" }
    if ($Status -notin @("ok", "no_change", "skipped", "failed", "rolled_back", "partial", "invalid_request", "unsupported")) { throw "结果状态无效。" }
    return [pscustomobject][ordered]@{
        schema = $script:ClashPatchResultSchema
        version = $script:ClashPatchResultVersion
        command = $Command
        platform = "windows"
        client = "clash-verge-rev"
        operation = $Operation
        ok = $Ok
        status = $Status
        code = $Code
        exit_code = $ExitCode
        summary_zh = (Protect-ClashPatchResultText $SummaryZh)
        profile = $Profile
        changes = @(ConvertTo-ClashPatchResultArray $Changes)
        checks = @(ConvertTo-ClashPatchResultArray $Checks)
        items = @(ConvertTo-ClashPatchResultArray $Items)
        messages = @(ConvertTo-ClashPatchResultArray $Messages)
        warnings = @(ConvertTo-ClashPatchResultArray $Warnings)
    }
}

function Write-ClashPatchResult([object]$Result) {
    [Console]::OutputEncoding = New-Object System.Text.UTF8Encoding($false)
    [Console]::Out.WriteLine(($Result | ConvertTo-Json -Depth 8 -Compress))
}
