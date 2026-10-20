[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [string]$ProjectRoot,

    [Parameter(Mandatory = $true)]
    [string]$Source,

    [Parameter(Mandatory = $true)]
    [string]$Destination,

    [switch]$CopyOnly
)

$ErrorActionPreference = "Stop"

function Exit-ResetHelper {
    param([int]$Code = 0)
    # Defold throws away captured output whenever the launched process exits
    # non-zero. Never leak robocopy's bitmask as powershell.exe's exit code;
    # success/failure is communicated through the MVTK_RESET_* markers.
    $global:LASTEXITCODE = 0
    exit $Code
}

trap {
    $message = ($_.Exception.Message -replace '[\r\n]+', ' ')
    Write-Output "MVTK_RESET_ERROR=$message"
    Exit-ResetHelper 0
}

function Invoke-ResetRobocopy {
    param(
        [string]$From,
        [string]$To,
        [switch]$MoveFiles
    )

    # Launch through .NET instead of invoking robocopy directly. PowerShell's
    # native-command exit state can otherwise become powershell.exe's process
    # status in some hosts even after a handled robocopy warning.
    $arguments = @(
        '"' + $From + '"',
        '"' + $To + '"',
        '/E'
    )
    if ($MoveFiles) {
        $arguments += '/MOV'
    }
    $arguments += @('/R:0', '/W:0', '/MT:16', '/NFL', '/NDL', '/NJH', '/NJS', '/NC', '/NS', '/NP', '/XJ')

    $startInfo = New-Object System.Diagnostics.ProcessStartInfo
    $startInfo.FileName = 'robocopy.exe'
    $startInfo.Arguments = ($arguments -join ' ')
    $startInfo.UseShellExecute = $false
    $startInfo.CreateNoWindow = $true
    $startInfo.RedirectStandardOutput = $true
    $startInfo.RedirectStandardError = $true

    $process = New-Object System.Diagnostics.Process
    $process.StartInfo = $startInfo
    if (-not $process.Start()) {
        throw 'Could not start robocopy.exe.'
    }
    $stdout = $process.StandardOutput.ReadToEnd()
    $stderr = $process.StandardError.ReadToEnd()
    $process.WaitForExit()
    return @($process.ExitCode, $stdout, $stderr)
}

