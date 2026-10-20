# Read-only filesystem inventory shared by the Spine editor command and CLI.
# Keep traversal in a plain script so its exact actions can be inspected.
[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)][string]$Root,
    [switch]$Utf8
)

$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'
# Desktop Lua's Windows file APIs use the process code page for paths.
[Console]::OutputEncoding = if ($Utf8) { [Text.UTF8Encoding]::new($false) } else { [Text.Encoding]::Default }

try {
    $base = [IO.Path]::GetFullPath($Root).TrimEnd('\', '/')
    if (-not [IO.Directory]::Exists($base)) { throw "Project directory does not exist: $base" }
    $ignored = @()
    $ignoreFile = Join-Path $base '.defignore'
    if (Test-Path -LiteralPath $ignoreFile -PathType Leaf) {
        foreach ($line in [IO.File]::ReadAllLines($ignoreFile)) {
            $line = $line.Trim()
            if ($line.StartsWith('/')) {
                # Match Defold's path-segment rules; '*' and '?' never cross
                # '/', while '**' includes zero whole folders.
                $pattern = '^'
                $parts = $line.Substring(1).TrimEnd('/').Split('/')
                foreach ($part in $parts) {
                    if ($part -ceq '**') { $pattern += '(/[^/]+)*' }
                    else { $pattern += '/' + [regex]::Escape($part).Replace('\*', '[^/]*').Replace('\?', '[^/]') }
                }
                $ignored += $pattern + '(/|$)'
            }
        }
    }
    $pending = [Collections.Generic.Stack[string]]::new()
    $pending.Push($base)
    while ($pending.Count -gt 0) {
        $directory = $pending.Pop()
        $relative = $directory.Substring($base.Length).TrimStart('\', '/').Replace('\', '/')
        [Console]::WriteLine('D' + [char]9 + $relative)
        foreach ($item in Get-ChildItem -LiteralPath $directory -Force -ErrorAction Stop) {
            $path = $item.FullName.Substring($base.Length).TrimStart('\', '/').Replace('\', '/')
            $skip = $false
            foreach ($pattern in $ignored) {
                if (('/' + $path) -cmatch $pattern) { $skip = $true; break }
            }
            if ($skip) { [Console]::WriteLine('I' + [char]9 + $path); continue }
            if ($item.PSIsContainer) {
                if ($item.Name.StartsWith('.') -or $item.Name -eq '__pycache__' -or
                    $path -match '^(test|tests|build|dist|export)(/|$)' -or
                    $path -eq 'developer/addons/spine') {
                    [Console]::WriteLine('I' + [char]9 + $path)
                    continue
                }
                if (($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
                    throw "Cannot scan linked directory: $path"
                }
                $pending.Push($item.FullName)
            } else {
                if (($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
                    throw "Cannot scan linked resource: $path"
                }
                [Console]::WriteLine('F' + [char]9 + $path)
            }
        }
    }
    [Console]::WriteLine('MVTK_SPINE_SCAN_OK')
} catch {
    [Console]::WriteLine($_.Exception.Message)
    exit 1
}

