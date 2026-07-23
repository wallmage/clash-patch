function Protect-BackupAcl([string]$Path) {
    if ([Environment]::OSVersion.Platform -ne [PlatformID]::Win32NT) { return }

    $security = Get-Acl -LiteralPath $Path
    $security.SetAccessRuleProtection($true, $false)
    @($security.Access.IdentityReference | Select-Object -Unique) | ForEach-Object {
        $security.PurgeAccessRules($_)
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

function ConvertTo-NormalizedWindowsPath([string]$Path) {
    $candidate = $Path
    if ($candidate.StartsWith("\\?\UNC\", [StringComparison]::OrdinalIgnoreCase)) {
        $candidate = "\\" + $candidate.Substring(8)
    } elseif ($candidate.StartsWith("\\?\", [StringComparison]::OrdinalIgnoreCase)) {
        $candidate = $candidate.Substring(4)
    }
    $absolute = [System.IO.Path]::GetFullPath($candidate)
    return $absolute.TrimEnd(
        [System.IO.Path]::DirectorySeparatorChar,
        [System.IO.Path]::AltDirectorySeparatorChar
    )
}

function Get-AppHomeRelativePath([string]$Path) {
    if ([string]::IsNullOrWhiteSpace([string]$script:ClashPatchMutationRoot)) {
        throw "当前操作没有绑定 Clash Verge Rev 配置目录。"
    }
    $root = ConvertTo-NormalizedWindowsPath $script:ClashPatchMutationRoot
    $absolute = ConvertTo-NormalizedWindowsPath $Path
    if ([string]::Equals($absolute, $root, [StringComparison]::OrdinalIgnoreCase)) {
        return "."
    }
    $prefix = $root + [System.IO.Path]::DirectorySeparatorChar
    if (-not $absolute.StartsWith($prefix, [StringComparison]::OrdinalIgnoreCase)) {
        throw "事务目标超出 Clash Verge Rev 配置目录。"
    }
    return $absolute.Substring($prefix.Length).Replace(
        [System.IO.Path]::AltDirectorySeparatorChar,
        [System.IO.Path]::DirectorySeparatorChar
    )
}

function Enter-AppHomeMutationLock([string]$AppHome) {
    $canonical = ConvertTo-NormalizedWindowsPath $AppHome
    Assert-NoReparsePointPath $canonical "Clash Verge Rev 配置目录"
    Initialize-VerifiedFileNative
    $rootHandle = $null
    $lockStream = $null
    try {
        try {
            $rootHandle = [ClashPatch.VerifiedDeleteNative]::OpenDirectory($canonical)
            if ([ClashPatch.VerifiedDeleteNative]::IsReparsePoint($rootHandle)) {
                throw "Clash Verge Rev 配置目录不能是符号链接、目录联接或其他重解析点。"
            }
            $lockHandle = [ClashPatch.VerifiedDeleteNative]::OpenLockFile(
                (Join-Path $canonical ".clash-patch.lock")
            )
            if ([ClashPatch.VerifiedDeleteNative]::IsReparsePoint($lockHandle) -or
                [ClashPatch.VerifiedDeleteNative]::GetLinkCount($lockHandle) -ne 1) {
                $lockHandle.Dispose()
                throw "Clash 补丁锁文件不能是链接。"
            }
            $lockStream = New-Object System.IO.FileStream($lockHandle, [System.IO.FileAccess]::ReadWrite)
        } catch [System.ComponentModel.Win32Exception] {
            throw "同一配置目录已有 Clash 补丁操作正在进行，请稍后重试。"
        }

        $script:ClashPatchMutationRoot = $canonical
        $script:ClashPatchTransactionJournalPath = Join-Path $canonical ".clash-patch-transaction.json"
        $recoveredTransaction = Test-Path -LiteralPath $script:ClashPatchTransactionJournalPath -PathType Leaf
        Repair-InterruptedFileTransaction
        return [pscustomobject]@{
            Root = $canonical
            RootHandle = $rootHandle
            LockStream = $lockStream
            RecoveredTransaction = $recoveredTransaction
        }
    } catch {
        if ($null -ne $lockStream) { $lockStream.Dispose() }
        if ($null -ne $rootHandle) { $rootHandle.Dispose() }
        $script:ClashPatchMutationRoot = $null
        $script:ClashPatchTransactionJournalPath = $null
        throw
    }
}

function Exit-AppHomeMutationLock([object]$Lock) {
    if ($null -eq $Lock) { return }
    try {
        if ($null -ne $Lock.LockStream) { $Lock.LockStream.Dispose() }
    } finally {
        if ($null -ne $Lock.RootHandle) { $Lock.RootHandle.Dispose() }
        if ([string]::Equals(
            [string]$script:ClashPatchMutationRoot,
            [string]$Lock.Root,
            [StringComparison]::OrdinalIgnoreCase
        )) {
            $script:ClashPatchMutationRoot = $null
            $script:ClashPatchTransactionJournalPath = $null
        }
    }
}

function Get-PathKey([string]$Path) {
    $identity = if ([string]::IsNullOrWhiteSpace([string]$script:ClashPatchMutationRoot)) {
        (ConvertTo-NormalizedWindowsPath $Path).ToUpperInvariant()
    } else {
        (Get-AppHomeRelativePath $Path).ToUpperInvariant()
    }
    $bytes = [System.Text.Encoding]::UTF8.GetBytes($identity)
    $sha = [System.Security.Cryptography.SHA256]::Create()
    try {
        return (($sha.ComputeHash($bytes, 0, $bytes.Length) | ForEach-Object { $_.ToString("x2") }) -join '').Substring(0, 16)
    } finally {
        $sha.Dispose()
    }
}

function Assert-NoReparsePointPath([string]$Path, [string]$Label) {
    $current = [System.IO.Path]::GetFullPath($Path)
    $visited = New-Object 'System.Collections.Generic.HashSet[string]' ([System.StringComparer]::OrdinalIgnoreCase)
    while (-not [string]::IsNullOrWhiteSpace($current) -and $visited.Add($current)) {
        if (Test-Path -LiteralPath $current) {
            $item = Get-Item -LiteralPath $current -Force
            if (($item.Attributes -band [System.IO.FileAttributes]::ReparsePoint) -ne 0) {
                throw "$Label 不能经过符号链接、目录联接或其他重解析点：$current"
            }
        }
        $parent = [System.IO.Path]::GetDirectoryName($current)
        if ([string]::IsNullOrWhiteSpace($parent) -or
            [string]::Equals($parent, $current, [StringComparison]::OrdinalIgnoreCase)) {
            break
        }
        $current = $parent
    }
}

function Backup-Versioned(
    [string]$Path,
    [string]$BackupRoot,
    [string]$Reason = "prewrite",
    [switch]$WithMetadata
) {
    Assert-NoReparsePointPath $Path "备份来源"
    Assert-NoReparsePointPath $BackupRoot "备份目录"
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
    $createdBytes = $null
    $failure = $null
    try {
        $sourceStream = [System.IO.File]::Open($Path, [System.IO.FileMode]::Open, [System.IO.FileAccess]::Read, [System.IO.FileShare]::Read)
        $backupStream = [System.IO.File]::Open($destination, [System.IO.FileMode]::CreateNew, [System.IO.FileAccess]::ReadWrite, [System.IO.FileShare]::None)
        $created = $true
        $sourceStream.CopyTo($backupStream)
        $backupStream.Flush($true)
        $createdBytes = Get-StreamBytes $backupStream
    } catch {
        $failure = $_
    } finally {
        if ($created -and $null -ne $backupStream -and $null -eq $createdBytes) {
            try { $createdBytes = Get-StreamBytes $backupStream } catch { }
        }
        if ($null -ne $backupStream) { $backupStream.Dispose() }
        if ($null -ne $sourceStream) { $sourceStream.Dispose() }
    }
    if ($null -ne $failure) {
        if ($created -and $null -ne $createdBytes) {
            Remove-VerifiedOwnedFile $destination $createdBytes
        }
        throw $failure
    }
    try {
        Protect-BackupAcl $destination
    } catch {
        Remove-VerifiedOwnedFile $destination $createdBytes
        throw
    }
    if ($WithMetadata) {
        return [pscustomobject]@{
            Path = $destination
            Sha256 = Get-BytesSha256 $createdBytes
        }
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
    $snapshot = Get-OptionalFileSnapshot $Path "写入目标"
    Invoke-VerifiedFileTransaction @(
        [pscustomobject]@{
            Path = $Path
            Bytes = $Bytes
            Existed = [bool]$snapshot.Exists
            OriginalBytes = $snapshot.Bytes
            OriginalIdentity = $snapshot.Identity
        }
    )
}

function ConvertTo-Utf8Bytes([string]$Content) {
    return (New-Object System.Text.UTF8Encoding($false)).GetBytes($Content)
}

function Write-Utf8Atomic([string]$Path, [string]$Content) {
    Write-BytesAtomic $Path (ConvertTo-Utf8Bytes $Content)
}


function Get-BytesSha256([byte[]]$Bytes) {
    # PowerShell binds an empty byte array as $null; empty input must still hash.
    if ($null -eq $Bytes) { $Bytes = [byte[]]@() }
    $sha = [System.Security.Cryptography.SHA256]::Create()
    try {
        return ([System.BitConverter]::ToString($sha.ComputeHash($Bytes, 0, $Bytes.Length))).Replace("-", "").ToLowerInvariant()
    } finally {
        $sha.Dispose()
    }
}

function Get-FileSha256([string]$Path) {
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { return "" }
    return (Get-BytesSha256 ([System.IO.File]::ReadAllBytes($Path)))
}

function Get-StreamBytes([System.IO.FileStream]$Stream) {
    $Stream.Position = 0
    $memory = New-Object System.IO.MemoryStream
    try {
        $Stream.CopyTo($memory)
        return $memory.ToArray()
    } finally {
        $memory.Dispose()
    }
}

function Get-OptionalFileSnapshot([string]$Path, [string]$Label) {
    Assert-NoReparsePointPath $Path $Label
    if (-not (Test-Path -LiteralPath $Path)) {
        return [pscustomobject]@{
            Exists = $false
            Path = $Path
            Bytes = $null
            Identity = $null
        }
    }
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
        throw "$Label 路径不是文件。"
    }
    Initialize-VerifiedFileNative
    $directoryHandles = @(Open-VerifiedDirectoryChain (Split-Path -Parent $Path))
    $handle = [ClashPatch.VerifiedDeleteNative]::Open($Path, $false, $false)
    $stream = $null
    try {
        if ([ClashPatch.VerifiedDeleteNative]::IsReparsePoint($handle)) {
            throw "$Label 不能是符号链接或其他重解析点。"
        }
        if ([ClashPatch.VerifiedDeleteNative]::GetLinkCount($handle) -ne 1) {
            throw "$Label 不能有硬链接别名。"
        }
        $identity = [ClashPatch.VerifiedDeleteNative]::GetIdentity($handle)
        $stream = New-Object System.IO.FileStream($handle, [System.IO.FileAccess]::Read)
        return [pscustomobject]@{
            Exists = $true
            Path = $Path
            Bytes = Get-StreamBytes $stream
            Identity = $identity
        }
    } finally {
        if ($null -ne $stream) {
            $stream.Dispose()
        } else {
            $handle.Dispose()
        }
        for ($index = $directoryHandles.Count - 1; $index -ge 0; $index--) {
            $directoryHandles[$index].Dispose()
        }
    }
}

function Remove-VerifiedOwnedFile(
    [string]$Path,
    [byte[]]$ExpectedBytes,
    [string]$ExpectedIdentity = ""
) {
    if (-not (Test-Path -LiteralPath $Path)) { return }
    $snapshot = Get-OptionalFileSnapshot $Path "待删除文件"
    if ((Get-BytesSha256 $snapshot.Bytes) -ne (Get-BytesSha256 $ExpectedBytes) -or
        (-not [string]::IsNullOrWhiteSpace($ExpectedIdentity) -and $snapshot.Identity -cne $ExpectedIdentity)) {
        throw "待删除文件在验证后发生变化。"
    }
    Invoke-VerifiedWriteDeleteTransaction @() @(
        [pscustomobject]@{
            Path = $Path
            Existed = $true
            OriginalBytes = $snapshot.Bytes
            OriginalIdentity = $snapshot.Identity
        }
    )
}

function Write-LockedStreamBytes(
    [System.IO.FileStream]$Stream,
    [byte[]]$Replacement,
    [byte[]]$Original
) {
    try {
        $Stream.Position = 0
        $Stream.Write($Replacement, 0, $Replacement.Length)
        $Stream.SetLength($Replacement.Length)
        $Stream.Flush($true)
    } catch {
        $writeError = $_
        try {
            $Stream.Position = 0
            $Stream.Write($Original, 0, $Original.Length)
            $Stream.SetLength($Original.Length)
            $Stream.Flush($true)
        } catch {
            throw "写入失败，且原内容恢复失败：$($_.Exception.Message)"
        }
        throw $writeError
    }
}

function Initialize-VerifiedFileNative {
    if ($null -ne ("ClashPatch.VerifiedDeleteNative" -as [type])) { return }
    Add-Type -TypeDefinition @'
using System;
using System.ComponentModel;
using System.Runtime.InteropServices;
using Microsoft.Win32.SafeHandles;

namespace ClashPatch
{
    public static class VerifiedDeleteNative
    {
        private const uint GenericRead = 0x80000000;
        private const uint GenericWrite = 0x40000000;
        private const uint DeleteAccess = 0x00010000;
        private const uint CreateNew = 1;
        private const uint OpenExisting = 3;
        private const uint OpenAlways = 4;
        private const uint FileShareRead = 0x00000001;
        private const uint FileShareWrite = 0x00000002;
        private const uint OpenReparsePoint = 0x00200000;
        private const uint BackupSemantics = 0x02000000;
        private const uint FileAttributeReparsePoint = 0x00000400;
        private const int FileDispositionInfo = 4;
        private const int FileAttributeTagInfo = 9;

        [StructLayout(LayoutKind.Sequential)]
        private struct FileDispositionInformation
        {
            public byte DeleteFile;
        }

        [StructLayout(LayoutKind.Sequential)]
        private struct FileAttributeTagInformation
        {
            public uint FileAttributes;
            public uint ReparseTag;
        }

        [StructLayout(LayoutKind.Sequential)]
        private struct ByHandleFileInformation
        {
            public uint FileAttributes;
            public System.Runtime.InteropServices.ComTypes.FILETIME CreationTime;
            public System.Runtime.InteropServices.ComTypes.FILETIME LastAccessTime;
            public System.Runtime.InteropServices.ComTypes.FILETIME LastWriteTime;
            public uint VolumeSerialNumber;
            public uint FileSizeHigh;
            public uint FileSizeLow;
            public uint NumberOfLinks;
            public uint FileIndexHigh;
            public uint FileIndexLow;
        }

        [DllImport("kernel32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
        private static extern SafeFileHandle CreateFile(
            string fileName,
            uint desiredAccess,
            uint shareMode,
            IntPtr securityAttributes,
            uint creationDisposition,
            uint flagsAndAttributes,
            IntPtr templateFile
        );

        [DllImport("kernel32.dll", SetLastError = true)]
        private static extern bool SetFileInformationByHandle(
            SafeFileHandle file,
            int informationClass,
            ref FileDispositionInformation information,
            uint bufferSize
        );

        [DllImport("kernel32.dll", SetLastError = true)]
        private static extern bool GetFileInformationByHandleEx(
            SafeFileHandle file,
            int informationClass,
            out FileAttributeTagInformation information,
            uint bufferSize
        );

        [DllImport("kernel32.dll", SetLastError = true)]
        private static extern bool GetFileInformationByHandle(
            SafeFileHandle file,
            out ByHandleFileInformation information
        );

        public static SafeFileHandle Open(string path, bool writable, bool createNew)
        {
            uint desiredAccess = GenericRead | DeleteAccess;
            if (writable)
            {
                desiredAccess |= GenericWrite;
            }
            SafeFileHandle handle = CreateFile(
                path,
                desiredAccess,
                0,
                IntPtr.Zero,
                createNew ? CreateNew : OpenExisting,
                OpenReparsePoint,
                IntPtr.Zero
            );
            if (handle.IsInvalid)
            {
                int error = Marshal.GetLastWin32Error();
                handle.Dispose();
                throw new Win32Exception(error, "无法独占打开事务目标。");
            }
            return handle;
        }

        public static SafeFileHandle OpenDirectory(string path)
        {
            SafeFileHandle handle = CreateFile(
                path,
                0,
                FileShareRead | FileShareWrite,
                IntPtr.Zero,
                OpenExisting,
                BackupSemantics | OpenReparsePoint,
                IntPtr.Zero
            );
            if (handle.IsInvalid)
            {
                int error = Marshal.GetLastWin32Error();
                handle.Dispose();
                throw new Win32Exception(error, "无法锁定事务目标目录。");
            }
            return handle;
        }

        public static SafeFileHandle OpenLockFile(string path)
        {
            SafeFileHandle handle = CreateFile(
                path,
                GenericRead | GenericWrite,
                0,
                IntPtr.Zero,
                OpenAlways,
                OpenReparsePoint,
                IntPtr.Zero
            );
            if (handle.IsInvalid)
            {
                int error = Marshal.GetLastWin32Error();
                handle.Dispose();
                throw new Win32Exception(error, "无法获取配置目录操作锁。");
            }
            return handle;
        }

        public static bool IsReparsePoint(SafeFileHandle handle)
        {
            FileAttributeTagInformation information;
            if (!GetFileInformationByHandleEx(
                handle,
                FileAttributeTagInfo,
                out information,
                (uint)Marshal.SizeOf(typeof(FileAttributeTagInformation))
            ))
            {
                throw new Win32Exception(Marshal.GetLastWin32Error(), "无法读取待删除文件属性。");
            }
            return (information.FileAttributes & FileAttributeReparsePoint) != 0;
        }

        public static uint GetLinkCount(SafeFileHandle handle)
        {
            ByHandleFileInformation information;
            if (!GetFileInformationByHandle(handle, out information))
            {
                throw new Win32Exception(Marshal.GetLastWin32Error(), "无法读取事务目标的文件身份。");
            }
            return information.NumberOfLinks;
        }

        public static string GetIdentity(SafeFileHandle handle)
        {
            ByHandleFileInformation information;
            if (!GetFileInformationByHandle(handle, out information))
            {
                throw new Win32Exception(Marshal.GetLastWin32Error(), "无法读取事务目标的文件身份。");
            }
            return information.VolumeSerialNumber.ToString("x8") + ":" +
                information.FileIndexHigh.ToString("x8") +
                information.FileIndexLow.ToString("x8");
        }

        public static void SetDeleteDisposition(SafeFileHandle handle, bool deleteFile)
        {
            FileDispositionInformation information = new FileDispositionInformation();
            information.DeleteFile = deleteFile ? (byte)1 : (byte)0;
            if (!SetFileInformationByHandle(
                handle,
                FileDispositionInfo,
                ref information,
                (uint)Marshal.SizeOf(typeof(FileDispositionInformation))
            ))
            {
                throw new Win32Exception(Marshal.GetLastWin32Error(), "无法更新已经验证的文件删除状态。");
            }
        }
    }
}
'@
}

function Open-VerifiedDirectoryChain([string]$Directory) {
    Initialize-VerifiedFileNative
    $absolute = ConvertTo-NormalizedWindowsPath $Directory
    $root = [System.IO.Path]::GetPathRoot($absolute)
    if ([string]::IsNullOrWhiteSpace($root)) { throw "事务目标目录无效。" }
    $relative = $absolute.Substring($root.Length)
    $segments = @($relative.Split(
        @([System.IO.Path]::DirectorySeparatorChar, [System.IO.Path]::AltDirectorySeparatorChar),
        [System.StringSplitOptions]::RemoveEmptyEntries
    ))
    $handles = @()
    $current = $root
    try {
        $rootHandle = [ClashPatch.VerifiedDeleteNative]::OpenDirectory($current)
        if ([ClashPatch.VerifiedDeleteNative]::IsReparsePoint($rootHandle)) {
            $rootHandle.Dispose()
            throw "事务目标目录不能经过重解析点：$current"
        }
        $handles += $rootHandle
        foreach ($segment in $segments) {
            $current = Join-Path $current $segment
            if (-not (Test-Path -LiteralPath $current -PathType Container)) {
                New-Item -ItemType Directory -Path $current | Out-Null
            }
            $handle = [ClashPatch.VerifiedDeleteNative]::OpenDirectory($current)
            if ([ClashPatch.VerifiedDeleteNative]::IsReparsePoint($handle)) {
                $handle.Dispose()
                throw "事务目标目录不能经过重解析点：$current"
            }
            $handles += $handle
        }
        return $handles
    } catch {
        for ($index = $handles.Count - 1; $index -ge 0; $index--) {
            $handles[$index].Dispose()
        }
        throw
    }
}

function Set-VerifiedDeleteDisposition([System.IO.FileStream]$Stream, [bool]$DeleteFile) {
    [ClashPatch.VerifiedDeleteNative]::SetDeleteDisposition($Stream.SafeFileHandle, $DeleteFile)
}

function Write-FileTransactionJournal([object[]]$Entries) {
    if ([string]::IsNullOrWhiteSpace([string]$script:ClashPatchTransactionJournalPath) -or
        @($Entries).Count -eq 0) {
        return $null
    }
    if (Test-Path -LiteralPath $script:ClashPatchTransactionJournalPath) {
        throw "发现尚未恢复的文件事务记录。"
    }
    $journalActions = @()
    foreach ($entry in $Entries) {
        [byte[]]$originalBytes = @()
        if ($null -ne $entry.Original) { $originalBytes = [byte[]]$entry.Original }
        $journalActions += [ordered]@{
            Action = [string]$entry.Action
            Path = Get-AppHomeRelativePath ([string]$entry.Target.Path)
            Existed = (-not [bool]$entry.Created)
            Identity = [ClashPatch.VerifiedDeleteNative]::GetIdentity($entry.Stream.SafeFileHandle)
            OriginalBase64 = [Convert]::ToBase64String($originalBytes)
            ReplacementBase64 = if ($entry.Action -eq "write") {
                [Convert]::ToBase64String([byte[]]$entry.Target.Bytes)
            } else {
                ""
            }
        }
    }
    $journal = [ordered]@{
        Version = 1
        Actions = $journalActions
    }
    $bytes = ConvertTo-Utf8Bytes (($journal | ConvertTo-Json -Depth 5) + "`r`n")
    $temporary = Join-Path $script:ClashPatchMutationRoot (
        ".clash-patch-transaction." + [Guid]::NewGuid().ToString("N") + ".tmp"
    )
    $stream = $null
    $moved = $false
    try {
        $stream = [System.IO.File]::Open(
            $temporary,
            [System.IO.FileMode]::CreateNew,
            [System.IO.FileAccess]::ReadWrite,
            [System.IO.FileShare]::None
        )
        $stream.Write($bytes, 0, $bytes.Length)
        $stream.Flush($true)
        $stream.Dispose()
        $stream = $null
        [System.IO.File]::Move($temporary, $script:ClashPatchTransactionJournalPath)
        Protect-BackupAcl $script:ClashPatchTransactionJournalPath
        $moved = $true
        return $bytes
    } finally {
        if ($null -ne $stream) { $stream.Dispose() }
        if (-not $moved -and (Test-Path -LiteralPath $temporary -PathType Leaf)) {
            [System.IO.File]::Delete($temporary)
        }
    }
}

function Remove-FileTransactionJournal([byte[]]$ExpectedBytes) {
    $path = [string]$script:ClashPatchTransactionJournalPath
    if ([string]::IsNullOrWhiteSpace($path)) { return }
    $snapshot = Get-OptionalFileSnapshot $path "文件事务记录"
    if (-not $snapshot.Exists) { return }
    if ((Get-BytesSha256 $snapshot.Bytes) -ne (Get-BytesSha256 $ExpectedBytes)) {
        throw "文件事务记录在操作期间发生变化。"
    }
    $directoryHandles = @(Open-VerifiedDirectoryChain (Split-Path -Parent $path))
    $handle = $null
    $stream = $null
    try {
        $handle = [ClashPatch.VerifiedDeleteNative]::Open($path, $false, $false)
        $stream = New-Object System.IO.FileStream($handle, [System.IO.FileAccess]::Read)
        if ([ClashPatch.VerifiedDeleteNative]::GetIdentity($handle) -cne $snapshot.Identity -or
            (Get-BytesSha256 (Get-StreamBytes $stream)) -ne (Get-BytesSha256 $ExpectedBytes)) {
            throw "文件事务记录在操作期间发生变化。"
        }
        Set-VerifiedDeleteDisposition $stream $true
    } finally {
        if ($null -ne $stream) {
            $stream.Dispose()
        } elseif ($null -ne $handle) {
            $handle.Dispose()
        }
        for ($index = $directoryHandles.Count - 1; $index -ge 0; $index--) {
            $directoryHandles[$index].Dispose()
        }
    }
}

function Get-ValidatedFileTransactionJournal([object]$Journal) {
    if ($null -eq $Journal) { throw "文件事务记录无效。" }
    $properties = @($Journal.PSObject.Properties.Name | Sort-Object)
    if (($properties -join ",") -cne "Actions,Version" -or
        -not ($Journal.Version -is [int] -or $Journal.Version -is [long]) -or
        [long]$Journal.Version -ne 1) {
        throw "文件事务记录无效。"
    }
    $actions = @($Journal.Actions)
    if ($actions.Count -eq 0) { throw "文件事务记录没有操作项。" }
    $paths = New-Object 'System.Collections.Generic.HashSet[string]' ([System.StringComparer]::OrdinalIgnoreCase)
    $validated = @()
    foreach ($action in $actions) {
        $actionProperties = @($action.PSObject.Properties.Name | Sort-Object)
        if (($actionProperties -join ",") -cne "Action,Existed,Identity,OriginalBase64,Path,ReplacementBase64" -or
            [string]$action.Action -notin @("write", "delete") -or
            -not ($action.Existed -is [bool]) -or
            -not ($action.Identity -is [string]) -or
            [string]::IsNullOrWhiteSpace([string]$action.Identity) -or
            -not ($action.OriginalBase64 -is [string]) -or
            -not ($action.ReplacementBase64 -is [string])) {
            throw "文件事务记录操作项无效。"
        }
        $relative = [string]$action.Path
        if ([string]::IsNullOrWhiteSpace($relative) -or
            [System.IO.Path]::IsPathRooted($relative) -or
            $relative -eq "." -or
            @($relative.Split("\") | Where-Object { $_ -eq ".." }).Count -gt 0) {
            throw "文件事务记录包含无效路径。"
        }
        $absolute = [System.IO.Path]::GetFullPath((Join-Path $script:ClashPatchMutationRoot $relative))
        if ((Get-AppHomeRelativePath $absolute) -cne $relative.Replace(
            [System.IO.Path]::AltDirectorySeparatorChar,
            [System.IO.Path]::DirectorySeparatorChar
        )) {
            throw "文件事务记录路径不规范。"
        }
        if (-not $paths.Add($absolute)) { throw "文件事务记录包含重复路径。" }
        try {
            $original = [Convert]::FromBase64String([string]$action.OriginalBase64)
            $replacement = [Convert]::FromBase64String([string]$action.ReplacementBase64)
        } catch {
            throw "文件事务记录包含无效 Base64。"
        }
        if ([Convert]::ToBase64String($original) -cne [string]$action.OriginalBase64 -or
            [Convert]::ToBase64String($replacement) -cne [string]$action.ReplacementBase64 -or
            ([string]$action.Action -eq "delete" -and
                (-not [bool]$action.Existed -or $replacement.Length -ne 0)) -or
            ([string]$action.Action -eq "write" -and
                -not [bool]$action.Existed -and $original.Length -ne 0)) {
            throw "文件事务记录内容不规范。"
        }
        $validated += [pscustomobject]@{
            Action = [string]$action.Action
            Path = $absolute
            Existed = [bool]$action.Existed
            Identity = [string]$action.Identity
            Original = $original
            Replacement = $replacement
        }
    }
    return $validated
}

function Get-InterruptedTransactionRecoveryPlan([object[]]$Actions) {
    $plan = @()
    foreach ($action in $Actions) {
        $snapshot = Get-OptionalFileSnapshot $action.Path "中断事务目标"
        $currentHash = if ($snapshot.Exists) { Get-BytesSha256 $snapshot.Bytes } else { "" }
        $originalHash = Get-BytesSha256 $action.Original
        $replacementHash = Get-BytesSha256 $action.Replacement
        if ($snapshot.Exists -and $snapshot.Identity -cne $action.Identity) {
            throw "中断事务目标已被同内容的其他文件替换：$($action.Path)"
        }
        if ($action.Action -eq "write" -and $action.Existed) {
            if (-not $snapshot.Exists -or $currentHash -notin @($originalHash, $replacementHash)) {
                throw "中断事务目标有无法自动合并的新改动：$($action.Path)"
            }
            if ($currentHash -eq $replacementHash -and $currentHash -ne $originalHash) {
                $plan += [pscustomobject]@{ Operation = "write"; Action = $action; Snapshot = $snapshot }
            }
        } elseif ($action.Action -eq "write") {
            if ($snapshot.Exists) {
                $plan += [pscustomobject]@{ Operation = "delete"; Action = $action; Snapshot = $snapshot }
            }
        } else {
            if ($snapshot.Exists -and $currentHash -ne $originalHash) {
                throw "中断事务删除目标有无法自动合并的新改动：$($action.Path)"
            }
            if (-not $snapshot.Exists) {
                $plan += [pscustomobject]@{ Operation = "create"; Action = $action; Snapshot = $snapshot }
            }
        }
    }
    return $plan
}

function Invoke-InterruptedTransactionRecovery([object[]]$Plan) {
    foreach ($item in $Plan) {
        $directoryHandles = @(Open-VerifiedDirectoryChain (Split-Path -Parent $item.Action.Path))
        $handle = $null
        $stream = $null
        try {
            if ($item.Operation -eq "create") {
                $handle = [ClashPatch.VerifiedDeleteNative]::Open($item.Action.Path, $true, $true)
                $stream = New-Object System.IO.FileStream($handle, [System.IO.FileAccess]::ReadWrite)
                Write-LockedStreamBytes $stream $item.Action.Original ([byte[]]@())
            } else {
                $writable = $item.Operation -eq "write"
                $handle = [ClashPatch.VerifiedDeleteNative]::Open($item.Action.Path, $writable, $false)
                $access = if ($writable) { [System.IO.FileAccess]::ReadWrite } else { [System.IO.FileAccess]::Read }
                $stream = New-Object System.IO.FileStream($handle, $access)
                $current = Get-StreamBytes $stream
                if ([ClashPatch.VerifiedDeleteNative]::GetIdentity($handle) -cne $item.Snapshot.Identity -or
                    (Get-BytesSha256 $current) -ne (Get-BytesSha256 $item.Snapshot.Bytes)) {
                    throw "中断事务目标在恢复前再次发生变化：$($item.Action.Path)"
                }
                if ($item.Operation -eq "write") {
                    Write-LockedStreamBytes $stream $item.Action.Original $current
                } else {
                    Set-VerifiedDeleteDisposition $stream $true
                }
            }
        } finally {
            if ($null -ne $stream) {
                $stream.Dispose()
            } elseif ($null -ne $handle) {
                $handle.Dispose()
            }
            for ($index = $directoryHandles.Count - 1; $index -ge 0; $index--) {
                $directoryHandles[$index].Dispose()
            }
        }
    }
}

function Assert-InterruptedTransactionRecovered([object[]]$Actions) {
    foreach ($action in $Actions) {
        $snapshot = Get-OptionalFileSnapshot $action.Path "中断事务恢复结果"
        if ($action.Action -eq "write" -and -not $action.Existed) {
            if ($snapshot.Exists) { throw "中断事务新建文件未删除：$($action.Path)" }
        } elseif (-not $snapshot.Exists -or
            (Get-BytesSha256 $snapshot.Bytes) -ne (Get-BytesSha256 $action.Original)) {
            throw "中断事务未恢复原文件：$($action.Path)"
        }
    }
}

function Repair-InterruptedFileTransaction {
    $path = [string]$script:ClashPatchTransactionJournalPath
    if ([string]::IsNullOrWhiteSpace($path)) { return }
    $snapshot = Get-OptionalFileSnapshot $path "文件事务记录"
    if (-not $snapshot.Exists) { return }
    try {
        $text = (New-Object System.Text.UTF8Encoding($false, $true)).GetString($snapshot.Bytes)
        if ([regex]::Matches($text, '(?i)"Version"\s*:').Count -ne 1 -or
            [regex]::Matches($text, '(?i)"Actions"\s*:').Count -ne 1) {
            throw "字段重复或缺失。"
        }
        $journal = $text | ConvertFrom-Json
        $actions = @(Get-ValidatedFileTransactionJournal $journal)
    } catch {
        throw "文件事务记录损坏，无法安全恢复。"
    }
    $plan = @(Get-InterruptedTransactionRecoveryPlan $actions)
    Invoke-InterruptedTransactionRecovery $plan
    Assert-InterruptedTransactionRecovered $actions
    Remove-FileTransactionJournal $snapshot.Bytes
}

function Invoke-VerifiedPathTransaction([object[]]$WriteTargets, [object[]]$DeleteTargets) {
    $writePathKeys = New-Object 'System.Collections.Generic.HashSet[string]' ([System.StringComparer]::OrdinalIgnoreCase)
    $actions = @()
    foreach ($writeTarget in @($WriteTargets)) {
        if ([string]::IsNullOrWhiteSpace([string]$writeTarget.Path)) { throw "事务写入目标路径无效。" }
        $pathKey = [System.IO.Path]::GetFullPath([string]$writeTarget.Path)
        if (-not $writePathKeys.Add($pathKey)) { throw "事务包含重复写入目标：$($writeTarget.Path)" }
        $actions += [pscustomobject]@{
            Action = "write"
            Path = [string]$writeTarget.Path
            Target = $writeTarget
            Writable = $true
            CreateNew = (-not [bool]$writeTarget.Existed)
        }
    }
    $deletePathKeys = New-Object 'System.Collections.Generic.HashSet[string]' ([System.StringComparer]::OrdinalIgnoreCase)
    foreach ($deleteTarget in @($DeleteTargets)) {
        if ([string]::IsNullOrWhiteSpace([string]$deleteTarget.Path)) { throw "事务删除目标路径无效。" }
        $pathKey = [System.IO.Path]::GetFullPath([string]$deleteTarget.Path)
        if (-not $deletePathKeys.Add($pathKey)) { throw "事务包含重复删除目标：$($deleteTarget.Path)" }
        if ($writePathKeys.Contains($pathKey)) { throw "事务不能同时写入并删除同一路径：$($deleteTarget.Path)" }
        if (-not [bool]$deleteTarget.Existed) { throw "事务删除目标必须是已经存在的文件：$($deleteTarget.Path)" }
        $actions += [pscustomobject]@{
            Action = "delete"
            Path = [string]$deleteTarget.Path
            Target = $deleteTarget
            Writable = $false
            CreateNew = $false
        }
    }

    foreach ($action in $actions) {
        Assert-NoReparsePointPath $action.Path "事务目标"
    }
    Initialize-VerifiedFileNative
    $opened = @()
    $directoryHandles = @()
    $markedDeletes = @()
    $journalBytes = $null
    $operationFailure = $null
    $recoveryFailures = @()
    try {
        foreach ($action in @($actions | Sort-Object Path)) {
            $directory = Split-Path -Parent $action.Path
            $directoryHandles += @(Open-VerifiedDirectoryChain $directory)
            if ($action.CreateNew) {
                if (Test-Path -LiteralPath $action.Path) {
                    throw "目标路径在候选生成后出现，拒绝覆盖：$($action.Path)"
                }
            } elseif (-not (Test-Path -LiteralPath $action.Path -PathType Leaf)) {
                throw "事务目标在候选生成后消失或不再是文件：$($action.Path)"
            }

            $handle = [ClashPatch.VerifiedDeleteNative]::Open(
                $action.Path,
                [bool]$action.Writable,
                [bool]$action.CreateNew
            )
            $stream = $null
            try {
                if ([ClashPatch.VerifiedDeleteNative]::IsReparsePoint($handle)) {
                    throw "事务目标不能是符号链接或其他重解析点：$($action.Path)"
                }
                if ([ClashPatch.VerifiedDeleteNative]::GetLinkCount($handle) -ne 1) {
                    throw "事务目标不能有硬链接别名：$($action.Path)"
                }
                $access = if ($action.Writable) { [System.IO.FileAccess]::ReadWrite } else { [System.IO.FileAccess]::Read }
                $stream = New-Object System.IO.FileStream($handle, $access)
            } catch {
                if ($null -ne $stream) { $stream.Dispose() } else { $handle.Dispose() }
                throw
            }
            $entry = [pscustomobject]@{
                Action = $action.Action
                Target = $action.Target
                Stream = $stream
                Original = [byte[]]@()
                Created = [bool]$action.CreateNew
            }
            $opened += $entry
            $current = Get-StreamBytes $stream
            $entry.Original = $current
            if ($action.CreateNew) {
                if ($current.Length -ne 0) { throw "新建事务目标不是空文件：$($action.Path)" }
            } else {
                $identityProperty = $action.Target.PSObject.Properties["OriginalIdentity"]
                if ($null -eq $identityProperty -or [string]::IsNullOrWhiteSpace([string]$identityProperty.Value)) {
                    throw "事务目标缺少候选生成时的文件身份：$($action.Path)"
                }
                if ([ClashPatch.VerifiedDeleteNative]::GetIdentity($handle) -cne [string]$identityProperty.Value -or
                    (Get-BytesSha256 $current) -ne (Get-BytesSha256 $action.Target.OriginalBytes)) {
                    throw "事务目标在候选生成后发生变化，拒绝继续：$($action.Path)"
                }
            }
        }

        $journalBytes = Write-FileTransactionJournal $opened
        foreach ($entry in @($opened | Where-Object { $_.Action -eq "write" })) {
            Write-LockedStreamBytes $entry.Stream $entry.Target.Bytes $entry.Original
        }
        foreach ($entry in @($opened | Where-Object { $_.Action -eq "write" })) {
            if ((Get-BytesSha256 (Get-StreamBytes $entry.Stream)) -ne (Get-BytesSha256 $entry.Target.Bytes)) {
                throw "写入后的文件与已验证候选不一致：$($entry.Target.Path)"
            }
        }
        foreach ($entry in @($opened | Where-Object { $_.Action -eq "delete" })) {
            Set-VerifiedDeleteDisposition $entry.Stream $true
            $markedDeletes += $entry
        }
    } catch {
        $operationFailure = $_
    }

    if ($null -ne $operationFailure) {
        for ($i = $markedDeletes.Count - 1; $i -ge 0; $i--) {
            try {
                Set-VerifiedDeleteDisposition $markedDeletes[$i].Stream $false
            } catch {
                $recoveryFailures += "$($markedDeletes[$i].Target.Path)：取消删除失败：$($_.Exception.Message)"
            }
        }
        for ($i = $opened.Count - 1; $i -ge 0; $i--) {
            $entry = $opened[$i]
            if ($entry.Action -ne "write") { continue }
            if ($entry.Created) {
                try {
                    Set-VerifiedDeleteDisposition $entry.Stream $true
                } catch {
                    $recoveryFailures += "$($entry.Target.Path)：删除事务新建文件失败：$($_.Exception.Message)"
                }
            } else {
                try {
                    Write-LockedStreamBytes $entry.Stream $entry.Original (Get-StreamBytes $entry.Stream)
                    if ((Get-BytesSha256 (Get-StreamBytes $entry.Stream)) -ne (Get-BytesSha256 $entry.Original)) {
                        throw "恢复后的内容与原文件不一致。"
                    }
                } catch {
                    $recoveryFailures += "$($entry.Target.Path)：恢复原文件失败：$($_.Exception.Message)"
                }
            }
        }
    }

    for ($i = $opened.Count - 1; $i -ge 0; $i--) {
        try {
            $opened[$i].Stream.Dispose()
        } catch {
            $recoveryFailures += "$($opened[$i].Target.Path)：关闭事务文件失败：$($_.Exception.Message)"
        }
    }
    for ($i = $directoryHandles.Count - 1; $i -ge 0; $i--) {
        try {
            $directoryHandles[$i].Dispose()
        } catch {
            $recoveryFailures += "关闭事务目标目录失败：$($_.Exception.Message)"
        }
    }
    if ($null -ne $journalBytes -and $recoveryFailures.Count -eq 0) {
        try {
            Remove-FileTransactionJournal $journalBytes
        } catch {
            $journalFailure = $_
            try {
                Repair-InterruptedFileTransaction
            } catch {
                $recoveryFailures += "清理事务记录失败：$($journalFailure.Exception.Message)；自动恢复失败：$($_.Exception.Message)"
            }
            if ($null -eq $operationFailure) { $operationFailure = $journalFailure }
        }
    }
    if ($recoveryFailures.Count -gt 0) {
        $operationMessage = if ($null -eq $operationFailure) { "文件清理失败" } else { $operationFailure.Exception.Message }
        throw ("事务失败：$operationMessage；回滚未能恢复所有文件：" + ($recoveryFailures -join "；"))
    }
    if ($null -ne $operationFailure) { throw $operationFailure }
}

function Invoke-VerifiedFileTransaction([object[]]$Targets) {
    Invoke-VerifiedPathTransaction $Targets @()
}

function Invoke-VerifiedWriteDeleteTransaction([object[]]$WriteTargets, [object[]]$DeleteTargets) {
    Invoke-VerifiedPathTransaction $WriteTargets $DeleteTargets
}


function Get-InstallStateEntry([object]$State, [string]$Name) {
    if ($null -eq $State) { return $null }
    $property = $State.PSObject.Properties[$Name]
    if ($null -eq $property) { return $null }
    return $property.Value
}

function Assert-InstallStateEntry([object]$Entry, [string]$Label) {
    if ($null -eq $Entry) { throw "安装状态文件无效：缺少 $Label。" }
    $propertyNames = @($Entry.PSObject.Properties.Name | Sort-Object)
    if (($propertyNames -join ",") -cne "Existed,InstalledSha256,OriginalBase64") {
        throw "安装状态文件无效：$Label 字段无效。"
    }
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
    $propertyNames = @($State.PSObject.Properties.Name | Sort-Object)
    if (($propertyNames -join ",") -cne "ConfigYaml,VergeYaml,Version") {
        throw "安装状态文件无效：字段无效。"
    }
    $version = $State.Version
    $numericVersion = $version -is [int] -or $version -is [long]
    if (-not $numericVersion -or [long]$version -ne 1) { throw "安装状态文件无效：版本不受支持。" }
    Assert-InstallStateEntry (Get-InstallStateEntry $State "VergeYaml") "VergeYaml"
    Assert-InstallStateEntry (Get-InstallStateEntry $State "ConfigYaml") "ConfigYaml"
}

function Assert-StateSnapshotUnchanged([object]$Entry, [object]$Snapshot, [string]$Label) {
    if ($null -eq $Entry) { return }
    $expected = [string]$Entry.InstalledSha256
    $actual = if ([bool]$Snapshot.Exists) { Get-BytesSha256 $Snapshot.Bytes } else { "" }
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
