param(
    [string]$AppHome = "",
    [string]$MihomoPath = ""
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

function Backup-Once([string]$Path) {
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { return }
    $destination = "$Path.clash-patch.original.backup"
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
        } elseif (-not $created -and (Test-Path -LiteralPath $destination -PathType Leaf)) {
            Protect-BackupAcl $destination
            return
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
$vergePath = Join-Path $AppHome "verge.yaml"
$configPath = Join-Path $AppHome "config.yaml"
$statePath = Join-Path $AppHome "clash-patch-install-state.json"
$targetScript = Join-Path $profilesDirectory "Script.js"
$enginePath = Join-Path (Join-Path $PSScriptRoot "windows") "clash_verge_global.js"

if (-not (Test-Path -LiteralPath $enginePath -PathType Leaf)) {
    [Console]::Error.WriteLine("[Clash 补丁] 安装包不完整：缺少 Windows 全局扩展脚本。")
    exit 3
}

try {
    $clientRunning = Test-ClashVergeRunning
    $corePath = Find-MihomoCore $MihomoPath
    Test-MihomoVersion $corePath | Out-Null

    if ($clientRunning) {
        New-Item -ItemType Directory -Path $profilesDirectory -Force | Out-Null
        $scriptOutput = Build-GlobalScript $enginePath $targetScript
        $scriptBytes = ConvertTo-Utf8Bytes $scriptOutput
        Backup-Once $targetScript
        Write-BytesAtomic $targetScript $scriptBytes
        Write-Info "Clash Verge Rev 保持运行；已更新全局扩展脚本。"
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
        [pscustomobject]@{ Path = $vergePath; Bytes = $vergeBytes; Existed = (Test-Path -LiteralPath $vergePath); OriginalBytes = $(if (Test-Path -LiteralPath $vergePath) { [System.IO.File]::ReadAllBytes($vergePath) } else { $null }) },
        [pscustomobject]@{ Path = $configPath; Bytes = $configBytes; Existed = (Test-Path -LiteralPath $configPath); OriginalBytes = $(if (Test-Path -LiteralPath $configPath) { [System.IO.File]::ReadAllBytes($configPath) } else { $null }) },
        [pscustomobject]@{ Path = $statePath; Bytes = $stateBytes; Existed = (Test-Path -LiteralPath $statePath); OriginalBytes = $(if (Test-Path -LiteralPath $statePath) { [System.IO.File]::ReadAllBytes($statePath) } else { $null }) }
    )
    foreach ($target in $targets) { Backup-Once $target.Path }

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
    Write-Info "已开启 TUN，并让全局脚本接管 DNS 配置。下次订阅刷新时应用补丁。"
    Write-Info "安装程序从未退出、停止或重启 Clash Verge Rev。"
    Write-Info "已有 AI 分组只补全规则；没有时创建包含全部可用节点和代理提供者的独立选择器。安装程序不会替你选择节点。"
    exit 0
} catch {
    [Console]::Error.WriteLine("[Clash 补丁] 安装失败：$($_.Exception.Message)")
    exit 1
}
