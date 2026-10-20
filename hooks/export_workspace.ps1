[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)] [string]$ProjectRoot,
    [Parameter(Mandatory = $true)] [ValidateSet('recover', 'prepare', 'stage', 'publish')] [string]$Operation,
    [string]$Plan
)
$ErrorActionPreference = 'Stop'

# Defold discards captured output on a nonzero process exit. Communicate the
# outcome explicitly, while preserving process errors as a separate failure.
trap {
    Write-Output ('MVTK_EXPORT_ERROR=' + ($_.Exception.Message -replace '[\r\n]+', ' '))
    $global:LASTEXITCODE = 0
    exit 0
}

$root = [IO.Path]::GetFullPath($ProjectRoot).TrimEnd('\', '/')
if (-not $root -or $root -eq [IO.Path]::GetPathRoot($root).TrimEnd('\', '/')) {
    throw 'Refusing to use a filesystem root for export.'
}
if (-not (Test-Path -LiteralPath $root -PathType Container) -or
        -not (Test-Path -LiteralPath (Join-Path $root 'game.project') -PathType Leaf)) {
    throw 'Export workspace requires a project containing game.project.'
}
$prefix = $root + [IO.Path]::DirectorySeparatorChar
$build = [IO.Path]::GetFullPath((Join-Path $root '.build'))
$stage = [IO.Path]::GetFullPath((Join-Path $build 'export-stage'))
$previous = [IO.Path]::GetFullPath((Join-Path $build 'export-previous'))
$export = [IO.Path]::GetFullPath((Join-Path $root 'export'))

function Assert-Contained([string]$Path) {
    $absolute = [IO.Path]::GetFullPath($Path)
    if (-not $absolute.StartsWith($prefix, [StringComparison]::OrdinalIgnoreCase)) {
        throw "Export workspace escaped the project root: $absolute"
    }
}

function Assert-Directory([string]$Path, [bool]$InspectChildren = $true) {
    Assert-Contained $Path
    try { $item = Get-Item -LiteralPath $Path -Force } catch [Management.Automation.ItemNotFoundException] { return }
    if (-not $item.PSIsContainer) { throw "Export workspace path is not a directory: $Path" }
    if (($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
        throw "Export workspace cannot contain a junction or symbolic link: $Path"
    }
    if ($InspectChildren) {
        foreach ($child in Get-ChildItem -LiteralPath $Path -Recurse -Force) {
            Assert-Contained $child.FullName
            if (($child.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
                throw "Export workspace contains a junction or symbolic link: $($child.FullName)"
            }
        }
    }
}

function Remove-WorkspaceDirectory([string]$Path) {
    # Resolve and verify again immediately before recursive deletion.
    Assert-Directory $Path
    if (Test-Path -LiteralPath $Path) {
        Remove-Item -LiteralPath $Path -Recurse -Force
        if (Test-Path -LiteralPath $Path) { throw "Cannot delete export workspace directory: $Path" }
    }
}

function Move-WorkspaceDirectory([string]$Source, [string]$Destination) {
    Assert-Directory $Source
    Assert-Contained $Destination
    if (Test-Path -LiteralPath $Destination) { throw "Export rename destination already exists: $Destination" }
    # Directory.Move has no copy fallback: a failed rename retains its source.
    [IO.Directory]::Move($Source, $Destination)
    if ((Test-Path -LiteralPath $Source) -or
            -not (Test-Path -LiteralPath $Destination -PathType Container)) {
        throw "Export directory rename did not complete: $Source"
    }
}

function Restore-PreviousExport {
    if (Test-Path -LiteralPath $previous) {
        Assert-Directory $export
        if (Test-Path -LiteralPath $export) {
            Remove-WorkspaceDirectory $previous
        } else {
            Move-WorkspaceDirectory $previous $export
        }
    }
}

function Assert-StageContained([string]$Path) {
    Assert-Contained $Path
    $absolute = [IO.Path]::GetFullPath($Path)
    if (-not $absolute.StartsWith($stage + [IO.Path]::DirectorySeparatorChar, [StringComparison]::OrdinalIgnoreCase)) {
        throw "Export staging path escaped its directory: $absolute"
    }
}

function Assert-RelativePlanPath([string]$Path) {
    if (-not $Path -or $Path.StartsWith('/') -or $Path.Contains('\') -or
            $Path.Contains(':') -or $Path -match '[\x00-\x1f]') {
        throw "Invalid relative path in export plan: $Path"
    }
    foreach ($segment in $Path.Split('/')) {
        if (-not $segment -or $segment -eq '.' -or $segment -eq '..' -or
                $segment.EndsWith('.') -or $segment.EndsWith(' ')) {
            # Windows aliases trailing dots/spaces to another path. Reject them
            # before copying so duplicate-target checks refer to exact files.
            throw "Invalid path segment in export plan: $Path"
        }
    }
}

function Stage-ExportPlan {
    Assert-Directory $stage
    if (-not (Test-Path -LiteralPath $stage -PathType Container)) {
        throw 'Export staging is missing; prepare the workspace first.'
    }
    if (-not $Plan) { throw 'Export staging requires a regular plan file inside .build/.' }
    $planPath = [IO.Path]::GetFullPath($Plan)
    Assert-Contained $planPath
    if (-not $planPath.StartsWith($build + [IO.Path]::DirectorySeparatorChar, [StringComparison]::OrdinalIgnoreCase)) {
        throw 'Export plan must be inside .build/.'
    }
    if (-not (Test-Path -LiteralPath $planPath -PathType Leaf)) {
        throw 'Export staging requires a regular plan file inside .build/.'
    }
    # The lexical location is insufficient if a plan or its parent is a link.
    $cursor = $planPath
    while (-not $cursor.Equals($build, [StringComparison]::OrdinalIgnoreCase)) {
        $item = Get-Item -LiteralPath $cursor -Force
        if (($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
            throw "Export plan cannot contain a junction or symbolic link: $cursor"
        }
        $cursor = [IO.Path]::GetDirectoryName($cursor)
    }
    $encoding = New-Object Text.UTF8Encoding($false, $true)
    $text = [IO.File]::ReadAllText($planPath, $encoding)
    $lines = $text.Split([char]10)
    if ($lines.Count -eq 0 -or $lines[0] -cne 'MVTK_EXPORT_PLAN_1') { throw 'Invalid export plan header.' }
    $records = New-Object 'Collections.Generic.List[object]'
    $copies = New-Object 'Collections.Generic.HashSet[string]' ([StringComparer]::OrdinalIgnoreCase)
    $directories = New-Object 'Collections.Generic.HashSet[string]' ([StringComparer]::OrdinalIgnoreCase)
    for ($index = 1; $index -lt $lines.Count; $index++) {
        $line = $lines[$index]
        if ($index -eq $lines.Count - 1 -and $line -eq '') { continue }
        if ($line.Length -lt 3 -or $line[1] -ne [char]9 -or ($line[0] -cne 'D' -and $line[0] -cne 'C')) {
            throw 'Invalid export plan record.'
        }
        $kind = [string]$line[0]
        $relative = $line.Substring(2)
        Assert-RelativePlanPath $relative
        $destination = [IO.Path]::GetFullPath((Join-Path $stage $relative))
        Assert-StageContained $destination
        $source = [IO.Path]::GetFullPath((Join-Path $root $relative))
        Assert-Contained $source
        if ($kind -ceq 'C') {
            if (-not $copies.Add($destination)) { throw "Duplicate copy target in export plan: $relative" }
        } else {
            # CreateDirectory creates parents; include them in conflict and
            # missing-parent validation without writing any of them yet.
            $cursor = $destination
            while (-not $cursor.Equals($stage, [StringComparison]::OrdinalIgnoreCase)) {
                $directories.Add($cursor) | Out-Null
                $cursor = [IO.Path]::GetDirectoryName($cursor)
            }
        }
        $records.Add([PSCustomObject]@{Kind=$kind; Relative=$relative; Source=$source; Destination=$destination})
    }
    foreach ($directory in $directories) {
        if ($copies.Contains($directory)) { throw "A copy target is a directory in export plan: $directory" }
        if ((Test-Path -LiteralPath $directory) -and -not (Test-Path -LiteralPath $directory -PathType Container)) {
            throw "Export staging directory is a file: $directory"
        }
    }
    foreach ($record in $records) {
        if ($record.Kind -cne 'C') { continue }
        if (-not [IO.File]::Exists($record.Source)) {
            throw "Export source is not a regular file: $($record.Relative)"
        }
        if (Test-Path -LiteralPath $record.Destination) {
            throw "Export staging destination already exists: $($record.Relative)"
        }
        $cursor = [IO.Path]::GetDirectoryName($record.Destination)
        while (-not $cursor.Equals($stage, [StringComparison]::OrdinalIgnoreCase)) {
            if ($copies.Contains($cursor)) { throw "A copy target is a parent directory in export plan: $cursor" }
            if (-not $directories.Contains($cursor) -and -not (Test-Path -LiteralPath $cursor -PathType Container)) {
                throw "Export staging directory missing for $($record.Relative)"
            }
            $cursor = [IO.Path]::GetDirectoryName($cursor)
        }
    }
    # The entire input is now valid. Byte copies bypass Defold's per-file Lua
    # writer resource synchronization; publication still waits for read-back.
    foreach ($record in $records) {
        if ($record.Kind -ceq 'D') { [IO.Directory]::CreateDirectory($record.Destination) | Out-Null }
    }
    $copied = 0
    foreach ($record in $records) {
        if ($record.Kind -ceq 'C') {
            [IO.File]::Copy($record.Source, $record.Destination, $false)
            $copied++
        }
    }
    Write-Output "MVTK_EXPORT_STAGED=$copied"
}

Assert-Directory $build $false
Assert-Directory $previous

if ($Operation -eq 'recover') {
    Restore-PreviousExport
    Write-Output 'MVTK_EXPORT_RECOVERED=1'
} elseif ($Operation -eq 'prepare') {
    Assert-Directory $export
    Assert-Directory $stage
    [IO.Directory]::CreateDirectory($build) | Out-Null
    Restore-PreviousExport
    Remove-WorkspaceDirectory $stage
    [IO.Directory]::CreateDirectory($stage) | Out-Null
    Write-Output 'MVTK_EXPORT_READY=1'
} elseif ($Operation -eq 'stage') {
    Stage-ExportPlan
} else {
    Assert-Directory $export
    Assert-Directory $stage
    if (-not (Test-Path -LiteralPath $stage -PathType Container)) {
        throw 'Export staging is missing; prepare the workspace first.'
    }
    if (-not (Test-Path -LiteralPath (Join-Path $stage 'game.project') -PathType Leaf)) {
        throw 'Export staging has no game.project; the current export has been preserved.'
    }
    if (Test-Path -LiteralPath $previous) {
        throw 'A previous export needs recovery; prepare the workspace first.'
    }
    $hadExport = Test-Path -LiteralPath $export -PathType Container
    if ($hadExport) { Move-WorkspaceDirectory $export $previous }
    try {
        Move-WorkspaceDirectory $stage $export
    } catch {
        $publicationError = $_.Exception.Message
        if ($hadExport) {
            try { Move-WorkspaceDirectory $previous $export } catch {
                throw "Export publication failed: $publicationError. Recovery is pending in .build/export-previous: $($_.Exception.Message)"
            }
        }
        throw "Cannot publish export staging: $publicationError. The previous export has been restored."
    }
    if ($hadExport) {
        try { Remove-WorkspaceDirectory $previous } catch {
            Write-Output 'MVTK_EXPORT_WARNING=Export published; previous export cleanup will be retried next time.'
        }
    }
    Write-Output 'MVTK_EXPORT_PUBLISHED=1'
}
$global:LASTEXITCODE = 0
exit 0
