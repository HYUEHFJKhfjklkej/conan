@echo off
:: ============================================================
::  TeamCity Windows agent readiness check for the grpc 1.60.1 Conan build.
::  Reports [ OK ] / [WARN] / [FAIL] per prerequisite and exits with the
::  number of REQUIRED items missing (0 = ready to run run_grpc_1601_win.bat).
::
::  Run from cmd.exe on the agent:   test-windows\check_agent.bat
::  Nothing is installed/changed — read-only check.
:: ============================================================
setlocal ENABLEEXTENSIONS ENABLEDELAYEDEXPANSION

set "SCRIPT_DIR=%~dp0"
set "ROOT_DIR=%SCRIPT_DIR%.."
set /a FAILS=0
set /a WARNS=0
set "VSWHERE=%ProgramFiles(x86)%\Microsoft Visual Studio\Installer\vswhere.exe"

echo ============================================
echo  Windows agent readiness check
echo  (grpc 1.60.1 Conan build prerequisites)
echo  repo: %ROOT_DIR%
echo ============================================
echo.

:: ---------- Python 3.14 (REQUIRED: offline Conan bootstrap) ----------
where python >nul 2>&1
if errorlevel 1 (
    call :fail "Python" "not found - install Python 3.14.x and tick 'Add to PATH'"
    goto :after_py
)
set "PYVER="
for /f "tokens=2" %%v in ('python --version 2^>^&1') do set "PYVER=%%v"
echo !PYVER!| findstr /b /l "3.14" >nul && (call :ok "Python" "!PYVER!") || (call :warn "Python" "found !PYVER! - offline wheels are cp314, need 3.14.x")
:after_py

:: ---------- MSVC v143 (REQUIRED: C++ compiler) ----------
if not exist "%VSWHERE%" (
    call :fail "MSVC C++" "vswhere not found - install VS2022 Build Tools 'Desktop development with C++'"
    goto :after_msvc
)
set "VSPATH="
for /f "usebackq delims=" %%i in (`"%VSWHERE%" -products * -requires Microsoft.VisualStudio.Component.VC.Tools.x86.x64 -property installationPath`) do set "VSPATH=%%i"
if defined VSPATH (call :ok "MSVC C++" "!VSPATH!") else (call :fail "MSVC C++" "no VC++ tools - add 'Desktop development with C++' to VS2022")
:after_msvc

:: ---------- CMake 3.25+ (REQUIRED) ----------
where cmake >nul 2>&1
if errorlevel 1 (
    call :fail "CMake" "not found - install CMake 3.25+ on PATH"
) else (
    set "CMVER="
    for /f "tokens=3" %%v in ('cmake --version 2^>^&1 ^| findstr /i /b /c:"cmake version"') do set "CMVER=%%v"
    call :ok "CMake" "!CMVER!"
)

:: ---------- Perl (REQUIRED: openssl Configure) ----------
set "PERLAT="
where perl >nul 2>&1 && set "PERLAT=PATH"
if not defined PERLAT if exist "C:\Strawberry\perl\bin\perl.exe" set "PERLAT=C:\Strawberry"
if not defined PERLAT if exist "%ROOT_DIR%\tools\windows\strawberryperl\perl\bin\perl.exe" set "PERLAT=tools\windows\strawberryperl"
if defined PERLAT (call :ok "Perl" "!PERLAT!") else (call :fail "Perl" "not found - Strawberry Perl at C:\Strawberry or tools\windows\strawberryperl\")

:: ---------- NASM (REQUIRED: openssl asm) ----------
set "NASMAT="
where nasm >nul 2>&1 && set "NASMAT=PATH"
if not defined NASMAT if exist "C:\Program Files\NASM\nasm.exe" set "NASMAT=C:\Program Files\NASM"
if not defined NASMAT if exist "%ROOT_DIR%\tools\windows\nasm\nasm.exe" set "NASMAT=tools\windows\nasm"
if defined NASMAT (call :ok "NASM" "!NASMAT!") else (call :fail "NASM" "not found - nasm.exe at C:\Program Files\NASM or tools\windows\nasm\")

:: ---------- Git (REQUIRED: TeamCity VCS checkout) ----------
where git >nul 2>&1
if errorlevel 1 (
    call :fail "Git" "not found - needed for TeamCity source checkout"
) else (
    set "GITVER="
    for /f "tokens=3" %%v in ('git --version 2^>^&1') do set "GITVER=%%v"
    call :ok "Git" "!GITVER!"
)

:: ---------- Offline Conan source in packages\ (REQUIRED) ----------
if exist "%ROOT_DIR%\packages\conan-2.29.0.tar.gz" (
    call :ok "packages offline conan" "conan-2.29.0.tar.gz present"
) else (
    call :fail "packages offline conan" "conan-2.29.0.tar.gz missing - git pull the repo"
)

:: ---------- Conan (optional: driver bootstraps it) ----------
where conan >nul 2>&1
if errorlevel 1 (
    call :warn "Conan" "not on PATH - run_grpc_1601_win.bat installs it offline from packages\ (needs Python)"
) else (
    set "CNVER="
    for /f "tokens=3" %%v in ('conan --version 2^>^&1') do set "CNVER=%%v"
    call :ok "Conan" "!CNVER!"
)

:: ---------- TeamCity agent (informational) ----------
if exist "C:\BuildAgent\conf\buildAgent.properties" (
    call :ok "TeamCity agent" "C:\BuildAgent present"
) else (
    call :warn "TeamCity agent" "C:\BuildAgent not found - check the agent install path on this host"
)

echo.
echo ============================================
if %FAILS%==0 (
    echo  RESULT: READY  -  0 required missing, %WARNS% warning^(s^)
    echo  Next:   test-windows\run_grpc_1601_win.bat
) else (
    echo  RESULT: NOT READY  -  %FAILS% required missing, %WARNS% warning^(s^)
    echo  Install the [FAIL] items above, then re-run this check.
)
echo ============================================

if not defined CI if not defined TEAMCITY_VERSION pause
endlocal & exit /b %FAILS%

:: ----- helpers -----
:ok
echo [ OK ] %~1: %~2
exit /b 0
:warn
echo [WARN] %~1: %~2
set /a WARNS+=1
exit /b 0
:fail
echo [FAIL] %~1: %~2
set /a FAILS+=1
exit /b 0
