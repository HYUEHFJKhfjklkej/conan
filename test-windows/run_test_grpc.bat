@echo off
:: ============================================
::  Полный тест Conan для grpc на Windows (MSVC)
::  1. Собирает grpc + 6 транзитивных deps Release+Debug (static)
::  2. Упаковывает все 7 пакетов в legacy .nupkg через Conan-deployer
::  Артефакты: output\{grpc,protobuf,abseil,re2,c-ares,openssl,zlib}.*.nupkg
::  Heavy: 30-60 минут на 8 ядрах (×2 build_type).
:: ============================================
setlocal ENABLEEXTENSIONS

set SCRIPT_DIR=%~dp0
set ROOT_DIR=%SCRIPT_DIR%..
pushd "%ROOT_DIR%"

set EXITCODE=0
if not exist output mkdir output

if exist venv\Scripts\activate.bat (
    call venv\Scripts\activate.bat
)

if "%PROFILE_NAME%"=="" set PROFILE_NAME=win-v143-x64
set PROFILE=%ROOT_DIR%\profiles\%PROFILE_NAME%
if not exist "%PROFILE%" (
    echo [ERROR] Profile not found: %PROFILE%
    set EXITCODE=1
    goto :END
)
echo [INFO] Using profile: %PROFILE%
echo.

:: -----------------------------------------------------------
echo ============================================
echo  Step 1/3: Export all recipes to local cache
echo ============================================
echo.
echo [INFO] conan export zlib (1.3.1)
conan export "%ROOT_DIR%\zlib" --version=1.3.1
if errorlevel 1 ( echo [FAIL] zlib export & set EXITCODE=1 & goto :END )

echo [INFO] conan export abseil (20250127.0)
conan export "%ROOT_DIR%\abseil" --version=20250127.0
if errorlevel 1 ( echo [FAIL] abseil export & set EXITCODE=1 & goto :END )

echo [INFO] conan export c-ares (1.34.6)
conan export "%ROOT_DIR%\c-ares" --version=1.34.6
if errorlevel 1 ( echo [FAIL] c-ares export & set EXITCODE=1 & goto :END )

echo [INFO] conan export re2 (20251105)
conan export "%ROOT_DIR%\re2" --version=20251105
if errorlevel 1 ( echo [FAIL] re2 export & set EXITCODE=1 & goto :END )

echo [INFO] conan export protobuf (5.29.6)
conan export "%ROOT_DIR%\protobuf" --version=5.29.6
if errorlevel 1 ( echo [FAIL] protobuf export & set EXITCODE=1 & goto :END )

echo [INFO] conan export openssl (3.4.5)
conan export "%ROOT_DIR%\openssl" --version=3.4.5
if errorlevel 1 ( echo [FAIL] openssl export & set EXITCODE=1 & goto :END )

echo [INFO] conan export grpc (1.78.1)
conan export "%ROOT_DIR%\grpc" --version=1.78.1
if errorlevel 1 ( echo [FAIL] grpc export & set EXITCODE=1 & goto :END )
echo.

:: -----------------------------------------------------------
echo ============================================
echo  Step 2/3: Build grpc tree Release + Debug
echo ============================================
echo.
for %%B in (Release Debug) do (
    echo [INFO] Building grpc/1.78.1 + 6 deps build_type=%%B
    conan install --requires=grpc/1.78.1 ^
        -pr:h="%PROFILE%" -pr:b="%PROFILE%" ^
        --build=missing --no-remote ^
        -s build_type=%%B ^
        -o "*/*:shared=False"
    if errorlevel 1 (
        echo [FAIL] grpc tree %%B build failed
        set EXITCODE=1
        goto :END
    )
)
echo [OK] grpc tree built (Release+Debug, static)
echo.

:: -----------------------------------------------------------
echo ============================================
echo  Step 3/3: Package full tree via deployer
echo ============================================
echo.
del /q output\grpc.*.nupkg     2>nul
del /q output\protobuf.*.nupkg 2>nul
del /q output\abseil.*.nupkg   2>nul
del /q output\re2.*.nupkg      2>nul
del /q output\c-ares.*.nupkg   2>nul
del /q output\openssl.*.nupkg  2>nul
del /q output\zlib.*.nupkg     2>nul

conan install ^
    --requires=grpc/1.78.1 ^
    -pr:h="%PROFILE%" -pr:b="%PROFILE%" ^
    --no-remote ^
    -o "*/*:shared=False" ^
    --deployer="%ROOT_DIR%\extensions\deployers\legacy_nupkg.py" ^
    --deployer-folder="%ROOT_DIR%\output"
if errorlevel 1 (
    echo [FAIL] deployer failed
    set EXITCODE=1
    goto :END
)

echo.
echo [INFO] Generated .nupkg files:
dir /b output\*.nupkg

echo.
echo ============================================
echo  ALL grpc TREE PACKAGES BUILT
echo ============================================
echo  Artifacts: output\*.nupkg (7 files)
echo  Structure matches TeamCity format.
echo ============================================
goto :END

:END
popd
echo.
if "%EXITCODE%"=="0" (
    echo [DONE] success
) else (
    echo [DONE] FAILED with code %EXITCODE%
)
echo Press any key to close this window...
pause >nul
endlocal & exit /b %EXITCODE%
