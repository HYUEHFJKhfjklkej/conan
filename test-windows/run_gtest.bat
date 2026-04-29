@echo off
:: ============================================
::  Build gtest (canonical conan-center recipe)
::  4 variants on Windows MSVC: static/Release, static/Debug, shared/Release, shared/Debug
::  Each build runs test_package automatically.
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

:: Pick profile: prefer win-v143-x64, fallback to win-v142-x64
set PROFILE=profiles\win-v143-x64
if not exist "%PROFILE%" set PROFILE=profiles\win-v142-x64

echo [INFO] Profile: %PROFILE%
for /f "delims=" %%V in ('conan --version') do echo [INFO] %%V
echo [INFO] Recipe: canonical from conan-center-index
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
conan list "gtest/1.16.0:*"

echo.
echo ============================================
echo  ALL 4 gtest VARIANTS BUILT (canonical recipe)
echo  test_package (consumer smoke test) ran for each variant.
echo ============================================
goto :END

:build_one
set LINKAGE=%1
set BT=%2
set SHARED=False
if "%LINKAGE%"=="shared" set SHARED=True

echo ============================================
echo  gtest 1.16.0  linkage=%LINKAGE%  build_type=%BT%
echo ============================================

conan create "%ROOT_DIR%\gtest\" ^
    --version=1.16.0 ^
    --profile="%PROFILE%" ^
    --build=missing ^
    --no-remote ^
    -s build_type=%BT% ^
    -o "gtest/*:shared=%SHARED%"
exit /b %errorlevel%

:END
popd
echo.
echo Press any key to close...
pause >nul
endlocal
