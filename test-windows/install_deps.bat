@echo off
:: ============================================
::  Готовит Windows build-tools (Strawberry Perl + NASM) в tools\windows\.
::  ОФЛАЙН-ТОЛЬКО — НИКОГДА не качает из интернета (closed-network).
::
::  Источник тулзов, в порядке приоритета (что найдёт — то и возьмёт):
::    1) уже распакованы в tools\windows\strawberryperl\ и tools\windows\nasm\
::    2) env PERL_SRC / NASM_SRC указывает на уже распакованную папку ИЛИ .zip
::         set PERL_SRC=C:\Users\me\Downloads\strawberry-perl-5.32.1.1-64bit-portable
::         set NASM_SRC=C:\path\nasm-2.16.01-win64.zip
::    3) портативный .zip лежит в tools\windows\ (имена см. PERL_ZIP/NASM_ZIP ниже)
::  Если ничего не найдено — скрипт ПАДАЕТ с инструкцией, в сеть НЕ лезет.
::
::  Результат:
::    tools\windows\strawberryperl\perl\bin\perl.exe
::    tools\windows\nasm\nasm.exe
::  Профили win-* добавляют их в PATH сборки через [buildenv].
:: ============================================
setlocal ENABLEEXTENSIONS

set SCRIPT_DIR=%~dp0
set ROOT_DIR=%SCRIPT_DIR%..
set TOOLS_DIR=%ROOT_DIR%\tools\windows

if not exist "%TOOLS_DIR%" mkdir "%TOOLS_DIR%"

set PERL_VER=5.32.1.1
set PERL_ZIP=%TOOLS_DIR%\strawberryperl-%PERL_VER%-portable.zip
set PERL_DIR=%TOOLS_DIR%\strawberryperl

set NASM_VER=2.16.01
set NASM_ZIP=%TOOLS_DIR%\nasm-%NASM_VER%-win64.zip
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
    echo.
    echo [FAIL] Strawberry Perl не найден, скачивание ОТКЛЮЧЕНО ^(closed-network^).
    echo        Дай тулзу офлайн одним из способов и запусти снова:
    echo          A) распакуй портативный Perl так, чтобы существовал файл:
    echo               %PERL_DIR%\perl\bin\perl.exe
    echo             ^(например скопируй свою папку strawberry-perl-...-portable
    echo              целиком в %PERL_DIR%^)
    echo          B) либо положи портативный .zip сюда:
    echo               %PERL_ZIP%
    goto :END_FAIL
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
    echo.
    echo [FAIL] NASM не найден, скачивание ОТКЛЮЧЕНО ^(closed-network^).
    echo        Дай тулзу офлайн одним из способов и запусти снова:
    echo          A) положи nasm.exe сюда: %NASM_DIR%\nasm.exe
    echo          B) либо положи nasm-%NASM_VER%-win64.zip сюда: %NASM_ZIP%
    goto :END_FAIL
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
