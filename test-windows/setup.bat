@echo off
:: ============================================
::  Conan Environment Setup (OFFLINE) — Windows
:: ============================================
setlocal ENABLEEXTENSIONS

:: Перейти в корень репо (на уровень выше test-windows/)
set SCRIPT_DIR=%~dp0
set ROOT_DIR=%SCRIPT_DIR%..
pushd "%ROOT_DIR%"

echo ============================================
echo  Conan Environment Setup (OFFLINE)
echo ============================================
echo.

:: Проверить Python
python --version >nul 2>&1
if %errorlevel% neq 0 (
    echo [ERROR] Python not found in PATH
    echo Install Python 3.11 from python.org and check "Add to PATH"
    goto :END
)
for /f "delims=" %%V in ('python --version') do set PYVER=%%V
echo [OK] %PYVER%

:: Колёса в packages/ собраны под Python 3.14 (cp314 win_amd64)
:: Если у вас другая версия — pip install ниже упадёт; используйте python 3.14

:: Создать venv
echo.
echo [INFO] Creating virtual environment in %ROOT_DIR%\venv ...
if exist venv (
    echo [INFO] venv already exists, skipping
) else (
    python -m venv venv
    if errorlevel 1 (
        echo [ERROR] venv creation failed
        goto :END
    )
)

call venv\Scripts\activate.bat

:: Offline-режим pip
set PIP_NO_INDEX=1
set PIP_FIND_LINKS=%ROOT_DIR%\packages

if not exist "%PIP_FIND_LINKS%" (
    echo [ERROR] Папка с offline-пакетами не найдена: %PIP_FIND_LINKS%
    goto :END
)

echo.
echo [INFO] Using local wheels from: %PIP_FIND_LINKS%
echo.
echo [INFO] Installing setuptools and wheel...
python -m pip install setuptools wheel
if errorlevel 1 (
    echo [ERROR] setuptools/wheel install failed
    goto :END
)

echo.
echo [INFO] Installing Conan from local packages...
python -m pip install conan
if errorlevel 1 (
    echo [ERROR] Conan install failed
    goto :END
)

set PIP_NO_INDEX=
set PIP_FIND_LINKS=

echo.
echo [OK] Conan installed:
conan --version

echo.
echo [INFO] Detecting Conan profile...
conan profile detect --force

echo.
echo.
echo [INFO] Setting up Strawberry Perl + NASM in tools\windows\ ...
call "%SCRIPT_DIR%install_deps.bat"
if errorlevel 1 (
    echo [ERROR] install_deps.bat failed. См. вывод выше.
    goto :END
)

echo.
echo ============================================
echo  Done! Environment is ready.
echo ============================================
echo Next: test-windows\run_test_grpc.bat

:END
popd
echo.
echo Press any key to close...
pause >nul
endlocal
