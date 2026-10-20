@echo off
REM tools\set_tiled_export_path.bat
REM
REM Configures THIS extracted toolkit folder so the Tiled "Export Lua + Defold
REM Tilemap" action writes into it and the File-menu items load without Tiled's
REM per-project "Enable Extensions" prompt. Optional: Defold's Project > Set Up
REM This Toolkit is the normal setup.
REM
REM All of the work is done by installer\setup_paths.ps1 (the single source of
REM truth for per-machine path setup): it writes
REM tiled\extensions\export_path.txt, hooks\project_path.txt, installs the Tiled
REM extensions into %LOCALAPPDATA%\Tiled\extensions, and writes
REM WHERE_THINGS_ARE.txt. Run this once, from the toolkit folder.

setlocal

REM Resolve repo root = parent of the tools\ folder this script lives in.
set "SCRIPT_DIR=%~dp0"
pushd "%SCRIPT_DIR%\.." >nul
set "REPO_ROOT=%CD%"
popd >nul

if not exist "%REPO_ROOT%\tiled\extensions" (
    echo [set-export-path] ERROR: tiled\extensions folder not found under %REPO_ROOT%
    echo [set-export-path] Run this script from inside the extracted toolkit folder.
    exit /b 1
)
if not exist "%REPO_ROOT%\installer\setup_paths.ps1" (
    echo [set-export-path] ERROR: installer\setup_paths.ps1 not found under %REPO_ROOT%
    echo [set-export-path] This does not look like a complete toolkit folder.
    exit /b 1
)

powershell -NoProfile -ExecutionPolicy Bypass -File "%REPO_ROOT%\installer\setup_paths.ps1" -InstallDir "%REPO_ROOT%"

echo.
echo Now restart Tiled (close it and reopen MVTK.tiled-project) so the
echo extension picks up the new path.

endlocal
