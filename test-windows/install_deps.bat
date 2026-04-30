@echo off
:: ============================================
::  Скачивает / распаковывает Windows build-tools (Strawberry Perl + NASM)
::  в tools\windows\ внутри репо.
::
::  Запускать ОДИН РАЗ перед setup.bat.
::
::  Сценарии:
::    1) На машине с интернетом:
::       test-windows\install_deps.bat
::         → скачивает архивы в tools\windows\, потом распаковывает.
::         → можно после этого скопировать tools\windows\*.zip на USB/share
::           для оффлайн-машины (вместе с самим репозиторием).
::
::    2) На оффлайн-машине, если архивы уже принесли в tools\windows\:
::       test-windows\install_deps.bat
::         → видит готовые архивы, пропускает скачивание, распаковывает.
::
::  После прогона:
::    tools\windows\strawberryperl\perl\bin\perl.exe
::    tools\windows\nasm\nasm.exe
::  И профили win-* видят их через [buildenv] PATH.
:: ============================================
setlocal ENABLEEXTENSIONS

set SCRIPT_DIR=%~dp0
set ROOT_DIR=%SCRIPT_DIR%..
set TOOLS_DIR=%ROOT_DIR%\tools\windows

if not exist "%TOOLS_DIR%" mkdir "%TOOLS_DIR%"

set PERL_VER=5.32.1.1
set PERL_ZIP=%TOOLS_DIR%\strawberryperl-%PERL_VER%-portable.zip
set PERL_URL=https://strawberryperl.com/download/%PERL_VER%/strawberry-perl-%PERL_VER%-64bit-portable.zip
set PERL_DIR=%TOOLS_DIR%\strawberryperl

set NASM_VER=2.16.01
set NASM_ZIP=%TOOLS_DIR%\nasm-%NASM_VER%-win64.zip
set NASM_URL=https://www.nasm.us/pub/nasm/releasebuilds/%NASM_VER%/win64/nasm-%NASM_VER%-win64.zip
set NASM_DIR=%TOOLS_DIR%\nasm

echo.
echo ============================================
echo  Step 1/3: Strawberry Perl %PERL_VER%
echo ============================================
if exist "%PERL_DIR%\perl\bin\perl.exe" (
    echo [OK] Already installed: %PERL_DIR%\perl\bin\perl.exe
    goto :nasm
)
if not exist "%PERL_ZIP%" (
    echo [INFO] Downloading from %PERL_URL%
    powershell -NoProfile -Command "try { [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12; Invoke-WebRequest -UseBasicParsing -Uri '%PERL_URL%' -OutFile '%PERL_ZIP%' } catch { Write-Host '[ERROR]' $_.Exception.Message; exit 1 }"
    if errorlevel 1 (
        echo.
        echo [FAIL] Не удалось скачать Strawberry Perl.
        echo        Если на этой машине нет интернета:
        echo          1. Скачайте %PERL_URL% на машине с интернетом.
        echo          2. Положите файл в %PERL_ZIP%
        echo          3. Запустите этот скрипт снова.
        goto :END_FAIL
    )
)
echo [INFO] Extracting %PERL_ZIP% to %PERL_DIR%
if exist "%PERL_DIR%" rmdir /s /q "%PERL_DIR%"
mkdir "%PERL_DIR%"
powershell -NoProfile -Command "Expand-Archive -Path '%PERL_ZIP%' -DestinationPath '%PERL_DIR%' -Force"
if errorlevel 1 (
    echo [FAIL] Распаковка Perl провалилась.
    goto :END_FAIL
)
if not exist "%PERL_DIR%\perl\bin\perl.exe" (
    echo [FAIL] perl.exe не найден после распаковки в %PERL_DIR%\perl\bin\
    goto :END_FAIL
)
echo [OK] Perl: %PERL_DIR%\perl\bin\perl.exe

:nasm
echo.
echo ============================================
echo  Step 2/3: NASM %NASM_VER%
echo ============================================
if exist "%NASM_DIR%\nasm.exe" (
    echo [OK] Already installed: %NASM_DIR%\nasm.exe
    goto :verify
)
if not exist "%NASM_ZIP%" (
    echo [INFO] Downloading from %NASM_URL%
    powershell -NoProfile -Command "try { [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12; Invoke-WebRequest -UseBasicParsing -Uri '%NASM_URL%' -OutFile '%NASM_ZIP%' } catch { Write-Host '[ERROR]' $_.Exception.Message; exit 1 }"
    if errorlevel 1 (
        echo.
        echo [FAIL] Не удалось скачать NASM.
        echo        На оффлайн-машине: скачайте %NASM_URL% и положите в %NASM_ZIP%.
        goto :END_FAIL
    )
)
echo [INFO] Extracting %NASM_ZIP% to %NASM_DIR%
if exist "%NASM_DIR%" rmdir /s /q "%NASM_DIR%"
mkdir "%NASM_DIR%"
:: NASM-zip распаковывается в подпапку nasm-X.Y.ZZ — переносим nasm.exe на уровень выше
powershell -NoProfile -Command "Expand-Archive -Path '%NASM_ZIP%' -DestinationPath '%NASM_DIR%\_extract' -Force"
for /d %%D in ("%NASM_DIR%\_extract\nasm-*") do (
    xcopy /e /y /q "%%D\*" "%NASM_DIR%\" >nul
)
rmdir /s /q "%NASM_DIR%\_extract"
if not exist "%NASM_DIR%\nasm.exe" (
    echo [FAIL] nasm.exe не найден после распаковки в %NASM_DIR%\
    goto :END_FAIL
)
echo [OK] NASM: %NASM_DIR%\nasm.exe

:verify
echo.
echo ============================================
echo  Step 3/3: Verify
echo ============================================
"%PERL_DIR%\perl\bin\perl.exe" --version | findstr "perl"
if errorlevel 1 (
    echo [FAIL] perl --version не отработал
    goto :END_FAIL
)
"%NASM_DIR%\nasm.exe" -v
if errorlevel 1 (
    echo [FAIL] nasm -v не отработал
    goto :END_FAIL
)

echo.
echo ============================================
echo  DONE — обе тулзы установлены в tools\windows\
echo ============================================
echo  Strawberry Perl: %PERL_DIR%\perl\bin\perl.exe
echo  NASM:            %NASM_DIR%\nasm.exe
echo.
echo  Профили win-v143-x64 и т.п. через [buildenv] добавляют эти
echo  пути в PATH сборки автоматически. Можно запускать setup.bat,
echo  потом run_test_grpc.bat.
echo ============================================
endlocal
exit /b 0

:END_FAIL
endlocal
exit /b 1
