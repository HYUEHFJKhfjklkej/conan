#!/bin/bash
# Матричная сборка: один пакет × все профили × shared/static
# Использование: ./build-matrix.sh <package_name> [remote]
# Пример:       ./build-matrix.sh gtest elara
#
# Для TeamCity: запускается на Linux-агенте (Linux-профили)
#               и на Windows-агенте (Windows-профили) отдельно

set -euo pipefail

PACKAGE="${1:?Укажите имя пакета (gtest, curl, ...)}"
REMOTE="${2:-elara}"

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT_DIR="$(dirname "$SCRIPT_DIR")"

cd "$ROOT_DIR"

# Определить OS агента
if [[ "$OSTYPE" == "msys" || "$OSTYPE" == "win32" || "$OSTYPE" == "cygwin" ]]; then
    AGENT_OS="windows"
else
    AGENT_OS="linux"
fi

# Профили для текущей OS
if [ "$AGENT_OS" == "linux" ]; then
    PROFILES=(
        "profiles/lin-gcc84-x86_64"
        "profiles/lin-gcc84-i686"
        "profiles/lin-gcc75-arm-linaro"
        "profiles/lin-gcc-aarch64-linaro"
        # Добавить другие Linux-профили по мере создания:
        # "profiles/lin-gcc-arm-nxp"
        # "profiles/lin-gcc-aarch64-rockchip"
        # "profiles/lin-gcc-atom"
    )
else
    PROFILES=(
        "profiles/win-v142-x64"
        "profiles/win-v142-x86"
        # "profiles/win-wince-ce800"
    )
fi

SHARED_OPTIONS=("True" "False")

TOTAL=0
FAILED=()

for profile in "${PROFILES[@]}"; do
    for shared in "${SHARED_OPTIONS[@]}"; do
        TOTAL=$((TOTAL + 1))
        LABEL="$profile shared=$shared"

        echo "##teamcity[blockOpened name='$LABEL']"
        echo ">>> [$TOTAL] Building $PACKAGE ($LABEL)..."

        if conan create "$PACKAGE/" \
            --profile="$profile" \
            -o "$PACKAGE/*:shared=$shared" \
            --build=missing; then
            echo ">>> [$TOTAL] $LABEL: OK"
        else
            echo ">>> [$TOTAL] $LABEL: FAILED"
            FAILED+=("$LABEL")
        fi

        echo "##teamcity[blockClosed name='$LABEL']"
    done
done

# Загрузить все собранные варианты
echo ">>> Uploading all $PACKAGE packages to $REMOTE..."
conan upload "$PACKAGE/*" --remote="$REMOTE" --confirm

# Итог
if [ ${#FAILED[@]} -gt 0 ]; then
    echo "##teamcity[buildProblem description='Failed: ${FAILED[*]}']"
    echo ">>> FAILED ${#FAILED[@]} of $TOTAL configurations"
    exit 1
fi

echo "##teamcity[buildStatus text='$PACKAGE: $TOTAL configurations built and uploaded']"
echo ">>> All $TOTAL configurations OK"
