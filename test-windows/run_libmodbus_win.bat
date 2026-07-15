@echo off
:: ============================================================
::  Сборка пакета libmodbus/3.1.12 на Windows MSVC (одиночный пакет).
::  Нативный аналог test-astra/build_libmodbus_nodocker.sh — на Windows без
::  Docker, собирает прямо на агенте через MSVC. libmodbus — вне grpc-дерева,
::  без транзитивных deps.
::
::  export -> build Release+Debug -> deployer -> libmodbus.win.*.nupkg
::  в output-libmodbus-win\.
::
::  Требуется на агенте: MSVC-toolset под профиль + Conan 2.29.0
::  (сначала test-windows\setup.bat). Запуск без pause.
::
::  Usage:    test-windows\run_libmodbus_win.bat
::  Env:
::    LIBMODBUS_VERSION       по умолчанию 3.1.12
::    PROFILE_NAME      по умолчанию win-v143-x64 (ещё win-v142-x64, win-v142-x86)
::    OUTPUT_DIR        по умолчанию <repo>\output-libmodbus-win
::    SHARED            по умолчанию False (контент — статические .a)
::    SKIP_CACHE_CLEAN  =1 чтобы пропустить очистку кэша `conan remove *`
:: ============================================================
setlocal ENABLEEXTENSIONS

set SCRIPT_DIR=%~dp0
set ROOT_DIR=%SCRIPT_DIR%..
pushd "%ROOT_DIR%"
set EXITCODE=0

if "%LIBMODBUS_VERSION%"=="" set LIBMODBUS_VERSION=3.1.12

if exist venv\Scripts\activate.bat call venv\Scripts\activate.bat

if "%PROFILE_NAME%"=="" set PROFILE_NAME=win-v143-x64
set PROFILE=%ROOT_DIR%\profiles\%PROFILE_NAME%
if not exist "%PROFILE%" (
    echo [ERROR] Profile not found: %PROFILE%
    set EXITCODE=1
    goto :END
)
if "%SHARED%"=="" set SHARED=False
if "%OUTPUT_DIR%"=="" set OUTPUT_DIR=%ROOT_DIR%\output-libmodbus-win
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

echo [INFO] Ref:      libmodbus/%LIBMODBUS_VERSION%
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
echo  Step 1/3: Export libmodbus recipe
echo ============================================
echo [INFO] conan export libmodbus (%LIBMODBUS_VERSION%)
conan export "%ROOT_DIR%\libmodbus" --version=%LIBMODBUS_VERSION% --no-remote
if errorlevel 1 ( echo [FAIL] libmodbus export & set EXITCODE=1 & goto :END )
echo.

:: -----------------------------------------------------------
echo ============================================
echo  Step 2/3: Build libmodbus/%LIBMODBUS_VERSION% Release + Debug
echo ============================================
for %%B in (Release Debug) do (
    echo [INFO] Building libmodbus/%LIBMODBUS_VERSION% build_type=%%B shared=%SHARED%
    conan install --requires=libmodbus/%LIBMODBUS_VERSION% ^
        -pr:h="%PROFILE%" -pr:b="%PROFILE%" ^
        --build=missing --no-remote ^
        -s build_type=%%B ^
        -o "*/*:shared=%SHARED%"
    if errorlevel 1 (
        echo [FAIL] libmodbus %%B build failed
        set EXITCODE=1
        goto :END
    )
)
echo [OK] libmodbus/%LIBMODBUS_VERSION% built (Release+Debug)
echo.

:: -----------------------------------------------------------
echo ============================================
echo  Step 3/3: Package via deployer
echo ============================================
del /q "%OUTPUT_DIR%\*.nupkg" 2>nul

conan install --requires=libmodbus/%LIBMODBUS_VERSION% ^
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

if exist "%OUTPUT_DIR%\libmodbus.win.*.nupkg" (
    echo [INFO] libmodbus.win.*.nupkg present in %OUTPUT_DIR%
) else (
    echo [FAIL] libmodbus.win.*.nupkg missing
    set EXITCODE=1
)

goto :END

:END
popd
echo.
if "%EXITCODE%"=="0" (
    echo ============================================
    echo  [DONE] libmodbus %LIBMODBUS_VERSION% Windows OK ^(profile %PROFILE_NAME%^)
    echo ============================================
) else (
    echo [DONE] FAILED with code %EXITCODE%
)
endlocal & exit /b %EXITCODE%
