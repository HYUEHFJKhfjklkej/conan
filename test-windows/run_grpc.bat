@echo off
:: ============================================
::  Build grpc 1.78.1 (canonical + offline) on Windows MSVC
::  Pulls full dep tree: abseil, c-ares, openssl, protobuf, re2, zlib.
::  4 variants — heavy: 30–60 min total.
:: ============================================
setlocal ENABLEEXTENSIONS ENABLEDELAYEDEXPANSION

set SCRIPT_DIR=%~dp0
set ROOT_DIR=%SCRIPT_DIR%..
pushd "%ROOT_DIR%"

if not exist venv\Scripts\activate.bat (
    echo [ERROR] venv not found. Run test-windows\setup.bat first.
    goto :END
)
call venv\Scripts\activate.bat

set PROFILE=profiles\win-v143-x64
if not exist "%PROFILE%" set PROFILE=profiles\win-v142-x64

echo [INFO] Profile: %PROFILE%
for /f "delims=" %%V in ('conan --version') do echo [INFO] %%V
echo [INFO] Recipe: canonical from conan-center-index
echo.

:: Step 1: export every recipe so Conan can find them in --no-remote mode.
:: Without this, `conan create grpc/` fails with "protobuf not resolved" etc.
echo ============================================
echo  Step 1: Export all recipes to local cache
echo ============================================
call :export_one zlib     1.3.1         || goto :END
call :export_one abseil   20250127.0    || goto :END
call :export_one c-ares   1.34.6        || goto :END
call :export_one re2      20251105      || goto :END
call :export_one protobuf 5.29.6        || goto :END
call :export_one openssl  3.4.5         || goto :END
echo.

call :build_one static  Release
if errorlevel 1 goto :END
call :build_one static  Debug
if errorlevel 1 goto :END
call :build_one shared  Release
if errorlevel 1 goto :END
call :build_one shared  Debug
if errorlevel 1 goto :END

echo.
echo [INFO] Conan cache after builds:
conan list "*/*:*"

echo.
echo ============================================
echo  ALL 4 grpc VARIANTS BUILT (canonical recipe)
echo  Dependency tree: abseil, c-ares, openssl, protobuf, re2, zlib
echo ============================================
goto :END

:build_one
set LINKAGE=%1
set BT=%2
set SHARED=False
if "%LINKAGE%"=="shared" set SHARED=True

echo ============================================
echo  grpc 1.78.1  linkage=%LINKAGE%  build_type=%BT%
echo ============================================

conan create "%ROOT_DIR%\grpc" ^
    --version=1.78.1 ^
    --profile="%PROFILE%" ^
    --build=missing ^
    --no-remote ^
    -s build_type=%BT% ^
    -o "*/*:shared=%SHARED%"
exit /b %errorlevel%

:export_one
echo [INFO] conan export %~1 (%~2)
conan export "%ROOT_DIR%\%~1" --version=%~2
exit /b %errorlevel%

:END
popd
echo.
echo Press any key to close...
pause >nul
endlocal
