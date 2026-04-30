@echo off
:: ============================================
::  Полный тест Conan для zlib (Windows MSVC)
::  1. Собирает zlib Release+Debug из оригинальных исходников
::  2. Упаковывает в legacy .nupkg через Conan-deployer
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

echo ============================================
echo  Test 1/2: Build zlib Release + Debug
echo ============================================
echo.
for %%B in (Release Debug) do (
    echo [INFO] Building zlib build_type=%%B
    conan create zlib\ --version=1.3.1 -pr:h="%PROFILE%" -pr:b="%PROFILE%" --build=missing --no-remote -s build_type=%%B
    if errorlevel 1 (
        echo [FAIL] zlib %%B build failed
        set EXITCODE=1
        goto :END
    )
)
echo [OK] zlib Release+Debug built
echo.

echo ============================================
echo  Test 2/2: Package via Conan deployer
echo ============================================
echo.
del /q output\zlib.*.nupkg 2>nul
conan install ^
    --requires=zlib/1.3.1 ^
    -pr:h="%PROFILE%" -pr:b="%PROFILE%" ^
    --no-remote ^
    --deployer="%ROOT_DIR%\extensions\deployers\legacy_nupkg.py" ^
    --deployer-folder="%ROOT_DIR%\output"
if errorlevel 1 (
    echo [FAIL] deployer failed
    set EXITCODE=1
    goto :END
)

echo.
echo [INFO] Generated .nupkg files:
dir /b output\zlib.*.nupkg

for %%F in (output\zlib.*.nupkg) do set NUPKG=%%F
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
if "%EXITCODE%"=="0" (
    echo [DONE] success
) else (
    echo [DONE] FAILED with code %EXITCODE%
)
echo Press any key to close this window...
pause >nul
endlocal & exit /b %EXITCODE%
