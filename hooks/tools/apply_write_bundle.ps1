param(
    [Parameter(Mandatory=$true)][string]$ProjectRoot,
    [Parameter(Mandatory=$true)][string]$Bundle
)
$ErrorActionPreference = 'Stop'
$projectPath = [IO.Path]::GetFullPath($ProjectRoot)
$contentRoot = [IO.Path]::Combine($projectPath, 'developer')
$contentPrefix = $contentRoot.TrimEnd('\', '/') + [IO.Path]::DirectorySeparatorChar
$timer = [Diagnostics.Stopwatch]::StartNew()
$entries = [Collections.Generic.List[object]]::new()
$seen = @{}
# Headers alone are ASCII lines. Payloads are raw length-prefixed bytes; never
# pass them through a text reader (which changes encoding or line endings).
function Read-BundleHeader($reader) {
    $header = [Collections.Generic.List[byte]]::new()
    while ($true) {
        $byte = $reader.BaseStream.ReadByte()
        if ($byte -lt 0) { throw 'Truncated bundle header' }
        if ($byte -eq 10) { return [Text.Encoding]::ASCII.GetString($header.ToArray()) }
        if ($byte -gt 127 -or $header.Count -ge 128) { throw 'Invalid bundle header' }
        $header.Add([byte]$byte)
    }
}
$reader = [IO.BinaryReader]::new([IO.File]::OpenRead($Bundle))
$utf8 = [Text.UTF8Encoding]::new($false, $true)
try {
    if ((Read-BundleHeader $reader) -cne 'MVTK_WRITE_BUNDLE_2') { throw 'Invalid bundle version' }
    # Validate and decode the entire bundle before writing any target.
    while ($reader.BaseStream.Position -lt $reader.BaseStream.Length) {
        $header = Read-BundleHeader $reader
        if ($header -cnotmatch '^([0-9]+)\t([0-9]+)$') { throw 'Invalid bundle entry' }
        $pathLength = [int]::Parse($Matches[1])
        $dataLength = [int]::Parse($Matches[2])
        if ($pathLength -le 0 -or ([long]$pathLength + $dataLength) -gt
            ($reader.BaseStream.Length - $reader.BaseStream.Position)) { throw 'Truncated bundle entry' }
        $relative = $utf8.GetString($reader.ReadBytes($pathLength))
        if ($relative -cnotmatch '^developer/' -or $relative -match '(^|/)\.\.(/|$)|[:\\]' -or
            [IO.Path]::IsPathRooted($relative)) { throw "Invalid target: $relative" }
        $targetPath = [IO.Path]::GetFullPath([IO.Path]::Combine($projectPath, $relative))
        if (-not $targetPath.StartsWith($contentPrefix, [StringComparison]::OrdinalIgnoreCase)) { throw 'Target escaped developer' }
        if ($seen.ContainsKey($targetPath)) { throw 'Duplicate target' }
        $seen[$targetPath] = $true
        if (-not [IO.File]::Exists($targetPath)) { throw "Existing target required: $relative" }
        # Reject junction/symlink traversal, including a linked developer directory.
        $probe = $targetPath
        while ($probe.Length -ge $contentRoot.Length) {
            if (([IO.File]::GetAttributes($probe) -band [IO.FileAttributes]::ReparsePoint) -ne 0) { throw 'Linked target rejected' }
            $probe = [IO.Path]::GetDirectoryName($probe)
        }
        $bytes = $reader.ReadBytes($dataLength)
        if ($bytes.Length -ne $dataLength) { throw 'Truncated bundle payload' }
        $entries.Add(@{ Path=$targetPath; Bytes=$bytes })
    }
} finally {
    $reader.Dispose()
}
$validatedMs = $timer.ElapsedMilliseconds
foreach ($entry in $entries) { [IO.File]::WriteAllBytes($entry.Path, $entry.Bytes) }
Write-Output "[WRITE_BATCH] Helper validated $($entries.Count) files in $validatedMs ms; wrote them in $($timer.ElapsedMilliseconds - $validatedMs) ms."
