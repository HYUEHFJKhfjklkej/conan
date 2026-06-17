@echo off
:: ============================================================
::  Драйвер TeamCity-стадии — нативная сборка дерева grpc на Windows MSVC.
::  Неинтерактивный аналог test-astra/test_x86_64.sh.
::  Обёртка над run_test_grpc.bat: guard версии Conan -> сборка -> проверка 7 .nupkg.
::
::  Usage:
::     test_win.bat smoke    :: только guard версии/профиля (без сборки)
::     test_win.bat build    :: полная сборка + проверка (по умолчанию)
::
::  Env:
::     PROFILE_NAME   по умолчанию win-v143-x64 (ещё win-v142-x64, win-v142-x86)
::     EXPECT_CONAN   по умолчанию 2.29.0 ; "any" отключает guard.
::                    packages\ содержит conan-2.29.0.tar.gz; setup.bat ставит
::                    его через pip --upgrade, чтобы агент был на 2.29.0.
::
::  Артефакты: output\<pkg>.win.v1xx.shared.x64.<ver>.nupkg  (7 файлов)
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

:: ----- guard версии Conan (проверка "перешли на новый Conan") -----
set CVER=
for /f "tokens=3" %%v in ('conan --version 2^>nul') do set CVER=%%v
echo [INFO] Conan: %CVER%   (expect %EXPECT_CONAN%)   profile %PROFILE_NAME%
if /i not "%EXPECT_CONAN%"=="any" if not "%CVER%"=="%EXPECT_CONAN%" (
    echo [FAIL] Conan %CVER%, expected %EXPECT_CONAN%.
    echo        Run test-windows\setup.bat ^(installs --upgrade from packages\,
    echo        which now ships conan-2.29.0.tar.gz^).
    endlocal & exit /b 1
)

if "%MODE%"=="smoke" (
    echo [PASS] smoke OK ^(Conan %CVER%, profile %PROFILE_NAME%^)
    endlocal & exit /b 0
)

:: ----- полная сборка (неинтерактивно; CI=1 убирает pause в run_test_grpc.bat) -----
set CI=1
call "%SCRIPT_DIR%run_test_grpc.bat"
set BUILDRC=%ERRORLEVEL%
if not "%BUILDRC%"=="0" (
    echo [FAIL] build failed, rc=%BUILDRC%
    endlocal & exit /b %BUILDRC%
)

:: ----- проверка 7 артефактов .nupkg -----
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
