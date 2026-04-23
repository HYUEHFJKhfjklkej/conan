#!/bin/bash
# Сборка всех рецептов для указанного профиля
# Использование: ./build-all.sh [profile]

set -euo pipefail

PROFILE="${1:-profiles/linux-gcc}"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT_DIR="$(dirname "$SCRIPT_DIR")"

cd "$ROOT_DIR"

# Список пакетов для сборки (порядок важен — зависимости первыми)
PACKAGES=(
    gtest
    # grpc
    # spdlog
    # Добавлять новые пакеты сюда
)

FAILED=()

for pkg in "${PACKAGES[@]}"; do
    echo "##teamcity[blockOpened name='$pkg']"
    if "$SCRIPT_DIR/build-recipe.sh" "$pkg" "$PROFILE"; then
        echo ">>> $pkg: OK"
    else
        echo ">>> $pkg: ОШИБКА"
        FAILED+=("$pkg")
    fi
    echo "##teamcity[blockClosed name='$pkg']"
done

if [ ${#FAILED[@]} -gt 0 ]; then
    echo "##teamcity[buildProblem description='Failed packages: ${FAILED[*]}']"
    exit 1
fi

echo "##teamcity[buildStatus text='All ${#PACKAGES[@]} packages built']"
