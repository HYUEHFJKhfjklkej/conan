@echo off
echo ============================================
echo  Build gtest + run example tests
echo ============================================
echo.

:: Activate venv
if exist venv\Scripts\activate.bat (
    call venv\Scripts\activate.bat
) else (
    echo [ERROR] venv not found! Run setup.bat first.
    pause
    exit /b 1
)

:: Step 1: Build gtest from original sources
echo.
echo [1/5] Building gtest from original sources (no modification)...
conan create gtest/ --build=missing --no-remote
if %errorlevel% neq 0 (
    echo [ERROR] Failed to build gtest!
    pause
    exit /b 1
)
echo [OK] gtest built successfully.

:: Step 2: Install dependencies for example
echo.
echo [2/5] Installing dependencies for example project...
cd example
if exist build rmdir /s /q build
conan install . --output-folder=build --no-remote
if %errorlevel% neq 0 (
    echo [ERROR] Failed to install dependencies!
    cd ..
    pause
    exit /b 1
)
echo [OK] Dependencies installed.

:: Step 3: Configure cmake
echo.
echo [3/5] Configuring CMake...
cmake -B build -DCMAKE_TOOLCHAIN_FILE=build/conan_toolchain.cmake
if %errorlevel% neq 0 (
    echo [ERROR] CMake configure failed!
    cd ..
    pause
    exit /b 1
)
echo [OK] CMake configured.

:: Step 4: Build
echo.
echo [4/5] Building example project...
cmake --build build --config Release
if %errorlevel% neq 0 (
    echo [ERROR] Build failed!
    cd ..
    pause
    exit /b 1
)
echo [OK] Build successful.

:: Step 5: Run tests
echo.
echo [5/5] Running tests...
cd build
ctest --output-on-failure -C Release
set TEST_RESULT=%errorlevel%
cd ..\..

if %TEST_RESULT% neq 0 (
    echo.
    echo [ERROR] Tests failed!
    pause
    exit /b 1
)

echo.
echo ============================================
echo  ALL DONE! gtest built and tests passed.
echo ============================================
echo.
echo  gtest was built from ORIGINAL sources
echo  without any modification to its code.
echo  Concept for IN-353 is verified.
echo.
pause
