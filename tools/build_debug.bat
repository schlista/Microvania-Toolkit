@echo off
setlocal EnableExtensions

cd /d "%~dp0.."
if errorlevel 1 (
    echo Failed to switch to the project directory.
    exit /b 1
)

set "LAUNCH_MODE=%~1"
if not defined LAUNCH_MODE set "LAUNCH_MODE=start"

echo Building Defold project...

call "%~dp0prepare_build_assets.bat"
if errorlevel 1 exit /b %ERRORLEVEL%

set "RESOLVE_HASH=.build\.resolve_hash"
set "HASH_TMP=%TEMP%\gp_hash_%RANDOM%_%RANDOM%.tmp"

if not exist ".build" mkdir ".build"
if errorlevel 1 (
    echo Failed to create .build directory.
    exit /b 1
)

set "NEED_RESOLVE=0"
if not exist "%RESOLVE_HASH%" set "NEED_RESOLVE=1"
if "%NEED_RESOLVE%"=="0" (
    certutil -hashfile game.project MD5 2>nul | findstr /v ":" > "%HASH_TMP%"
    fc /b "%RESOLVE_HASH%" "%HASH_TMP%" >nul 2>&1
    if errorlevel 1 set "NEED_RESOLVE=1"
)

if "%NEED_RESOLVE%"=="1" (
    echo Resolving dependencies...
    call "%~dp0defold_bob.bat" --variant debug resolve
    if errorlevel 1 goto :resolve_failed
    certutil -hashfile game.project MD5 2>nul | findstr /v ":" > "%RESOLVE_HASH%"
    echo Dependencies resolved.
) else (
    echo Dependencies up to date, skipping resolve.
)

lua tools/prepare_project.lua --begin-build
if errorlevel 1 exit /b %ERRORLEVEL%
call "%~dp0defold_bob.bat" --variant debug build
set "BUILD_RESULT=%ERRORLEVEL%"

if exist "%HASH_TMP%" del "%HASH_TMP%" >nul 2>&1

if not "%BUILD_RESULT%"=="0" (
    echo Build failed.
    exit /b %BUILD_RESULT%
)

lua tools/prepare_project.lua --record-build
if errorlevel 1 exit /b %ERRORLEVEL%

if /I "%LAUNCH_MODE%"=="build" (
    echo Build successful.
    exit /b 0
)

if /I "%LAUNCH_MODE%"=="console" (
    echo Build successful! Launching game with console output...
    echo.
    echo ========== GAME OUTPUT ==========
    echo.
    ".\build\x86_64-win32\dmengine.exe"
    exit /b %ERRORLEVEL%
)

echo Build successful! Launching game...
start "" ".\build\x86_64-win32\dmengine.exe"
exit /b 0

:resolve_failed
echo Resolve failed.
if exist "%HASH_TMP%" del "%HASH_TMP%" >nul 2>&1
exit /b 1
