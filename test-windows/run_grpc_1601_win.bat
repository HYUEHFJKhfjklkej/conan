@echo off
:: ============================================================
::  Windows MSVC build of the grpc/1.60.1 tree (legacy GR113/GR120 parity).
::  Native sibling of test-astra/run_grpc_1601_upstream.sh — no Docker on
::  Windows, builds directly on the agent with MSVC.
::
::  Versions (exactly the grpc/1.60.x line, same as the Linux driver):
::    grpc 1.60.1, protobuf 4.25.2, abseil 20230802.1, re2 20230301,
::    c-ares 1.25.0, openssl 1.1.1 (recipe dir openssl-1x\), zlib 1.3.0
::  -> 7 legacy .nupkg in output-grpc-1601-win\ via the deployer.
::
::  Prereqs on the agent: MSVC toolset for the profile + Conan 2.29.0
::  (run test-windows\setup.bat first). Run from a terminal (no pause).
::
::  Usage:    test-windows\run_grpc_1601_win.bat
::  Env:
::    PROFILE_NAME      default win-v143-x64 (also win-v142-x64, win-v142-x86)
::    OUTPUT_DIR        default <repo>\output-grpc-1601-win
::    SHARED            default False (content static .a)
::    SKIP_CACHE_CLEAN  set to 1 to skip the `conan remove *` cache wipe
:: ============================================================
setlocal ENABLEEXTENSIONS

set SCRIPT_DIR=%~dp0
set ROOT_DIR=%SCRIPT_DIR%..
pushd "%ROOT_DIR%"
set EXITCODE=0

if exist venv\Scripts\activate.bat call venv\Scripts\activate.bat

if "%PROFILE_NAME%"=="" set PROFILE_NAME=win-v143-x64
set PROFILE=%ROOT_DIR%\profiles\%PROFILE_NAME%
if not exist "%PROFILE%" (
    echo [ERROR] Profile not found: %PROFILE%
    set EXITCODE=1
    goto :END
)
if "%SHARED%"=="" set SHARED=False
if "%OUTPUT_DIR%"=="" set OUTPUT_DIR=%ROOT_DIR%\output-grpc-1601-win
if not exist "%OUTPUT_DIR%" mkdir "%OUTPUT_DIR%"

echo [INFO] Profile:  %PROFILE%
echo [INFO] Output:   %OUTPUT_DIR%
echo [INFO] Shared:   %SHARED%
for /f "tokens=*" %%v in ('conan --version 2^>^&1') do echo [INFO] Conan:    %%v
echo.

:: -----------------------------------------------------------
:: Step 0.5: wipe the Conan cache (protobuf package_id can be silently
:: reused across option sets — same reason the Linux 1601 driver does it).
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
echo  Step 1/3: Export 7 recipes (1.60.1-line versions)
echo ============================================
echo [INFO] conan export zlib (1.3.0)
conan export "%ROOT_DIR%\zlib" --version=1.3.0 --no-remote
if errorlevel 1 ( echo [FAIL] zlib export & set EXITCODE=1 & goto :END )

echo [INFO] conan export abseil (20230802.1)
conan export "%ROOT_DIR%\abseil" --version=20230802.1 --no-remote
if errorlevel 1 ( echo [FAIL] abseil export & set EXITCODE=1 & goto :END )

echo [INFO] conan export c-ares (1.25.0)
conan export "%ROOT_DIR%\c-ares" --version=1.25.0 --no-remote
if errorlevel 1 ( echo [FAIL] c-ares export & set EXITCODE=1 & goto :END )

echo [INFO] conan export re2 (20230301)
conan export "%ROOT_DIR%\re2" --version=20230301 --no-remote
if errorlevel 1 ( echo [FAIL] re2 export & set EXITCODE=1 & goto :END )

echo [INFO] conan export protobuf (4.25.2)
conan export "%ROOT_DIR%\protobuf" --version=4.25.2 --no-remote
if errorlevel 1 ( echo [FAIL] protobuf export & set EXITCODE=1 & goto :END )

echo [INFO] conan export openssl-1x (1.1.11)  [recipe dir openssl-1x, name=openssl]
conan export "%ROOT_DIR%\openssl-1x" --version=1.1.11 --no-remote
if errorlevel 1 ( echo [FAIL] openssl-1x export & set EXITCODE=1 & goto :END )

echo [INFO] conan export grpc (1.60.1)
conan export "%ROOT_DIR%\grpc" --version=1.60.1 --no-remote
if errorlevel 1 ( echo [FAIL] grpc export & set EXITCODE=1 & goto :END )
echo.

:: -----------------------------------------------------------
echo ============================================
echo  Step 2/3: Build grpc/1.60.1 tree Release + Debug
echo ============================================
for %%B in (Release Debug) do (
    echo [INFO] Building grpc/1.60.1 + 6 deps build_type=%%B shared=%SHARED%
    conan install --requires=grpc/1.60.1 ^
        -pr:h="%PROFILE%" -pr:b="%PROFILE%" ^
        --build=missing --no-remote ^
        -s build_type=%%B ^
        -o "*/*:shared=%SHARED%"
    if errorlevel 1 (
        echo [FAIL] grpc tree %%B build failed
        set EXITCODE=1
        goto :END
    )
)
echo [OK] grpc/1.60.1 tree built (Release+Debug)
echo.

:: -----------------------------------------------------------
echo ============================================
echo  Step 3/3: Package full tree via deployer
echo ============================================
del /q "%OUTPUT_DIR%\*.nupkg" 2>nul

conan install --requires=grpc/1.60.1 ^
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

set /a COUNT=0
:: deployer emits LEGACY names (LEGACY_NAME_MAP): abseil->absl, c-ares->cares
for %%P in (grpc protobuf absl re2 cares openssl zlib) do (
    if exist "%OUTPUT_DIR%\%%P.win.*.nupkg" (
        set /a COUNT+=1
    ) else (
        echo [FAIL] %%P.win.*.nupkg missing
    )
)
echo [INFO] %COUNT%/7 packages present in %OUTPUT_DIR%
if not "%COUNT%"=="7" set EXITCODE=1

goto :END

:END
popd
echo.
if "%EXITCODE%"=="0" (
    echo ============================================
    echo  [DONE] grpc 1.60.1 Windows tree OK ^(profile %PROFILE_NAME%^)
    echo ============================================
) else (
    echo [DONE] FAILED with code %EXITCODE%
)
endlocal & exit /b %EXITCODE%
