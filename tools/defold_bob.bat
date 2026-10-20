@echo off
setlocal EnableExtensions

if "%~1"=="" (
    echo Usage: %~nx0 [Bob arguments]
    echo Example: %~nx0 --variant debug resolve build bundle
    exit /b 1
)

set "PACKAGES_DIR="
if defined DEFOLD_PACKAGES_DIR if exist "%DEFOLD_PACKAGES_DIR%" set "PACKAGES_DIR=%DEFOLD_PACKAGES_DIR%"
if not defined PACKAGES_DIR if defined DEFOLD_HOME if exist "%DEFOLD_HOME%\packages" set "PACKAGES_DIR=%DEFOLD_HOME%\packages"
if not defined PACKAGES_DIR if exist "D:\SteamLibrary\steamapps\common\Defold\packages" set "PACKAGES_DIR=D:\SteamLibrary\steamapps\common\Defold\packages"
if not defined PACKAGES_DIR if exist "C:\Program Files\Defold\packages" set "PACKAGES_DIR=C:\Program Files\Defold\packages"

if not defined PACKAGES_DIR (
    echo Could not locate Defold packages directory.
    echo Set DEFOLD_PACKAGES_DIR or DEFOLD_HOME before running this script.
    exit /b 1
)

set "JAVA_EXE="
for /f "delims=" %%I in ('dir /b /ad /o:-d "%PACKAGES_DIR%\jdk-*" 2^>nul') do (
    if not defined JAVA_EXE if exist "%PACKAGES_DIR%\%%I\bin\java.exe" set "JAVA_EXE=%PACKAGES_DIR%\%%I\bin\java.exe"
)

if not defined JAVA_EXE (
    echo Could not locate a Defold-packaged JDK under "%PACKAGES_DIR%".
    exit /b 1
)

set "BOB_JAR="
for /f "delims=" %%I in ('dir /b /a:-d /o:-d "%PACKAGES_DIR%\defold-*.jar" 2^>nul') do (
    if not defined BOB_JAR set "BOB_JAR=%PACKAGES_DIR%\%%I"
)

if not defined BOB_JAR (
    echo Could not locate a Defold Bob jar under "%PACKAGES_DIR%".
    exit /b 1
)

"%JAVA_EXE%" -cp "%BOB_JAR%" com.dynamo.bob.Bob %*
exit /b %ERRORLEVEL%