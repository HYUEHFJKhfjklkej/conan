@echo off
echo ============================================
echo  Установка окружения для Conan
echo ============================================
echo.

:: Проверить Python
python --version >nul 2>&1
if %errorlevel% neq 0 (
    echo [ОШИБКА] Python не найден!
    echo Скачайте: https://www.python.org/downloads/
    echo При установке поставьте галку "Add Python to PATH"
    pause
    exit /b 1
)

echo [OK] Python найден:
python --version

:: Установить pip если нет
pip --version >nul 2>&1
if %errorlevel% neq 0 (
    echo [INFO] pip не найден, устанавливаю...
    python -m ensurepip --upgrade
    if %errorlevel% neq 0 (
        echo [INFO] ensurepip не сработал, скачиваю get-pip.py...
        curl -o get-pip.py https://bootstrap.pypa.io/get-pip.py
        python get-pip.py
        del get-pip.py
    )
)

echo [OK] pip найден:
pip --version

:: Создать виртуальное окружение
echo.
echo [INFO] Создаю виртуальное окружение...
if exist venv (
    echo [INFO] venv уже существует, пропускаю
) else (
    python -m venv venv
)

:: Активировать
echo [INFO] Активирую виртуальное окружение...
call venv\Scripts\activate.bat

:: Установить Conan
echo.
echo [INFO] Устанавливаю Conan...
pip install -r requirements.txt

:: Настроить Conan
echo.
echo [INFO] Настраиваю Conan profile...
conan profile detect

echo.
echo ============================================
echo  Готово! Окружение настроено.
echo ============================================
echo.
echo Для сборки gtest выполните:
echo   venv\Scripts\activate.bat
echo   conan create gtest/ --build=missing
echo.
pause
