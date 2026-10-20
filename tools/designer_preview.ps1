# Build a disposable real-engine preview. All writes are inside the new job.
[CmdletBinding()]
param([Parameter(Mandatory=$true)][ValidatePattern('^\d+_\d+$')][string]$JobId,
      [switch]$StageOnly, [switch]$BuildOnly)
$ErrorActionPreference='Stop'
$repo=[IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..'))
$jobs=[IO.Path]::GetFullPath((Join-Path $repo '.build/designer-preview'))
$job=[IO.Path]::GetFullPath((Join-Path $jobs $JobId))
if (-not $job.StartsWith($jobs+[IO.Path]::DirectorySeparatorChar,[StringComparison]::OrdinalIgnoreCase)) { throw 'Preview path escaped workspace' }
$project=Join-Path $job 'project'
function Status([string]$message) { [IO.File]::WriteAllText((Join-Path $job 'status.txt'),$message) }
try {
    if (-not (Test-Path -LiteralPath (Join-Path $job 'request.lua'))) { throw 'Preview request is missing' }
    if (Test-Path -LiteralPath $project) { throw 'This preview job was already staged. Launch a new preview.' }
    Status 'Copying project for isolated preview...'
    New-Item -ItemType Directory -Path $project | Out-Null
    foreach ($dir in @('developer','mvtk','hooks','renderer','tools','tiled')) {
        Copy-Item -LiteralPath (Join-Path $repo $dir) -Destination $project -Recurse
    }
    foreach ($relative in @('developer/.wizard','developer/.trash')) {
        $scratch=[IO.Path]::GetFullPath((Join-Path $project $relative))
        if (-not $scratch.StartsWith($project+[IO.Path]::DirectorySeparatorChar,[StringComparison]::OrdinalIgnoreCase)) { throw 'Scratch cleanup escaped preview' }
        if (Test-Path -LiteralPath $scratch) { Remove-Item -LiteralPath $scratch -Recurse -Force }
    }
    foreach ($file in @('game.project','.defignore','hooks.editor_script')) {
        Copy-Item -LiteralPath (Join-Path $repo $file) -Destination $project
    }
    # Reuse dependency archives, never engine outputs or authoring caches.
    if (Test-Path -LiteralPath (Join-Path $repo '.internal/lib')) {
        New-Item -ItemType Directory -Path (Join-Path $project '.internal') -Force | Out-Null
        Copy-Item -LiteralPath (Join-Path $repo '.internal/lib') -Destination (Join-Path $project '.internal') -Recurse
    }
    [IO.File]::WriteAllText((Join-Path $project '.designer-preview'),$JobId)
    [IO.File]::WriteAllText((Join-Path $project 'hooks/project_path.txt'),$project.Replace('\','/'))
    Copy-Item -LiteralPath (Join-Path $job 'request.lua') -Destination (Join-Path $project 'preview_request.lua')
    Push-Location $project
    try {
        Status 'Applying draft and rebuilding player geometry...'
        & lua tools/stage_designer_preview.lua *> (Join-Path $job 'stage.log')
        if ($LASTEXITCODE -ne 0) { throw 'Preview staging failed; read stage.log' }
        # Course staging marks copied room sources that should be removed. Paths
        # are fixed here, resolved and checked, and are never live project paths.
        if (Test-Path -LiteralPath '.preview-course') {
            foreach ($relative in @('developer/assets/tiled/maps','developer/rooms/collections','developer/rooms/factories','developer/rooms/generated')) {
                $target=[IO.Path]::GetFullPath((Join-Path $project $relative))
                if (-not $target.StartsWith($project+[IO.Path]::DirectorySeparatorChar,[StringComparison]::OrdinalIgnoreCase)) { throw 'Cleanup escaped preview' }
                Get-ChildItem -LiteralPath $target -File -ErrorAction SilentlyContinue | Where-Object { $_.Name -notlike '_*' } | ForEach-Object { Remove-Item -LiteralPath $_.FullName -Force }
            }
            & lua tools/stage_designer_preview.lua --course *> (Join-Path $job 'course.log')
            if ($LASTEXITCODE -ne 0) { throw 'Course creation failed; read course.log' }
        }
        & lua tools/generate_rooms.lua *> (Join-Path $job 'generation.log')
        if ($LASTEXITCODE -ne 0) { throw 'Room generation failed; read generation.log' }
        if ($StageOnly) { Status 'Staged successfully; native build was not requested.'; return }
        Status 'Building preview with Defold (first build may take several minutes)...'
        & tools/defold_bob.bat --variant debug resolve build *> (Join-Path $job 'build.log')
        if ($LASTEXITCODE -ne 0) { throw 'Defold build failed; read build.log' }
        if ($BuildOnly) { Status 'Preview built successfully.'; return }
        Status 'Preview running. Close its window to return to your unchanged Game Settings draft.'
        # Visible window is intentional: this is the interactive game preview.
        $engine=Join-Path $project 'build/x86_64-win32/dmengine.exe'
        if (-not (Test-Path -LiteralPath $engine)) { throw 'Built engine not found' }
        Start-Process -FilePath $engine -WorkingDirectory $project -Wait
        Status 'Preview closed. Draft retained; launch again to test new changes.'
    } finally { Pop-Location }
} catch {
    if (Test-Path -LiteralPath $job) { Status ('Preview failed: '+$_.Exception.Message) }
    Write-Error $_
    exit 1
}
