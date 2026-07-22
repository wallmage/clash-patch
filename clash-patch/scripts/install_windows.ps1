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
    [string]$ExpectedCurrentSha256 = ""
)

$ErrorActionPreference = "Stop"

function Write-Info([string]$Message) {
    Write-Host "[Clash 补丁] $Message"
}

function ConvertTo-NativeArgument([string]$Value) {
    if ($Value -notmatch '[\s"]') { return $Value }

    $builder = New-Object System.Text.StringBuilder
    [void]$builder.Append('"')
    $slashes = 0
    foreach ($character in $Value.ToCharArray()) {
        if ($character -eq '\') {
            $slashes++
            continue
        }
        if ($character -eq '"') {
            [void]$builder.Append(('\' * (($slashes * 2) + 1)))
            [void]$builder.Append('"')
        } else {
            if ($slashes -gt 0) { [void]$builder.Append(('\' * $slashes)) }
            [void]$builder.Append($character)
        }
        $slashes = 0
    }
    if ($slashes -gt 0) { [void]$builder.Append(('\' * ($slashes * 2))) }
    [void]$builder.Append('"')
    return $builder.ToString()
}

function Invoke-Mihomo(
    [string]$CorePath,
    [string[]]$Arguments,
    [int]$TimeoutSeconds = 30
) {
    $nativeArguments = (($Arguments | ForEach-Object { ConvertTo-NativeArgument $_ }) -join ' ')
    $start = New-Object System.Diagnostics.ProcessStartInfo
    if ([Environment]::OSVersion.Platform -eq [PlatformID]::Win32NT -and $CorePath -match '(?i)\.(?:cmd|bat)$') {
        $start.FileName = $env:ComSpec
        $start.Arguments = '/d /s /c ""' + $CorePath + '" ' + $nativeArguments + '"'
    } else {
        $start.FileName = $CorePath
        $start.Arguments = $nativeArguments
    }
    $start.UseShellExecute = $false
    $start.CreateNoWindow = $true
    $start.RedirectStandardOutput = $true
    $start.RedirectStandardError = $true
    $process = New-Object System.Diagnostics.Process
    $process.StartInfo = $start
    try {
        if (-not $process.Start()) { throw "无法启动 Mihomo 校验进程。" }
        $stdout = $process.StandardOutput.ReadToEndAsync()
        $stderr = $process.StandardError.ReadToEndAsync()
        if (-not $process.WaitForExit($TimeoutSeconds * 1000)) {
            $process.Kill()
            $process.WaitForExit()
            throw "Mihomo 校验超过 $TimeoutSeconds 秒；候选配置无效，原文件保持不变。"
        }
        $process.WaitForExit()
        return [pscustomobject]@{
            ExitCode = $process.ExitCode
            Output = (($stdout.Result, $stderr.Result) -join "`n")
        }
    } finally {
        $process.Dispose()
    }
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

function Split-YamlLines([string]$Text) {
    if ([string]::IsNullOrEmpty($Text)) { return @() }
    return @($Text -split "`r?`n")
}

function Join-YamlLines([string[]]$Lines) {
    if ($Lines.Count -eq 0) { return "" }
    $text = $Lines -join "`r`n"
    if (-not $text.EndsWith("`r`n")) { $text += "`r`n" }
    return $text
}

function Get-YamlIndent([string]$Line) {
    if ($Line -match '^ *\t') { throw "YAML 使用了制表符缩进，无法安全修改。" }
    if ($Line -match '^( *)') { return $Matches[1].Length }
    return 0
}

function Get-YamlMappingEntry([string]$Line) {
    $pattern = '^\s*(?:"([A-Za-z0-9_-]+)"|''([A-Za-z0-9_-]+)''|([A-Za-z0-9_-]+))\s*:\s*(.*)$'
    if ($Line -notmatch $pattern) { return $null }
    $key = @($Matches[1], $Matches[2], $Matches[3]) | Where-Object { -not [string]::IsNullOrEmpty($_) } | Select-Object -First 1
    return [pscustomobject]@{ Key = $key; Value = $Matches[4] }
}

function Get-YamlPathFingerprints([string]$Text) {
    $lines = @(Split-YamlLines $Text)
    $values = @{}
    $stack = New-Object System.Collections.ArrayList

    foreach ($line in $lines) {
        if ([string]::IsNullOrWhiteSpace($line) -or $line.TrimStart().StartsWith("#")) { continue }
        if ($line -match "`t") { throw "YAML 使用了制表符缩进，无法安全比较。" }
        $indent = Get-YamlIndent $line
        while ($stack.Count -gt 0 -and [int]$stack[$stack.Count - 1].Indent -ge $indent) {
            $stack.RemoveAt($stack.Count - 1)
        }
        $trimmed = $line.TrimStart()
        if ($trimmed.StartsWith("- ")) {
            if ($stack.Count -eq 0) { continue }
            $path = [string]$stack[$stack.Count - 1].Path
            $values[$path].Add($trimmed)
            [void]$stack.Add([pscustomobject]@{ Indent = $indent; Path = $path; Sequence = $true })
            continue
        }
        if ($stack.Count -gt 0 -and $stack[$stack.Count - 1].Sequence) {
            $values[[string]$stack[$stack.Count - 1].Path].Add($trimmed)
            continue
        }
        $entry = Get-YamlMappingEntry $trimmed
        if ($null -eq $entry) {
            if ($stack.Count -eq 0) { continue }
            $path = [string]$stack[$stack.Count - 1].Path
            if (-not $values.ContainsKey($path)) { $values[$path] = New-Object System.Collections.Generic.List[string] }
            $values[$path].Add($trimmed)
            continue
        }
        $parent = if ($stack.Count -eq 0) { "" } else { [string]$stack[$stack.Count - 1].Path }
        $path = if ([string]::IsNullOrWhiteSpace($parent)) { [string]$entry.Key } else { "$parent.$($entry.Key)" }
        if ($values.ContainsKey($path)) { throw "YAML 中存在重复键：$path。无法安全比较。" }
        $values[$path] = New-Object System.Collections.Generic.List[string]
        $value = ($entry.Value -replace '\s+#.*$', '').Trim()
        if (-not [string]::IsNullOrWhiteSpace($value)) { $values[$path].Add($value) }
        [void]$stack.Add([pscustomobject]@{ Indent = $indent; Path = $path; Sequence = $false })
    }

    $fingerprints = @{}
    foreach ($path in $values.Keys) {
        $fingerprints[$path] = Get-BytesSha256 (ConvertTo-Utf8Bytes (($values[$path].ToArray()) -join "`n"))
    }
    return $fingerprints
}

function Get-RedactedYamlChangedPaths([string]$Before, [string]$After) {
    if ($Before -ceq $After) { return @() }
    $beforeSections = Get-YamlPathFingerprints $Before
    $afterSections = Get-YamlPathFingerprints $After
    $keys = @($beforeSections.Keys) + @($afterSections.Keys) | Sort-Object -Unique
    $changes = @($keys | Where-Object {
        -not $beforeSections.ContainsKey($_) -or
        -not $afterSections.ContainsKey($_) -or
        $beforeSections[$_] -ne $afterSections[$_]
    })
    if ($changes.Count -eq 0) { return @("无法安全识别的配置区域") }
    return $changes
}

function Find-YamlMappingNode(
    [string[]]$Lines,
    [string]$Key,
    [int]$Indent,
    [int]$SearchStart,
    [int]$SearchEnd
) {
    $foundIndexes = @()
    for ($i = $SearchStart; $i -lt $SearchEnd; $i++) {
        $line = $Lines[$i]
        if ([string]::IsNullOrWhiteSpace($line) -or $line.TrimStart().StartsWith("#")) { continue }
        if ((Get-YamlIndent $line) -ne $Indent) { continue }
        $entry = Get-YamlMappingEntry $line
        if ($null -ne $entry -and $entry.Key -eq $Key) {
            $foundIndexes += $i
        }
    }
    if ($foundIndexes.Count -gt 1) { throw "YAML 中存在重复键：$Key。原文件没有被修改。" }
    if ($foundIndexes.Count -eq 0) { return $null }

    $start = [int]$foundIndexes[0]
    $finish = $SearchEnd
    for ($i = $start + 1; $i -lt $SearchEnd; $i++) {
        $line = $Lines[$i]
        if ([string]::IsNullOrWhiteSpace($line)) { continue }
        $lineIndent = Get-YamlIndent $line
        if ($line.TrimStart().StartsWith("#")) {
            if ($lineIndent -le $Indent) { $finish = $i; break }
            continue
        }
        if ($lineIndent -le $Indent) { $finish = $i; break }
    }
    $entry = Get-YamlMappingEntry $Lines[$start]
    $value = if ($null -ne $entry) { $entry.Value } else { "" }
    return [pscustomobject]@{ Start = $start; End = $finish; Value = $value; Indent = $Indent }
}

function Replace-YamlRange([string[]]$Lines, [int]$Start, [int]$End, [string[]]$Replacement) {
    $before = @(if ($Start -gt 0) { $Lines[0..($Start - 1)] })
    $after = @(if ($End -lt $Lines.Count) { $Lines[$End..($Lines.Count - 1)] })
    return @($before + $Replacement + $after)
}

function Set-YamlTopLevelScalar([string]$Text, [string]$Key, [string]$Value) {
    $lines = @(Split-YamlLines $Text)
    $node = Find-YamlMappingNode $lines $Key 0 0 $lines.Count
    $comment = ""
    if ($null -ne $node) {
        $semanticValue = ($node.Value -replace '\s+#.*$', '').Trim()
        if ($semanticValue -match '(^|\s)[&*][A-Za-z0-9_-]+(?=\s|$)') {
            throw "$Key 使用了 YAML 锚点或别名，无法安全修改。原文件没有被修改。"
        }
        if ($node.Value -match '(\s+#.*)$') { $comment = $Matches[1] }
    }
    $replacement = @("$Key`: $Value$comment")
    if ($null -eq $node) {
        while ($lines.Count -gt 0 -and [string]::IsNullOrWhiteSpace($lines[$lines.Count - 1])) {
            $lines = if ($lines.Count -eq 1) { @() } else { @($lines[0..($lines.Count - 2)]) }
        }
        return (Join-YamlLines -Lines @($lines + $replacement))
    }
    $updated = Replace-YamlRange -Lines $lines -Start $node.Start -End $node.End -Replacement $replacement
    return (Join-YamlLines -Lines $updated)
}

function Get-ManagedTunLines([int]$Indent, [string]$Key) {
    $prefix = " " * $Indent
    switch ($Key) {
        "enable" { return @("${prefix}enable: true") }
        "stack" { return @("${prefix}stack: system") }
        "dns-hijack" { return @("${prefix}dns-hijack:", "${prefix}  - any:53", "${prefix}  - tcp://any:53") }
        "auto-route" { return @("${prefix}auto-route: true") }
        "auto-detect-interface" { return @("${prefix}auto-detect-interface: true") }
        "strict-route" { return @("${prefix}strict-route: true") }
        default { throw "未知的 TUN 设置：$Key" }
    }
}

function New-ManagedTunBlock {
    $lines = @("tun:")
    foreach ($key in @("enable", "stack", "dns-hijack", "auto-route", "auto-detect-interface", "strict-route")) {
        $lines += @(Get-ManagedTunLines 2 $key)
    }
    return $lines
}

function Set-YamlTunMapping([string]$Text) {
    $lines = @(Split-YamlLines $Text)
    $tun = Find-YamlMappingNode $lines "tun" 0 0 $lines.Count
    if ($null -eq $tun) {
        while ($lines.Count -gt 0 -and [string]::IsNullOrWhiteSpace($lines[$lines.Count - 1])) {
            $lines = if ($lines.Count -eq 1) { @() } else { @($lines[0..($lines.Count - 2)]) }
        }
        $replacement = @(New-ManagedTunBlock)
        return (Join-YamlLines -Lines @($lines + $replacement))
    }

    $semanticValue = ($tun.Value -replace '\s+#.*$', '').Trim()
    if ($semanticValue -match '^[&*]') {
        throw "config.yaml 的 tun 节点使用了 YAML 锚点或别名，无法安全合并。原文件没有被修改。"
    }
    if ($semanticValue -match '^\{') {
        throw "config.yaml 使用了行内 tun 写法，无法安全合并。原文件没有被修改。"
    }
    if ($semanticValue -ne "" -and $semanticValue -notmatch '^(?:null|~)$') {
        $replacement = @(New-ManagedTunBlock)
        $updated = Replace-YamlRange -Lines $lines -Start $tun.Start -End $tun.End -Replacement $replacement
        return (Join-YamlLines -Lines $updated)
    }
    if ($semanticValue -match '^(?:null|~)$') {
        $replacement = @(New-ManagedTunBlock)
        $updated = Replace-YamlRange -Lines $lines -Start $tun.Start -End $tun.End -Replacement $replacement
        return (Join-YamlLines -Lines $updated)
    }

    $childIndent = 2
    for ($i = $tun.Start + 1; $i -lt $tun.End; $i++) {
        if ([string]::IsNullOrWhiteSpace($lines[$i]) -or $lines[$i].TrimStart().StartsWith("#")) { continue }
        $childIndent = Get-YamlIndent $lines[$i]
        if ($childIndent -le 0) { throw "tun 节点不是有效的 YAML 映射。原文件没有被修改。" }
        break
    }

    foreach ($key in @("enable", "stack", "dns-hijack", "auto-route", "auto-detect-interface", "strict-route")) {
        $tun = Find-YamlMappingNode $lines "tun" 0 0 $lines.Count
        $child = Find-YamlMappingNode $lines $key $childIndent ($tun.Start + 1) $tun.End
        $replacement = @(Get-ManagedTunLines $childIndent $key)
        if ($null -eq $child) {
            $lines = Replace-YamlRange -Lines $lines -Start $tun.End -End $tun.End -Replacement $replacement
        } else {
            $lines = Replace-YamlRange -Lines $lines -Start $child.Start -End $child.End -Replacement $replacement
        }
    }
    return (Join-YamlLines -Lines $lines)
}

function Test-GeneratedYaml([string]$Text, [string]$Label) {
    $lines = @(Split-YamlLines $Text)
    $topKeys = @{}
    $seenContent = $false
    for ($i = 0; $i -lt $lines.Count; $i++) {
        $line = $lines[$i]
        if ([string]::IsNullOrWhiteSpace($line) -or $line.TrimStart().StartsWith("#")) { continue }
        $trimmed = $line.Trim()
        if ($trimmed -match '^---(?:\s+#.*)?$') {
            if ($seenContent) { throw "$Label 包含多个 YAML 文档，原文件没有被修改。" }
            $seenContent = $true
            continue
        }
        if ($trimmed -match '^\.\.\.(?:\s+#.*)?$') { throw "$Label 包含 YAML 文档结束标记，原文件没有被修改。" }
        $seenContent = $true
        if ((Get-YamlIndent $line) -ne 0) { continue }
        $entry = Get-YamlMappingEntry $line
        if ($null -ne $entry) {
            $key = $entry.Key
            if ($topKeys.ContainsKey($key)) { throw "$Label 生成了重复键：$key。" }
            $topKeys[$key] = $true
        }
    }

    if ($Label -eq "config.yaml") {
        foreach ($key in @("ipv6", "tun")) {
            if (-not $topKeys.ContainsKey($key)) { throw "$Label 缺少设置：$key。" }
        }
        $tun = Find-YamlMappingNode $lines "tun" 0 0 $lines.Count
        foreach ($key in @("enable", "stack", "dns-hijack", "auto-route", "auto-detect-interface", "strict-route")) {
            $found = $false
            for ($i = $tun.Start + 1; $i -lt $tun.End; $i++) {
                if ($lines[$i] -match ('^\s+' + [regex]::Escape($key) + '\s*:')) { $found = $true; break }
            }
            if (-not $found) { throw "$Label 缺少 TUN 设置：$key。" }
        }
    }
    return $true
}

function Get-RemoteSubscriptionProfileItems([string[]]$Lines) {
    for ($i = 0; $i -lt $Lines.Count; $i++) {
        if ($Lines[$i] -match "`t") { throw "profiles.yaml 使用了制表符缩进，无法安全修改。" }
        if ($Lines[$i].Trim() -match '^(?:---|\.\.\.)(?:\s+#.*)?$') {
            throw "profiles.yaml 包含 YAML 文档标记，无法安全修改。"
        }
    }
    $itemsIndexes = @()
    for ($i = 0; $i -lt $Lines.Count; $i++) {
        if ((Get-YamlIndent $Lines[$i]) -ne 0) { continue }
        $entry = Get-YamlMappingEntry $Lines[$i]
        if ($null -ne $entry -and $entry.Key -eq "items") { $itemsIndexes += $i }
    }
    if ($itemsIndexes.Count -eq 0) { throw "profiles.yaml 缺少 items 清单。" }
    if ($itemsIndexes.Count -gt 1) { throw "profiles.yaml 存在重复 items 清单。" }
    $itemsStart = [int]$itemsIndexes[0]
    $itemsEntry = Get-YamlMappingEntry $Lines[$itemsStart]
    $itemsValue = ($itemsEntry.Value -replace '\s+#.*$', '').Trim()
    if ($itemsValue -ne "") { throw "profiles.yaml 的 items 不是受支持的块状清单。" }
    $itemsEnd = $Lines.Count
    for ($i = $itemsStart + 1; $i -lt $Lines.Count; $i++) {
        if ([string]::IsNullOrWhiteSpace($Lines[$i]) -or $Lines[$i].TrimStart().StartsWith("#")) { continue }
        if ((Get-YamlIndent $Lines[$i]) -ne 0 -or $Lines[$i] -match '^\s*-\s+') { continue }
        if ($null -ne (Get-YamlMappingEntry $Lines[$i])) { $itemsEnd = $i; break }
    }

    $candidateStarts = @()
    for ($i = $itemsStart + 1; $i -lt $itemsEnd; $i++) {
        if ($Lines[$i] -match '^( *)-\s+(.+)$') {
            $candidateStarts += [pscustomobject]@{ Index = $i; Indent = $Matches[1].Length; Inline = $Matches[2] }
        }
    }
    if ($candidateStarts.Count -eq 0) { return @() }
    $itemIndent = ($candidateStarts | Measure-Object -Property Indent -Minimum).Minimum
    $starts = @($candidateStarts | Where-Object { $_.Indent -eq $itemIndent })
    $items = @()
    for ($position = 0; $position -lt $starts.Count; $position++) {
        $start = $starts[$position]
        $finish = if ($position + 1 -lt $starts.Count) { $starts[$position + 1].Index } else { $itemsEnd }
        $fieldIndent = $start.Indent + 2
        $fieldValues = @{}
        $inlineEntry = Get-YamlMappingEntry $start.Inline
        if ($null -ne $inlineEntry) { $fieldValues[[string]$inlineEntry.Key] = @([string]$inlineEntry.Value) }
        $optionIndexes = @()
        for ($i = $start.Index + 1; $i -lt $finish; $i++) {
            if ([string]::IsNullOrWhiteSpace($Lines[$i]) -or $Lines[$i].TrimStart().StartsWith("#")) { continue }
            if ((Get-YamlIndent $Lines[$i]) -ne $fieldIndent) { continue }
            $entry = Get-YamlMappingEntry $Lines[$i]
            if ($null -eq $entry) { continue }
            if (-not $fieldValues.ContainsKey([string]$entry.Key)) { $fieldValues[[string]$entry.Key] = @() }
            $fieldValues[[string]$entry.Key] += [string]$entry.Value
            if ($entry.Key -eq "option") { $optionIndexes += $i }
        }
        $typeValues = @($fieldValues["type"])
        if ($typeValues.Count -ne 1) { throw "profiles.yaml 的订阅项目缺少唯一 type。" }
        if ($optionIndexes.Count -gt 1) { throw "profiles.yaml 的订阅项目存在重复 option。" }
        $typeValue = (($typeValues[0] -replace '\s+#.*$', '').Trim()).Trim("'`"")
        $uidValues = @($fieldValues["uid"])
        $nameValues = @($fieldValues["name"])
        $uidValue = if ($uidValues.Count -eq 1) { (($uidValues[0] -replace '\s+#.*$', '').Trim()).Trim("'`"") } else { "" }
        $nameValue = if ($nameValues.Count -eq 1) { (($nameValues[0] -replace '\s+#.*$', '').Trim()).Trim("'`"") } else { "" }
        if ($typeValue -eq "remote" -and ($uidValues.Count -ne 1 -or $uidValue -notmatch '^[A-Za-z0-9._-]+$')) {
            throw "profiles.yaml 的远程订阅缺少安全且唯一的 uid。"
        }
        $items += [pscustomobject]@{
            Start = $start.Index
            End = $finish
            ItemIndent = $start.Indent
            FieldIndent = $fieldIndent
            Type = $typeValue
            Uid = $uidValue
            Name = $nameValue
            OptionIndex = $(if ($optionIndexes.Count -eq 1) { [int]$optionIndexes[0] } else { -1 })
        }
    }
    return @($items)
}

function Get-RemoteSubscriptionTargets([string]$ProfilesIndexText, [string]$Directory) {
    if (-not (Test-Path -LiteralPath $Directory -PathType Container)) { throw "找不到订阅目录。" }
    $items = @(Get-RemoteSubscriptionProfileItems @(Split-YamlLines $ProfilesIndexText) | Where-Object { $_.Type -eq "remote" })
    if ($items.Count -eq 0) { throw "没有可更新的远程订阅。" }
    $targets = @()
    $targetPaths = New-Object 'System.Collections.Generic.HashSet[string]' ([System.StringComparer]::OrdinalIgnoreCase)
    foreach ($item in $items) {
        $matches = @(
            (Join-Path $Directory ($item.Uid + ".yaml")),
            (Join-Path $Directory ($item.Uid + ".yml"))
        ) | Where-Object { Test-Path -LiteralPath $_ -PathType Leaf }
        if ($matches.Count -ne 1) { throw "远程订阅无法对应到唯一配置文件：$($item.Uid)。" }
        $path = (Resolve-Path -LiteralPath $matches[0]).Path
        if (-not $targetPaths.Add($path)) { throw "多个远程订阅对应到同一配置文件。" }
        $targets += [pscustomobject]@{ Uid = $item.Uid; Name = $item.Name; Path = $path }
    }
    return @($targets)
}

function Set-RemoteSubscriptionAutoUpdateDisabled([string]$Text) {
    $lines = @(Split-YamlLines $Text)
    $items = @(Get-RemoteSubscriptionProfileItems $lines)
    for ($position = $items.Count - 1; $position -ge 0; $position--) {
        $item = $items[$position]
        if ($item.Type -ne "remote") { continue }
        $fieldPrefix = " " * $item.FieldIndent
        if ($item.OptionIndex -lt 0) {
            $lines = Replace-YamlRange -Lines $lines -Start $item.End -End $item.End -Replacement @(
                "${fieldPrefix}option:",
                "${fieldPrefix}  allow_auto_update: false"
            )
            continue
        }

        $optionEntry = Get-YamlMappingEntry $lines[$item.OptionIndex]
        $optionValue = ($optionEntry.Value -replace '\s+#.*$', '').Trim()
        if ($optionValue -match '^[&*]' -or ($optionValue -match '^\{' -and $optionValue -ne '{}')) {
            throw "profiles.yaml 的 option 使用了无法安全修改的写法。"
        }
        if ($optionValue -match '^(?:null|~|\{\})$') {
            $lines = Replace-YamlRange -Lines $lines -Start $item.OptionIndex -End ($item.OptionIndex + 1) -Replacement @(
                "${fieldPrefix}option:",
                "${fieldPrefix}  allow_auto_update: false"
            )
            continue
        }
        if ($optionValue -ne "") { throw "profiles.yaml 的 option 不是受支持的块状映射。" }

        $optionEnd = $item.End
        for ($i = $item.OptionIndex + 1; $i -lt $item.End; $i++) {
            if ([string]::IsNullOrWhiteSpace($lines[$i])) { continue }
            $indent = Get-YamlIndent $lines[$i]
            if (-not $lines[$i].TrimStart().StartsWith("#") -and $indent -le $item.FieldIndent) {
                $optionEnd = $i
                break
            }
        }
        $childIndent = $item.FieldIndent + 2
        $allowIndexes = @()
        for ($i = $item.OptionIndex + 1; $i -lt $optionEnd; $i++) {
            if ([string]::IsNullOrWhiteSpace($lines[$i]) -or $lines[$i].TrimStart().StartsWith("#")) { continue }
            $indent = Get-YamlIndent $lines[$i]
            if ($indent -le $item.FieldIndent) { continue }
            $entry = Get-YamlMappingEntry $lines[$i]
            if ($null -ne $entry -and $entry.Key -eq "allow_auto_update") { $allowIndexes += $i }
            if ($childIndent -eq $item.FieldIndent + 2) { $childIndent = $indent }
        }
        if ($allowIndexes.Count -gt 1) { throw "profiles.yaml 的 option 存在重复 allow_auto_update。" }
        $childPrefix = " " * $childIndent
        if ($allowIndexes.Count -eq 0) {
            $lines = Replace-YamlRange -Lines $lines -Start $optionEnd -End $optionEnd -Replacement @("${childPrefix}allow_auto_update: false")
        } else {
            $allowIndex = [int]$allowIndexes[0]
            $allowEntry = Get-YamlMappingEntry $lines[$allowIndex]
            $allowValue = ($allowEntry.Value -replace '\s+#.*$', '').Trim()
            if ($allowValue -match '(^|\s)[&*][A-Za-z0-9_-]+(?=\s|$)') {
                throw "profiles.yaml 的 allow_auto_update 使用了 YAML 锚点或别名。"
            }
            $comment = if ($allowEntry.Value -match '(\s+#.*)$') { $Matches[1] } else { "" }
            $lines[$allowIndex] = "${childPrefix}allow_auto_update: false$comment"
        }
    }
    $output = Join-YamlLines -Lines $lines
    Assert-RemoteSubscriptionAutoUpdateDisabled $output | Out-Null
    return $output
}

function Assert-RemoteSubscriptionAutoUpdateDisabled([string]$Text) {
    $lines = @(Split-YamlLines $Text)
    $items = @(Get-RemoteSubscriptionProfileItems $lines)
    foreach ($item in $items) {
        if ($item.Type -ne "remote") { continue }
        if ($item.OptionIndex -lt 0) { throw "远程订阅仍允许自动更新。" }
        $found = 0
        for ($i = $item.OptionIndex + 1; $i -lt $item.End; $i++) {
            if ([string]::IsNullOrWhiteSpace($lines[$i]) -or $lines[$i].TrimStart().StartsWith("#")) { continue }
            $indent = Get-YamlIndent $lines[$i]
            if ($indent -le $item.FieldIndent) { break }
            $entry = Get-YamlMappingEntry $lines[$i]
            if ($null -ne $entry -and $entry.Key -eq "allow_auto_update") {
                $value = ($entry.Value -replace '\s+#.*$', '').Trim()
                if ($value -ne "false") { throw "远程订阅仍允许自动更新。" }
                $found++
            }
        }
        if ($found -ne 1) { throw "无法确认远程订阅已经关闭自动更新。" }
    }
    return $true
}

function Test-ClashVergeRunning {
    $names = @("clash-verge", "clash-verge-rev", "Clash Verge", "Clash Verge Rev")
    foreach ($name in $names) {
        if ($null -ne (Get-Process -Name $name -ErrorAction SilentlyContinue | Select-Object -First 1)) { return $true }
    }
    return $false
}

function Test-MihomoVersionText([string]$Text) {
    $match = [regex]::Match($Text, '(?i)\bv?(\d+)\.(\d+)\.(\d+)\b')
    if (-not $match.Success) { return $false }
    $actual = [version]("{0}.{1}.{2}" -f $match.Groups[1].Value, $match.Groups[2].Value, $match.Groups[3].Value)
    $minimum = [version]"1.19.27"
    return $actual.CompareTo($minimum) -ge 0
}

function Test-MihomoVersion([string]$CorePath) {
    if ([string]::IsNullOrWhiteSpace($CorePath) -or -not (Test-Path -LiteralPath $CorePath -PathType Leaf)) {
        throw "没有找到可用的 Mihomo 内核。请更新 Clash Verge Rev，或用 -MihomoPath 指定可信的内核路径。"
    }
    $result = Invoke-Mihomo $CorePath @("-v")
    if ($result.ExitCode -ne 0 -or -not (Test-MihomoVersionText $result.Output)) {
        throw "需要 Mihomo 1.19.27 或更高版本，当前内核版本无法确认或过旧。"
    }
    return $true
}

function Find-MihomoCore([string]$RequestedPath) {
    if (-not [string]::IsNullOrWhiteSpace($RequestedPath)) {
        if (-not (Test-Path -LiteralPath $RequestedPath -PathType Leaf)) {
            throw "指定的 Mihomo 内核不存在：$RequestedPath"
        }
        return (Resolve-Path -LiteralPath $RequestedPath).Path
    }

    $installCandidates = @()
    if (-not [string]::IsNullOrWhiteSpace($env:LOCALAPPDATA)) {
        $installCandidates += (Join-Path (Join-Path $env:LOCALAPPDATA "Clash Verge") "verge-mihomo.exe")
        $installCandidates += (Join-Path (Join-Path $env:LOCALAPPDATA "Clash Verge") "verge-mihomo-alpha.exe")
    }
    if (-not [string]::IsNullOrWhiteSpace($env:ProgramFiles)) {
        $installCandidates += (Join-Path (Join-Path $env:ProgramFiles "Clash Verge") "verge-mihomo.exe")
        $installCandidates += (Join-Path (Join-Path $env:ProgramFiles "Clash Verge") "verge-mihomo-alpha.exe")
        $installCandidates += (Join-Path (Join-Path $env:ProgramFiles "Clash Verge Rev") "verge-mihomo.exe")
    }
    $programFilesX86 = [Environment]::GetEnvironmentVariable("ProgramFiles(x86)")
    if (-not [string]::IsNullOrWhiteSpace($programFilesX86)) {
        $installCandidates += (Join-Path (Join-Path $programFilesX86 "Clash Verge") "verge-mihomo.exe")
        $installCandidates += (Join-Path (Join-Path $programFilesX86 "Clash Verge") "verge-mihomo-alpha.exe")
        $installCandidates += (Join-Path (Join-Path $programFilesX86 "Clash Verge Rev") "verge-mihomo.exe")
    }
    foreach ($candidate in $installCandidates) {
        if (Test-Path -LiteralPath $candidate -PathType Leaf) { return $candidate }
    }
    return $null
}

function Test-MihomoCandidate([string]$CorePath, [string]$Text, [string]$Directory) {
    Test-MihomoVersion $CorePath | Out-Null
    $temporary = Join-Path $Directory (".clash-patch-validate-" + [System.IO.Path]::GetRandomFileName() + ".yaml")
    try {
        [System.IO.File]::WriteAllText($temporary, $Text, (New-Object System.Text.UTF8Encoding($false)))
        $result = Invoke-Mihomo $CorePath @("-d", $Directory, "-t", "-f", $temporary)
        if ($result.ExitCode -ne 0) { throw "Mihomo 拒绝了生成的 config.yaml。原文件没有被修改。" }
    } finally {
        if (Test-Path -LiteralPath $temporary) { Remove-Item -LiteralPath $temporary -Force }
    }
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
                if ($finish + 1 -ge $Text.Length) { throw "JavaScript 块注释没有结束，原脚本没有被修改。" }
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
            throw "JavaScript 字符串没有结束，原脚本没有被修改。"
        }
        [void]$mask.Append($(if ($character -eq "`r" -or $character -eq "`n") { $character } else { " " }))
        $index++
    }
    if ($state -ne "code") { throw "JavaScript 字符串没有结束，原脚本没有被修改。" }
    return [pscustomobject]@{ Code = $mask.ToString(); Markers = @($markers) }
}

function Rename-JavaScriptMain([string]$Text, [string]$From, [string]$To) {
    $analysis = Get-JavaScriptAnalysis $Text
    $pattern = '(?m)^\s*function\s+' + [regex]::Escape($From) + '\s*\('
    $matches = [regex]::Matches($analysis.Code, $pattern)
    if ($matches.Count -ne 1) { throw "无法确认原始 main 函数，原脚本没有被修改。" }
    $relative = $matches[0].Value.IndexOf($From, [StringComparison]::Ordinal)
    $nameIndex = $matches[0].Index + $relative
    return $Text.Substring(0, $nameIndex) + $To + $Text.Substring($nameIndex + $From.Length)
}

function Assert-JavaScriptReservedIdentifiers([string]$Text) {
    $analysis = Get-JavaScriptAnalysis $Text
    if ([regex]::IsMatch($analysis.Code, '\b(?:clashPatch[A-Za-z0-9_$]*|CLASH_PATCH_[A-Za-z0-9_$]*)\b')) {
        throw "现有脚本使用了 Clash 补丁保留标识符，无法安全合并。原脚本没有被修改。"
    }
}

function Assert-JavaScriptCanCompose([string]$Text) {
    $analysis = Get-JavaScriptAnalysis $Text
    if ([regex]::IsMatch($analysis.Code, '(?m)^\s*async\s+function\s+main\s*\(')) {
        throw "检测到异步 main。Clash Verge Rev 不会等待异步 main 的结果，原脚本没有被修改。"
    }
    $matches = [regex]::Matches($analysis.Code, '(?m)^\s*function\s+main\s*\(')
    if ($matches.Count -ne 1) {
        throw "检测到已有全局扩展脚本，但无法安全合并。原脚本没有被修改，请把提示和 Script.js 截图发回来。"
    }
    Assert-JavaScriptReservedIdentifiers $Text
    $withoutDeclaration = $analysis.Code.Substring(0, $matches[0].Index) + (" " * $matches[0].Length) +
        $analysis.Code.Substring($matches[0].Index + $matches[0].Length)
    if ([regex]::IsMatch($withoutDeclaration, '(?<![A-Za-z0-9_$.])main\s*\(')) {
        throw "现有 main 会递归调用自身，重命名后会误调用 Clash 补丁 main。原脚本没有被修改。"
    }
}

function Build-GlobalScript([string]$EnginePath, [string]$TargetPath) {
    $engine = Get-Content -LiteralPath $EnginePath -Raw -Encoding UTF8
    $begin = "// CLASH PATCH BEGIN"
    $end = "// CLASH PATCH END"
    $prefix = ""
    $suffix = ""

    if (Test-Path -LiteralPath $TargetPath -PathType Leaf) {
        $current = Get-Content -LiteralPath $TargetPath -Raw -Encoding UTF8
        $analysis = Get-JavaScriptAnalysis $current
        $beginMarkers = @($analysis.Markers | Where-Object { $_.Kind -eq "begin" })
        $endMarkers = @($analysis.Markers | Where-Object { $_.Kind -eq "end" })
        if ($beginMarkers.Count -gt 0 -or $endMarkers.Count -gt 0) {
            if ($beginMarkers.Count -ne 1 -or $endMarkers.Count -ne 1 -or $endMarkers[0].Start -lt $beginMarkers[0].Start) {
                throw "检测到不完整或重复的 Clash 补丁标记。原脚本没有被修改。"
            }
            $managedBlock = $current.Substring($beginMarkers[0].Start, $endMarkers[0].End - $beginMarkers[0].Start)
            if (-not $managedBlock.Contains("CLASH PATCH POLICY BEGIN") -or -not $managedBlock.Contains("function clashPatchTransform")) {
                throw "检测到非本工具创建的同名标记。原脚本没有被修改。"
            }
            $prefix = $current.Substring(0, $beginMarkers[0].Start).TrimEnd()
            $suffix = $current.Substring($endMarkers[0].End).Trim()
            if (-not [string]::IsNullOrWhiteSpace($prefix)) {
                $restoredPrefix = Rename-JavaScriptMain $prefix "clashPatchPreviousMain" "main"
                Assert-JavaScriptCanCompose $restoredPrefix
                $prefix = Rename-JavaScriptMain $restoredPrefix "main" "clashPatchPreviousMain"
            }
            if (-not [string]::IsNullOrWhiteSpace($suffix)) { Assert-JavaScriptReservedIdentifiers $suffix }
        } elseif (-not [string]::IsNullOrWhiteSpace($current)) {
            Assert-JavaScriptCanCompose $current
            $prefix = (Rename-JavaScriptMain $current "main" "clashPatchPreviousMain").TrimEnd()
        }
    }

    $parts = @()
    if (-not [string]::IsNullOrWhiteSpace($prefix)) { $parts += $prefix }
    $parts += $begin
    $parts += $engine.Trim()
    $parts += $end
    if (-not [string]::IsNullOrWhiteSpace($suffix)) { $parts += $suffix }
    return ($parts -join "`r`n") + "`r`n"
}

if ([string]::IsNullOrWhiteSpace($AppHome)) {
    $candidates = @(
        (Join-Path $env:APPDATA "io.github.clash-verge-rev.clash-verge-rev"),
        (Join-Path $env:LOCALAPPDATA "io.github.clash-verge-rev.clash-verge-rev")
    )
    $AppHome = $candidates | Where-Object { Test-Path -LiteralPath $_ -PathType Container } | Select-Object -First 1
}

if ([string]::IsNullOrWhiteSpace($AppHome) -or -not (Test-Path -LiteralPath $AppHome -PathType Container)) {
    [Console]::Error.WriteLine("[Clash 补丁] 没有找到受支持的 Clash Verge Rev。请安装最新版 Clash Verge Rev，打开一次后再运行 Clash 补丁。")
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
    exit 0
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
    exit 0
}

if ($ListBackups) {
    if (Test-Path -LiteralPath $backupRoot -PathType Container) {
        Get-ChildItem -LiteralPath $backupRoot -File -Filter "*.backup" | Sort-Object Name -Descending | ForEach-Object { $_.Name }
    }
    exit 0
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
    [pscustomobject]@{
        Backup = $CompareBackup
        Profile = (Split-Path -Leaf $resolved.TargetPath)
        Same = $same
        BackupSha256 = $backupHash
        CurrentSha256 = $currentHash
        ChangedFields = $changedFields
        ConfigurationDifference = $(if ($same) { "无配置差异" } else { "存在配置差异；为保护隐私只输出发生变化的字段名" })
    } | ConvertTo-Json
    exit 0
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
    exit 0
}
$enginePath = Join-Path (Join-Path $PSScriptRoot "windows") "clash_verge_global.js"

try {
    $savedUsageProfile = Get-SavedUsageProfile $usageStatePath
} catch {
    [Console]::Error.WriteLine("[Clash 补丁] $($_.Exception.Message)")
    exit 1
}

if ($ShowUsageProfile) {
    if ($savedUsageProfile -eq 0) { Write-Output "unset" } else { Write-Output $savedUsageProfile }
    exit 0
}

$profileSource = "saved"
$resolvedUsageProfile = $UsageProfile
if ($resolvedUsageProfile -eq 0 -and -not [string]::IsNullOrWhiteSpace($env:CLASH_PATCH_USAGE_PROFILE)) {
    $parsedUsageProfile = 0
    if (-not [int]::TryParse($env:CLASH_PATCH_USAGE_PROFILE, [ref]$parsedUsageProfile)) {
        [Console]::Error.WriteLine("[Clash 补丁] 用途档位无效，只能是 1、2 或 3。")
        exit 64
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
    [Console]::Error.WriteLine("[Clash 补丁] 还没有选择用途档位。请先在 skill 中选择：1 普通浏览、2 海外 AI、3 Claude/Claude Code。")
    exit 10
}
if ($resolvedUsageProfile -notin @(1, 2, 3)) {
    [Console]::Error.WriteLine("[Clash 补丁] 用途档位无效，只能是 1、2 或 3。")
    exit 64
}
if ($profileSource -ne "saved" -and $resolvedUsageProfile -ne 3) {
    try {
        Save-UsageProfile $usageStatePath $resolvedUsageProfile
        Write-Info "已保存用途档位 $resolvedUsageProfile。"
    } catch {
        [Console]::Error.WriteLine("[Clash 补丁] 无法保存用途档位：$($_.Exception.Message)")
        exit 1
    }
}

if ($resolvedUsageProfile -ne 3) {
    if ($savedUsageProfile -eq 3 -and $profileSource -ne "saved") {
        Write-Info "检测到从档位 3 改为轻量档位。安装程序不会覆盖后来产生的用户改动；请由本 skill 先运行安全卸载流程，并说明无法自动恢复的旧增强。"
    }
    if ($resolvedUsageProfile -eq 1) {
        Write-Info "档位 1 只需要确认 Clash Verge Rev 的“设置为系统代理”已开启；未修改 TUN 或订阅。"
    } else {
        Write-Info "档位 2 只需要开启 TUN 并关闭 Clash Verge Rev 自己的系统代理开关；未修改订阅、DNS、WebRTC 或 AI 分组。"
    }
    Write-Info "请由本 skill 使用 Computer Use 完成客户端开关和对应网站复测。"
    exit 0
}

if (-not (Test-Path -LiteralPath $enginePath -PathType Leaf)) {
    [Console]::Error.WriteLine("[Clash 补丁] 安装包不完整：缺少 Windows 全局扩展脚本。")
    exit 3
}

try {
    $clientRunning = Test-ClashVergeRunning
    $corePath = Find-MihomoCore $MihomoPath
    Test-MihomoVersion $corePath | Out-Null
    if ($profileSource -ne "saved") {
        Save-UsageProfile $usageStatePath $resolvedUsageProfile
        Write-Info "已保存用途档位 $resolvedUsageProfile。"
    }
    if (-not (Test-Path -LiteralPath $profilesIndexPath -PathType Leaf)) {
        throw "找不到 Clash Verge Rev 的 profiles.yaml，无法自动关闭订阅更新。"
    }
    $profilesIndexInput = Get-Content -LiteralPath $profilesIndexPath -Raw -Encoding UTF8
    $profilesIndexOutput = Set-RemoteSubscriptionAutoUpdateDisabled $profilesIndexInput
    Assert-RemoteSubscriptionAutoUpdateDisabled $profilesIndexOutput
    $profilesIndexBytes = ConvertTo-Utf8Bytes $profilesIndexOutput

    if ($clientRunning) {
        New-Item -ItemType Directory -Path $profilesDirectory -Force | Out-Null
        $scriptOutput = Build-GlobalScript $enginePath $targetScript
        $scriptBytes = ConvertTo-Utf8Bytes $scriptOutput
        $runningTargets = @(
            [pscustomobject]@{ Path = $targetScript; Bytes = $scriptBytes; Existed = (Test-Path -LiteralPath $targetScript); OriginalBytes = $(if (Test-Path -LiteralPath $targetScript) { [System.IO.File]::ReadAllBytes($targetScript) } else { $null }) },
            [pscustomobject]@{ Path = $profilesIndexPath; Bytes = $profilesIndexBytes; Existed = $true; OriginalBytes = [System.IO.File]::ReadAllBytes($profilesIndexPath) }
        )
        foreach ($target in $runningTargets) {
            Backup-InitialOnce $target.Path $backupRoot | Out-Null
            Backup-Versioned $target.Path $backupRoot "prewrite" | Out-Null
        }
        try {
            foreach ($target in $runningTargets) { Write-BytesAtomic $target.Path $target.Bytes }
            Assert-RemoteSubscriptionAutoUpdateDisabled (Get-Content -LiteralPath $profilesIndexPath -Raw -Encoding UTF8)
        } catch {
            Restore-Transaction $runningTargets
            throw
        }
        Write-Info "Clash Verge Rev 保持运行；已更新全局扩展脚本，并自动关闭全部远程订阅的自动更新。"
        Write-Info "config.yaml、verge.yaml 和当前运行配置均未修改。下次订阅刷新时应用补丁。"
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
    $scriptOutput = Build-GlobalScript $enginePath $targetScript
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
    foreach ($target in $targets) {
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

    Write-Info "已安装全局扩展脚本，之后每次加载或刷新订阅都会自动应用补丁。"
    Write-Info "已自动关闭全部远程订阅的自动更新，并回读确认 profiles.yaml。"
    Write-Info "已开启 TUN，并让全局脚本接管 DNS 配置。下次订阅刷新时应用补丁。"
    Write-Info "安装程序从未退出、停止或重启 Clash Verge Rev。"
    Write-Info "已有 AI 分组只补全规则；没有时创建包含全部可用节点和代理提供者的独立选择器。安装程序不会替你选择节点。"
    exit 0
} catch {
    [Console]::Error.WriteLine("[Clash 补丁] 安装失败：$($_.Exception.Message)")
    exit 1
}
