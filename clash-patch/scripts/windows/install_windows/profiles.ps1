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
