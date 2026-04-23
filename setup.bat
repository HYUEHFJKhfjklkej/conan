@echo off
echo ============================================
echo  Установка окружения для Conan (OFFLINE)
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

:: Установить Conan из локальных пакетов (без интернета!)
echo.
echo [INFO] Устанавливаю Conan из локальных пакетов...
python -m pip install conan --no-index --find-links=packages

if %errorlevel% neq 0 (
    echo [ОШИБКА] Не удалось установить Conan!
    echo Попробуйте: python -m pip install conan --no-index --find-links=packages
    pause
    exit /b 1
)

echo [OK] Conan установлен:
conan --version

:: Настроить Conan
echo.
echo [INFO] Настраиваю Conan profile...
conan profile detect

echo.
echo ============================================
echo  Готово! Окружение настроено.
echo ============================================
echo.
echo Следующий шаг - собрать gtest:
echo   venv\Scripts\activate.bat
echo   conan create gtest/ --build=missing
echo.
pause
