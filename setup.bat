@echo off
echo ============================================
echo  Conan Environment Setup (OFFLINE)
echo ============================================
echo.

:: Check Python
python --version >nul 2>&1
if %errorlevel% neq 0 (
    echo [ERROR] Python not found!
    echo Download: https://www.python.org/downloads/
    echo Make sure to check "Add Python to PATH" during installation
    pause
    exit /b 1
)

echo [OK] Python found:
python --version

:: Create virtual environment
echo.
echo [INFO] Creating virtual environment...
if exist venv (
    echo [INFO] venv already exists, skipping
) else (
    python -m venv venv
)

:: Activate
echo [INFO] Activating virtual environment...
call venv\Scripts\activate.bat

:: Install Conan from local packages (no internet required!)
echo.
echo [INFO] Installing Conan from local packages...
python -m pip install conan --no-index --find-links=packages

if %errorlevel% neq 0 (
    echo [ERROR] Failed to install Conan!
    echo Try manually: python -m pip install conan --no-index --find-links=packages
    pause
    exit /b 1
)

echo [OK] Conan installed:
conan --version

:: Configure Conan
echo.
echo [INFO] Detecting Conan profile...
conan profile detect

echo.
echo ============================================
echo  Done! Environment is ready.
echo ============================================
echo.
echo Next step - build gtest:
echo   venv\Scripts\activate.bat
echo   conan create gtest/ --build=missing
echo.
pause