function Get-ResetSourceManifest {
    param([string]$RootPath)

    $scanErrors = @()
    $entries = @(Get-ChildItem -LiteralPath $RootPath -Recurse -Force `
        -ErrorAction SilentlyContinue -ErrorVariable +scanErrors)
    if ($scanErrors.Count -gt 0) {
        throw "Cannot enumerate reset source safely: $RootPath"
    }

    $manifest = @()
    $rootLength = $RootPath.TrimEnd('\', '/').Length
    foreach ($entry in $entries) {
        if (($entry.Attributes -band [System.IO.FileAttributes]::ReparsePoint) -ne 0) {
            throw "Reset source contains a junction or symbolic link that cannot be backed up safely: $($entry.FullName)"
        }
        if (-not $entry.PSIsContainer) {
            $manifest += [pscustomobject]@{
                RelativePath = $entry.FullName.Substring($rootLength).TrimStart('\', '/')
                Length = [long]$entry.Length
            }
        }
    }
    return $manifest
}

function Assert-ResetBackupManifest {
    param(
        [object[]]$Manifest,
        [string]$BackupRoot
    )

    foreach ($sourceFile in $Manifest) {
        $backupFile = Join-Path $BackupRoot $sourceFile.RelativePath
        if (-not (Test-Path -LiteralPath $backupFile -PathType Leaf)) {
            throw "Backup is missing file: $($sourceFile.RelativePath)"
        }
        if ([long](Get-Item -LiteralPath $backupFile).Length -ne [long]$sourceFile.Length) {
            throw "Backup size mismatch: $($sourceFile.RelativePath)"
        }
    }
}

$projectRootPath = [System.IO.Path]::GetFullPath($ProjectRoot).TrimEnd('\', '/')
$sourcePath = [System.IO.Path]::GetFullPath($Source)
$destinationPath = [System.IO.Path]::GetFullPath($Destination)
$projectPrefix = $projectRootPath + [System.IO.Path]::DirectorySeparatorChar
$sourcePrefix = $sourcePath.TrimEnd('\', '/') + [System.IO.Path]::DirectorySeparatorChar
$trashRoot = [System.IO.Path]::GetFullPath((Join-Path $projectRootPath 'developer\.trash')).TrimEnd('\', '/')
$trashPrefix = $trashRoot + [System.IO.Path]::DirectorySeparatorChar

if ($sourcePath.Equals($projectRootPath, [System.StringComparison]::OrdinalIgnoreCase)) {
    throw "Refusing to move the project root."
}
if (-not $sourcePath.StartsWith($projectPrefix, [System.StringComparison]::OrdinalIgnoreCase)) {
    throw "Reset source must be inside the project root."
}
if (-not $destinationPath.StartsWith($trashPrefix, [System.StringComparison]::OrdinalIgnoreCase)) {
    throw "Reset destination must be inside developer/.trash."
}
if ($sourcePath.Equals($destinationPath, [System.StringComparison]::OrdinalIgnoreCase)) {
    throw "Reset source and destination must differ."
}
if ($destinationPath.StartsWith($sourcePrefix, [System.StringComparison]::OrdinalIgnoreCase)) {
    throw "Reset destination must not be inside the source directory."
}
if (-not (Test-Path -LiteralPath $sourcePath -PathType Container)) {
    throw "Reset source directory does not exist: $sourcePath"
}
$sourceRootItem = Get-Item -LiteralPath $sourcePath -Force
if (($sourceRootItem.Attributes -band [System.IO.FileAttributes]::ReparsePoint) -ne 0) {
    throw "Reset source directory cannot be a junction or symbolic link: $sourcePath"
}

$timer = [System.Diagnostics.Stopwatch]::StartNew()
$destinationParent = [System.IO.Path]::GetDirectoryName($destinationPath)
if ($destinationParent) {
    [System.IO.Directory]::CreateDirectory($destinationParent) | Out-Null
}

$renameError = $null
if (-not $CopyOnly) {
    try {
        [System.IO.Directory]::Move($sourcePath, $destinationPath)
        $timer.Stop()
        Write-Output "MVTK_RESET_STRATEGY=rename"
        Write-Output "MVTK_RESET_ELAPSED_MS=$($timer.ElapsedMilliseconds)"
        Exit-ResetHelper 0
    }
    catch {
        $renameError = ($_.Exception.Message -replace '[\r\n]+', ' ')
    }
    Write-Output "MVTK_RESET_RENAME_ERROR=$renameError"
}

# Capture the exact files that must reach trash before any non-atomic copy or
# move. The manifest also rejects directory reparse points that robocopy /XJ
# would otherwise skip while still allowing the source to be deleted.
$sourceManifest = @(Get-ResetSourceManifest -RootPath $sourcePath)

# An empty watched directory is already in the desired reset state. Robocopy
# may not create a destination for it, so report success without invoking it.
if ($sourceManifest.Count -eq 0) {
    if ($CopyOnly -and -not (Test-Path -LiteralPath $destinationPath -PathType Container)) {
        [System.IO.Directory]::CreateDirectory($destinationPath) | Out-Null
    }
    $timer.Stop()
    Write-Output "MVTK_RESET_STRATEGY=$(if ($CopyOnly) { 'copy' } else { 'empty' })"
    Write-Output "MVTK_RESET_ELAPSED_MS=$($timer.ElapsedMilliseconds)"
    Exit-ResetHelper 0
}

if ($CopyOnly) {
    $copyResult = Invoke-ResetRobocopy -From $sourcePath -To $destinationPath
    $copyCode = [int]$copyResult[0]
    Write-Output "MVTK_RESET_COPY_CODE=$copyCode"
    if ($copyCode -ge 8) {
        $detail = (($copyResult[1] + ' ' + $copyResult[2]) -replace '[\r\n]+', ' ').Trim()
        throw "Backup copy failed with robocopy exit code $copyCode. $detail"
    }

    Assert-ResetBackupManifest -Manifest $sourceManifest -BackupRoot $destinationPath

    $timer.Stop()
    Write-Output "MVTK_RESET_STRATEGY=copy"
    Write-Output "MVTK_RESET_ELAPSED_MS=$($timer.ElapsedMilliseconds)"
    Exit-ResetHelper 0
}

# Move files but intentionally leave the directory tree in place. Defold keeps
# watched resource directories open, and robocopy can report code 8/9 solely
# because /MOVE could not delete those directories after moving every file.
$copyResult = Invoke-ResetRobocopy -From $sourcePath -To $destinationPath -MoveFiles
$copyCode = [int]$copyResult[0]
Write-Output "MVTK_RESET_COPY_CODE=$copyCode"

if (-not (Test-Path -LiteralPath $destinationPath -PathType Container)) {
    throw "Bulk move did not create the destination: $destinationPath"
}

# Robocopy's bitmask is useful diagnostic information, but the filesystem is
# authoritative. A move is recoverable only when every pre-move manifest entry
# exists in trash with the same size and no source file/reparse point remains.
$remainingManifest = @()
if (Test-Path -LiteralPath $sourcePath -PathType Container) {
    $remainingManifest = @(Get-ResetSourceManifest -RootPath $sourcePath)
}
if ($remainingManifest.Count -gt 0) {
    throw "Bulk move left $($remainingManifest.Count) source file(s) behind after robocopy exit code $copyCode."
}
Assert-ResetBackupManifest -Manifest $sourceManifest -BackupRoot $destinationPath
if ($copyCode -ge 8) {
    Write-Output "MVTK_RESET_COPY_WARNING=robocopy returned $copyCode, but verification confirmed that all source files moved"
}

$timer.Stop()
Write-Output "MVTK_RESET_STRATEGY=bulk"
Write-Output "MVTK_RESET_ELAPSED_MS=$($timer.ElapsedMilliseconds)"
Exit-ResetHelper 0
