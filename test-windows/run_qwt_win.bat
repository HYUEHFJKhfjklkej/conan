@echo off
:: ============================================================
::  Сборка пакета qwt/6.2.0 на Windows MSVC (одиночный пакет).
::  Нативный аналог test-astra/build_qwt_nodocker.sh — на Windows без
::  Docker, собирает прямо на агенте через MSVC. qwt — вне grpc-дерева,
::  без conan-deps, НО требует Qt на агенте: env QT5_ROOT_DIR = корень
::  Qt-инсталляции (рецепт сам найдёт тулчейн-подкаталог msvc*_64 c
::  lib\cmake). qmake НЕ используется (commercial-Qt licheck, HELP [32]) —
::  сборка CMake-графтом, find_package лицензию не проверяет.
::
::  export -> build Release+Debug -> deployer -> qwt.win.*.nupkg
::  в output-qwt-win\.
::
::  Требуется на агенте: MSVC-toolset под профиль + Conan 2.29.0
::  (сначала test-windows\setup.bat). Запуск без pause.
::
::  Usage:    test-windows\run_qwt_win.bat
::  Env:
::    QWT_VERSION       по умолчанию 6.2.0
::    PROFILE_NAME      по умолчанию win-v143-x64 (ещё win-v142-x64, win-v142-x86)
::    OUTPUT_DIR        по умолчанию <repo>\output-qwt-win
::    SHARED            по умолчанию False (контент — статические .a)
::    SKIP_CACHE_CLEAN  =1 чтобы пропустить очистку кэша `conan remove *`
:: ============================================================
setlocal ENABLEEXTENSIONS

set SCRIPT_DIR=%~dp0
set ROOT_DIR=%SCRIPT_DIR%..
pushd "%ROOT_DIR%"
set EXITCODE=0

if "%QWT_VERSION%"=="" set QWT_VERSION=6.2.0

if exist venv\Scripts\activate.bat call venv\Scripts\activate.bat

if "%PROFILE_NAME%"=="" set PROFILE_NAME=win-v143-x64
set PROFILE=%ROOT_DIR%\profiles\%PROFILE_NAME%
if not exist "%PROFILE%" (
    echo [ERROR] Profile not found: %PROFILE%
    set EXITCODE=1
    goto :END
)
if "%SHARED%"=="" set SHARED=False
if "%OUTPUT_DIR%"=="" set OUTPUT_DIR=%ROOT_DIR%\output-qwt-win
if not exist "%OUTPUT_DIR%" mkdir "%OUTPUT_DIR%"

:: -----------------------------------------------------------
:: Убедиться, что Conan есть. На чистом TC-агенте его может не быть — ставим
:: офлайн из packages\ (без интернета). Нужен Python на агенте. Если нет ни
:: того ни другого — разово подготовить агент (см. [FAIL] ниже).
:: -----------------------------------------------------------
where conan >nul 2>&1 || (
    echo [INFO] conan not on PATH - installing offline from packages\ ...
    python -m pip install --no-index --find-links="%ROOT_DIR%\packages" --upgrade pip setuptools wheel
    python -m pip install --no-index --find-links="%ROOT_DIR%\packages" --upgrade conan
)
where conan >nul 2>&1 || (
    echo [FAIL] Conan not available on this agent.
    echo        Provision once: install Python, then run test-windows\setup.bat
    echo        ^(installs Conan offline from packages\^), or add conan to PATH.
    set EXITCODE=1
    goto :END
)

:: Qt pre-flight: рецепт читает QT5_ROOT_DIR (side-channel, как весь легаси).
if "%QT5_ROOT_DIR%"=="" (
    echo [FAIL] QT5_ROOT_DIR is not set. Point it at the agent's Qt install root
    echo        ^(e.g. C:\Qt\5.15.2^) - the recipe finds the msvc*_64 subdir itself.
    set EXITCODE=1
    goto :END
)
echo [INFO] QT5_ROOT_DIR: %QT5_ROOT_DIR%

echo [INFO] Ref:      qwt/%QWT_VERSION%
echo [INFO] Profile:  %PROFILE%
echo [INFO] Output:   %OUTPUT_DIR%
echo [INFO] Shared:   %SHARED%
for /f "tokens=*" %%v in ('conan --version 2^>^&1') do echo [INFO] Conan:    %%v
echo.

:: -----------------------------------------------------------
:: Шаг 0.5: чистим кэш Conan (package_id может молча переиспользоваться между
:: наборами опций — по той же причине это делает Linux-драйвер).
:: -----------------------------------------------------------
if not "%SKIP_CACHE_CLEAN%"=="1" (
    echo ============================================
    echo  Step 0.5: conan remove "*" -c  (set SKIP_CACHE_CLEAN=1 to skip)
    echo ============================================
    conan remove "*" -c
    echo.
)

:: -----------------------------------------------------------
echo ============================================
echo  Step 1/3: Export qwt recipe
echo ============================================
echo [INFO] conan export qwt (%QWT_VERSION%)
conan export "%ROOT_DIR%\qwt" --version=%QWT_VERSION% --no-remote
if errorlevel 1 ( echo [FAIL] qwt export & set EXITCODE=1 & goto :END )
echo.

:: -----------------------------------------------------------
echo ============================================
echo  Step 2/3: Build qwt/%QWT_VERSION% Release + Debug
echo ============================================
for %%B in (Release Debug) do (
    echo [INFO] Building qwt/%QWT_VERSION% build_type=%%B shared=%SHARED%
    conan install --requires=qwt/%QWT_VERSION% ^
        -pr:h="%PROFILE%" -pr:b="%PROFILE%" ^
        --build=missing --no-remote ^
        -s build_type=%%B ^
        -o "*/*:shared=%SHARED%"
    if errorlevel 1 (
        echo [FAIL] qwt %%B build failed
        set EXITCODE=1
        goto :END
    )
)
echo [OK] qwt/%QWT_VERSION% built (Release+Debug)
echo.

:: -----------------------------------------------------------
echo ============================================
echo  Step 3/3: Package via deployer
echo ============================================
del /q "%OUTPUT_DIR%\*.nupkg" 2>nul

conan install --requires=qwt/%QWT_VERSION% ^
    -pr:h="%PROFILE%" -pr:b="%PROFILE%" ^
    --no-remote ^
    -o "*/*:shared=%SHARED%" ^
    --deployer="%ROOT_DIR%\extensions\deployers\legacy_nupkg.py" ^
    --deployer-folder="%OUTPUT_DIR%"
if errorlevel 1 (
    echo [FAIL] deployer failed
    set EXITCODE=1
    goto :END
)

echo.
echo [INFO] Generated .nupkg files:
dir /b "%OUTPUT_DIR%\*.nupkg"

if exist "%OUTPUT_DIR%\qwt.win.*.nupkg" (
    echo [INFO] qwt.win.*.nupkg present in %OUTPUT_DIR%
) else (
    echo [FAIL] qwt.win.*.nupkg missing
    set EXITCODE=1
)

goto :END

:END
popd
echo.
if "%EXITCODE%"=="0" (
    echo ============================================
    echo  [DONE] qwt %QWT_VERSION% Windows OK ^(profile %PROFILE_NAME%^)
    echo ============================================
) else (
    echo [DONE] FAILED with code %EXITCODE%
)
endlocal & exit /b %EXITCODE%
