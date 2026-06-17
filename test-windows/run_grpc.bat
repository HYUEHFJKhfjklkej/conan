@echo off
:: ============================================
::  Сборка grpc 1.78.1 (canonical + offline) на Windows MSVC.
::  Тянет всё дерево deps: abseil, c-ares, openssl, protobuf, re2, zlib.
::  4 варианта — тяжело: 30–60 мин суммарно.
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

:: Шаг 1: экспортируем все рецепты, чтобы Conan нашёл их в режиме --no-remote.
:: Без этого `conan create grpc/` падает с "protobuf not resolved" и т.п.
echo ============================================
echo  Step 1: Export all recipes to local cache
echo ============================================
echo [INFO] conan export zlib (1.3.1)
conan export "%ROOT_DIR%\zlib" --version=1.3.1
if errorlevel 1 goto :END

echo [INFO] conan export abseil (20250127.0)
conan export "%ROOT_DIR%\abseil" --version=20250127.0
if errorlevel 1 goto :END

echo [INFO] conan export c-ares (1.34.6)
conan export "%ROOT_DIR%\c-ares" --version=1.34.6
if errorlevel 1 goto :END

echo [INFO] conan export re2 (20251105)
conan export "%ROOT_DIR%\re2" --version=20251105
if errorlevel 1 goto :END

echo [INFO] conan export protobuf (5.29.6)
conan export "%ROOT_DIR%\protobuf" --version=5.29.6
if errorlevel 1 goto :END

echo [INFO] conan export openssl (3.4.5)
conan export "%ROOT_DIR%\openssl" --version=3.4.5
if errorlevel 1 goto :END
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
    -pr:h="%PROFILE%" -pr:b="%PROFILE%" ^
    --build=missing ^
    --no-remote ^
    -s build_type=%BT% ^
    -o "*/*:shared=%SHARED%"
exit /b %errorlevel%

:END
popd
echo.
echo Press any key to close...
pause >nul
endlocal
