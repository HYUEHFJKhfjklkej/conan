@echo off
:: ============================================================
::  TeamCity stage driver — native Windows MSVC build of the grpc tree.
::  Non-interactive sibling of test-astra/test_x86_64.sh.
::  Wraps run_test_grpc.bat: Conan-version guard -> build -> verify 7 .nupkg.
::
::  Usage:
::     test_win.bat smoke    :: version/profile guard only (no build)
::     test_win.bat build    :: full build + verify (default)
::
::  Env:
::     PROFILE_NAME   default win-v143-x64  (also win-v142-x64, win-v142-x86)
::     EXPECT_CONAN   default 2.29.0 ; set to "any" to disable the guard.
::                    NOTE: packages\ still ships conan-2.27.1.tar.gz — bump it
::                    to 2.29.0 and re-run setup.bat, else this guard FAILS.
::
::  Artefacts: output\<pkg>.win.v1xx.shared.x64.<ver>.nupkg  (7 files)
:: ============================================================
setlocal ENABLEEXTENSIONS

set SCRIPT_DIR=%~dp0
set ROOT_DIR=%SCRIPT_DIR%..

set MODE=%1
if "%MODE%"=="" set MODE=build
if not "%MODE%"=="smoke" if not "%MODE%"=="build" (
    echo [FAIL] mode must be 'smoke' or 'build', got '%MODE%'
    endlocal & exit /b 2
)

if "%PROFILE_NAME%"=="" set PROFILE_NAME=win-v143-x64
if "%EXPECT_CONAN%"=="" set EXPECT_CONAN=2.29.0

if not exist "%ROOT_DIR%\profiles\%PROFILE_NAME%" (
    echo [FAIL] profile not found: %ROOT_DIR%\profiles\%PROFILE_NAME%
    endlocal & exit /b 2
)

if exist "%ROOT_DIR%\venv\Scripts\activate.bat" call "%ROOT_DIR%\venv\Scripts\activate.bat"

:: ----- Conan version guard (the "moved to new Conan" check) -----
set CVER=
for /f "tokens=3" %%v in ('conan --version 2^>nul') do set CVER=%%v
echo [INFO] Conan: %CVER%   (expect %EXPECT_CONAN%)   profile %PROFILE_NAME%
if /i not "%EXPECT_CONAN%"=="any" if not "%CVER%"=="%EXPECT_CONAN%" (
    echo [FAIL] Conan %CVER%, expected %EXPECT_CONAN%.
    echo        Bump packages\conan-2.27.1.tar.gz -^> conan-2.29.0.tar.gz and
    echo        re-run test-windows\setup.bat ^(confirm its deps resolve offline^).
    endlocal & exit /b 1
)

if "%MODE%"=="smoke" (
    echo [PASS] smoke OK ^(Conan %CVER%, profile %PROFILE_NAME%^)
    endlocal & exit /b 0
)

:: ----- full build (non-interactive; CI=1 skips run_test_grpc.bat pause) -----
set CI=1
call "%SCRIPT_DIR%run_test_grpc.bat"
set BUILDRC=%ERRORLEVEL%
if not "%BUILDRC%"=="0" (
    echo [FAIL] build failed, rc=%BUILDRC%
    endlocal & exit /b %BUILDRC%
)

:: ----- verify the 7 .nupkg artefacts -----
set /a COUNT=0
for %%P in (grpc protobuf abseil openssl re2 c-ares zlib) do (
    if exist "%ROOT_DIR%\output\%%P.win.*.nupkg" (
        echo [PASS] %%P
        set /a COUNT+=1
    ) else (
        echo [FAIL] %%P.win.*.nupkg missing
    )
)
echo [INFO] %COUNT%/7 packages present in output\
if not "%COUNT%"=="7" (
    endlocal & exit /b 1
)

echo ============================================
echo  WINDOWS grpc TREE OK  ^(profile %PROFILE_NAME%, Conan %CVER%^)
echo ============================================
endlocal & exit /b 0
