#!/bin/bash
# Скрипт сборки Conan-рецепта для TeamCity
# Использование: ./build-recipe.sh <package_name> [profile]
# Пример:       ./build-recipe.sh gtest profiles/linux-gcc

set -euo pipefail

PACKAGE="${1:?Укажите имя пакета (gtest, grpc, ...)}"
PROFILE="${2:-profiles/linux-gcc}"
REMOTE="${CONAN_REMOTE:-elara}"

echo "##teamcity[progressMessage 'Building $PACKAGE with profile $PROFILE']"

# Собрать пакет из оригинальных исходников
echo ">>> Сборка $PACKAGE..."
conan create "$PACKAGE/" --profile="$PROFILE" --build=missing

# Загрузить собранный пакет в Conan-remote
echo ">>> Загрузка $PACKAGE в $REMOTE..."
conan upload "$PACKAGE/*" --remote="$REMOTE" --confirm

echo "##teamcity[buildStatus text='$PACKAGE built and uploaded']"
echo ">>> Готово: $PACKAGE"
