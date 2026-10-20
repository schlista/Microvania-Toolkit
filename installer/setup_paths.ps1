<#
    installer/setup_paths.ps1

    Single source of truth for the toolkit's per-machine path setup. This is the
    only place that writes the export/project path overrides, installs the Tiled
    menu extensions globally, and writes WHERE_THINGS_ARE.txt.

    It is called by tools/set_tiled_export_path.bat (running in place). The
    Windows installer and INSTALL.bat that also called it are retired; Defold's
    Project > Set Up This Toolkit is the normal setup.

    Resilience: every step runs independently in its own try/catch. A single
    failing step (e.g. the global-extensions copy while Tiled holds a file open)
    records a warning and CONTINUES, instead of aborting the rest of setup and
    leaving the install half-configured. A human-readable result is written to
    <InstallDir>\post_install_log.txt and echoed to the console.

    This script intentionally does NOT regenerate the HTML/PDF guides: those are
    generated at packaging time and shipped, and regenerating them requires
    Python, which a creator's machine usually lacks. Trying was pure added
    failure surface.
#>
param(
    [Parameter(Mandatory = $true)]
    [string]$InstallDir
)

# Never let a single non-terminating error abort the whole script; each step
# decides its own success below.
$ErrorActionPreference = 'Continue'

$script:Results = New-Object System.Collections.Generic.List[string]
$script:Failures = 0

function Add-Result([string]$status, [string]$message) {
    $line = "[{0}] {1}" -f $status, $message
    $script:Results.Add($line) | Out-Null
    if ($status -eq 'FAIL') { $script:Failures++ }
    Write-Host "  $line"
}

function Invoke-Step([string]$name, [scriptblock]$body) {
    try {
        & $body
        Add-Result 'OK' $name
    } catch {
        Add-Result 'FAIL' ("{0}: {1}" -f $name, $_.Exception.Message)
    }
}

function Convert-ToForwardSlash([string]$Path) {
    return ($Path -replace '\\', '/')
}

function Write-Utf8NoBom([string]$Path, [string[]]$Lines) {
    $dir = Split-Path -Parent $Path
    if ($dir -and -not (Test-Path -LiteralPath $dir)) {
        New-Item -ItemType Directory -Path $dir -Force | Out-Null
    }
    $encoding = New-Object System.Text.UTF8Encoding($false)
    [System.IO.File]::WriteAllLines($Path, $Lines, $encoding)
}

function Write-ExportPathFile([string]$Path, [string]$InstallPathForward) {
    Write-Utf8NoBom $Path @(
        '# MV Toolkit - Tiled export path override (written by setup_paths.ps1)'
        '# Delete or blank this file to fall back to auto-detect.'
        $InstallPathForward
    )
}

