@echo off
:: ============================================
::  Полный тест Conan на Windows (MSVC)
::  Аналог test-astra/run_test.sh для Linux
::  1. Собирает gtest Release+Debug из оригинальных исходников
::  2. Прогоняет тесты потребителя
::  3. Упаковывает через Conan-deployer в .nupkg
:: ============================================
setlocal ENABLEEXTENSIONS

set SCRIPT_DIR=%~dp0
set ROOT_DIR=%SCRIPT_DIR%..
pushd "%ROOT_DIR%"

set RC=0
if not exist output mkdir output

:: Активировать venv если есть
if exist venv\Scripts\activate.bat (
    call venv\Scripts\activate.bat
)

:: Профиль Windows. По умолчанию VS 2022 (v143/MSVC 194).
:: Можно переопределить:  set PROFILE_NAME=win-v142-x64  и потом run_test.bat
if "%PROFILE_NAME%"=="" set PROFILE_NAME=win-v143-x64
set PROFILE=%ROOT_DIR%\profiles\%PROFILE_NAME%
if not exist "%PROFILE%" (
    echo [ERROR] Profile not found: %PROFILE%
    echo Available profiles:
    dir /b "%ROOT_DIR%\profiles\win-*"
    set RC=1
    goto :END
)
echo [INFO] Using profile: %PROFILE%
echo.

:: -----------------------------------------------------------
echo ============================================
echo  Test 1/3: Build gtest Release + Debug
echo ============================================
echo.
for %%B in (Release Debug) do (
    echo [INFO] Building gtest build_type=%%B
    conan create gtest\ --profile="%PROFILE%" --build=missing --no-remote -s build_type=%%B
    if errorlevel 1 (
        echo [FAIL] gtest %%B build failed
        set RC=1
        goto :END
    )
)
echo [OK] gtest Release+Debug built

:: -----------------------------------------------------------
echo.
echo ============================================
echo  Test 2/3: Build example consumer + run tests
echo ============================================
echo.
pushd example
if exist build rmdir /s /q build
conan install . --output-folder=build --build=missing --profile="%PROFILE%" --no-remote
if errorlevel 1 (
    echo [FAIL] conan install for example failed
    popd
    set RC=1
    goto :END
)
cmake -B build -DCMAKE_TOOLCHAIN_FILE=build\conan_toolchain.cmake -DCMAKE_BUILD_TYPE=Release
if errorlevel 1 ( popd & set RC=1 & goto :END )
cmake --build build --config Release
if errorlevel 1 ( popd & set RC=1 & goto :END )
pushd build
ctest -C Release --output-on-failure
if errorlevel 1 (
    echo [FAIL] tests failed
    popd
    popd
    set RC=1
    goto :END
)
popd
popd
echo [OK] Tests passed

:: -----------------------------------------------------------
echo.
echo ============================================
echo  Test 3/3: Package via Conan deployer
echo ============================================
echo.
del /q output\*.nupkg 2>nul
conan install ^
    --requires=gtest/1.15.2 ^
    --profile="%PROFILE%" ^
    --no-remote ^
    --deployer="%ROOT_DIR%\extensions\deployers\legacy_nupkg.py" ^
    --deployer-folder="%ROOT_DIR%\output"
if errorlevel 1 (
    echo [FAIL] deployer failed
    set RC=1
    goto :END
)

echo.
echo [INFO] Generated .nupkg files:
dir /b output\*.nupkg

for %%F in (output\*.nupkg) do set NUPKG=%%F
if defined NUPKG (
    echo.
    echo [INFO] Contents of %NUPKG%:
    python -c "import zipfile; zf=zipfile.ZipFile(r'%NUPKG%'); [print(f'  {i.filename}  ({i.file_size:,} bytes)') for i in zf.infolist()]"
)

echo.
echo ============================================
echo  ALL TESTS PASSED
echo ============================================

:END
popd
echo.
if "%RC%"=="0" (
    echo [DONE] success
) else (
    echo [DONE] FAILED with code %RC%
)
echo Press any key to close this window...
pause >nul
endlocal & exit /b %RC%
