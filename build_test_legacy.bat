@echo off
echo ============================================
echo  Build gtest + package in legacy format
echo ============================================
echo.

:: Activate venv
if exist venv\Scripts\activate.bat (
    call venv\Scripts\activate.bat
) else (
    echo [WARN] venv not found, using system Python
)

:: Step 1: Build gtest via Conan (no source modification!)
echo.
echo [1/4] Building gtest from original sources via Conan...
conan create gtest/ --build=missing --no-remote
if %errorlevel% neq 0 (
    echo [ERROR] Failed to build gtest!
    pause
    exit /b 1
)
echo [OK] gtest built successfully.

:: Step 2: Package in legacy format
echo.
echo [2/4] Packaging in legacy format (same as TeamCity artifacts)...
if not exist output mkdir output
python teamcity\package-legacy.py --name gtest --version 1.14.0 --profile windows-msvc --shared False --output output
if %errorlevel% neq 0 (
    echo [ERROR] Failed to package!
    pause
    exit /b 1
)
echo [OK] Legacy package created.

:: Step 3: Show result
echo.
echo [3/4] Result:
echo.
dir output\*.zip
echo.

:: Step 4: Show zip contents
echo [4/4] Zip contents:
echo.
python -c "import zipfile,sys; [print(f'  {i.filename}  ({i.file_size:,} bytes)') for i in zipfile.ZipFile('output/googletest.zip').infolist()]"

echo.
echo ============================================
echo  DONE! Legacy artifact created:
echo  output\googletest.zip
echo.
echo  Same structure as current TeamCity artifacts:
echo    lin.gcc.shared.x64\
echo      build\native\*.targets
echo      include\
echo      lib\
echo      nuget\*.nuspec
echo      CMakeLists.var
echo      LICENSE.txt
echo.
echo  Source code was NOT modified.
echo ============================================
echo.
pause