# --- Resolve the install root -------------------------------------------------
if (-not (Test-Path -LiteralPath $InstallDir)) {
    Write-Host "[setup_paths] ERROR: install dir does not exist: $InstallDir"
    exit 1
}
$root = (Resolve-Path -LiteralPath $InstallDir).Path.TrimEnd('\')
$rootForward = Convert-ToForwardSlash $root
$globalExtensions = Join-Path $env:LOCALAPPDATA 'Tiled\extensions'

Write-Host "[setup_paths] Configuring toolkit at: $root"

# --- Step 1: project-local Tiled export path override -------------------------
Invoke-Step 'Tiled export path (project copy)' {
    Write-ExportPathFile (Join-Path $root 'tiled\extensions\export_path.txt') $rootForward
}

# --- Step 2: Defold project root override ------------------------------------
Invoke-Step 'Defold project path (hooks\project_path.txt)' {
    Write-Utf8NoBom (Join-Path $root 'hooks\project_path.txt') @($rootForward)
}

# --- Step 3: install Tiled menu extensions globally --------------------------
Invoke-Step 'Global Tiled extensions folder' {
    New-Item -ItemType Directory -Path $globalExtensions -Force | Out-Null
}
foreach ($extensionName in @(
    'export_lua_and_defold.js',
    'export_tiled_world.js',
    'content_relationships.js',
    'grouped_property_schema.js',
    'new_room_blank.js',
    'world_setup.js'
)) {
    # Do not call this loop variable `$name`: Invoke-Step also has a `$name`
    # parameter and PowerShell's dynamically scoped scriptblocks would then see
    # the step label ("Global Tiled extension: ...") instead of the filename.
    Invoke-Step ("Global Tiled extension: {0}" -f $extensionName) {
        $src = Join-Path $root ("tiled\extensions\{0}" -f $extensionName)
        $dst = Join-Path $globalExtensions $extensionName
        if (-not (Test-Path -LiteralPath $src)) {
            throw "missing source $src"
        }
        Copy-Item -LiteralPath $src -Destination $dst -Force -ErrorAction Stop
        if (-not (Test-Path -LiteralPath $dst -PathType Leaf)) {
            throw "copy did not create destination $dst"
        }
        $sourceHash = (Get-FileHash -LiteralPath $src -Algorithm SHA256 -ErrorAction Stop).Hash
        $destinationHash = (Get-FileHash -LiteralPath $dst -Algorithm SHA256 -ErrorAction Stop).Hash
        if ($sourceHash -ne $destinationHash) {
            throw "copied extension content does not match source: $dst"
        }
    }
}
Invoke-Step 'Tiled export path (global copy)' {
    Write-ExportPathFile (Join-Path $globalExtensions 'export_path.txt') $rootForward
}
Invoke-Step 'Remove retired Tiled grouped-property upgrade' {
    # An in-place toolkit update can leave the retired project copy as well.
    foreach ($retiredExtension in @(
        (Join-Path $globalExtensions 'upgrade_grouped_properties.js'),
        (Join-Path $root 'tiled\extensions\upgrade_grouped_properties.js')
    )) {
        if (Test-Path -LiteralPath $retiredExtension) {
            Remove-Item -LiteralPath $retiredExtension -Force -ErrorAction Stop
        }
    }
}

# --- Step 4: WHERE_THINGS_ARE.txt --------------------------------------------
Invoke-Step 'WHERE_THINGS_ARE.txt' {
    Write-Utf8NoBom (Join-Path $root 'WHERE_THINGS_ARE.txt') @(
        '================================================================================'
        '  MICROVANIA TOOLKIT - WHERE THINGS ARE'
        '================================================================================'
        ''
        'This toolkit is installed at:'
        ''
        "    $root"
        ''
        '--------------------------------------------------------------------------------'
        '  OPEN THESE TWO FILES FIRST'
        '--------------------------------------------------------------------------------'
        ''
        '  In Defold (Open Project):'
        "      $root\game.project"
        ''
        '  In Tiled (Open File or Project):'
        "      $root\MVTK.tiled-project"
        ''
        '  The Tiled extensions were also installed globally here:'
        "      $globalExtensions"
        ''
        '--------------------------------------------------------------------------------'
        '  WHERE YOUR WORK GOES'
        '--------------------------------------------------------------------------------'
        ''
        '  Tiled room exports:'
        "      $root\developer\assets\tiled\maps"
        ''
        '  Your tilesets (.tsx) and tilesheet images:'
        "      $root\developer\assets\tiled\tilesets   (.tsx)"
        "      $root\developer\assets\tilesheets        (.png/.jpg)"
        ''
        '  Game settings saved by Project > Game Settings...:'
        "      $root\developer\config"
        ''
        '  Generated rooms (after Project > Create Rooms):'
        "      $root\developer\rooms\collections"
        "      $root\developer\rooms\factories"
        "      $root\developer\rooms\generated"
        "      $root\developer\config\rooms_config.lua"
        ''
        '  Recoverable cleanup backups (safe to delete to reclaim space):'
        "      $root\developer\.trash"
        ''
        '--------------------------------------------------------------------------------'
        '  GUIDES'
        '--------------------------------------------------------------------------------'
        ''
        "  Complete creator guide: $root\docs\CREATOR_WORKFLOW.html"
        "  Template property guide: $root\tiled\templates\README.html"
        ''
        '================================================================================'
    )
}

# --- Write a visible result log ----------------------------------------------
$logHeader = @(
    "Microvania Toolkit - path setup log"
    "when:    $((Get-Date).ToString('yyyy-MM-dd HH:mm:ss'))"
    "install: $root"
    "tiled global extensions: $globalExtensions"
    ""
)
$logBody = @()
foreach ($r in $script:Results) { $logBody += $r }
$logFooter = @(
    ""
    $(if ($script:Failures -eq 0) {
        "RESULT: all steps OK."
    } else {
        "RESULT: $($script:Failures) step(s) failed. Close Tiled, then run tools\set_tiled_export_path.bat again."
    })
)
try {
    Write-Utf8NoBom (Join-Path $root 'post_install_log.txt') ($logHeader + $logBody + $logFooter)
} catch {
    Write-Host "[setup_paths] WARN: could not write post_install_log.txt: $($_.Exception.Message)"
}

if ($script:Failures -eq 0) {
    Write-Host "[setup_paths] Path setup complete for $root"
} else {
    Write-Host "[setup_paths] Path setup finished with $($script:Failures) failure(s); see post_install_log.txt"
}

# Always exit 0: partial setup is logged, and the caller's remaining steps
# (shortcuts, prompts) should still run. The log carries the real status.
exit 0
