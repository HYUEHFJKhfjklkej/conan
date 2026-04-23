#!/bin/bash
# Скрипт сборки Conan-рецепта для TeamCity
# Собирает пакет через Conan (без патчинга) и пакует в legacy zip-формат
#
# Использование: ./build-recipe.sh <package_name> <version> <profile> [shared]
# Пример:       ./build-recipe.sh gtest 1.14.0 linux-gcc True

set -euo pipefail

PACKAGE="${1:?Укажите имя пакета (gtest, curl, ...)}"
VERSION="${2:?Укажите версию (1.14.0)}"
PROFILE_NAME="${3:-linux-gcc}"
SHARED="${4:-True}"
REMOTE="${CONAN_REMOTE:-elara}"

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT_DIR="$(dirname "$SCRIPT_DIR")"
OUTPUT_DIR="${ROOT_DIR}/output"

mkdir -p "$OUTPUT_DIR"

echo "##teamcity[progressMessage 'Building $PACKAGE/$VERSION (profile=$PROFILE_NAME, shared=$SHARED)']"

# 1. Собрать пакет из оригинальных исходников (БЕЗ модификации)
echo ">>> [1/3] Сборка $PACKAGE через Conan..."
conan create "$ROOT_DIR/$PACKAGE/" \
    --profile="$ROOT_DIR/profiles/$PROFILE_NAME" \
    -o "$PACKAGE/*:shared=$SHARED" \
    --build=missing

# 2. Упаковать в legacy zip-формат (как текущие артефакты TeamCity)
echo ">>> [2/3] Упаковка в legacy-формат..."
python3 "$SCRIPT_DIR/package-legacy.py" \
    --name "$PACKAGE" \
    --version "$VERSION" \
    --profile "$PROFILE_NAME" \
    --shared "$SHARED" \
    --output "$OUTPUT_DIR"

# 3. Загрузить в Conan remote (опционально)
if [ "${CONAN_UPLOAD:-true}" == "true" ]; then
    echo ">>> [3/3] Загрузка в $REMOTE..."
    conan upload "$PACKAGE/*" --remote="$REMOTE" --confirm
else
    echo ">>> [3/3] Upload пропущен (CONAN_UPLOAD=false)"
fi

echo "##teamcity[buildStatus text='$PACKAGE/$VERSION built and packaged']"
echo "##teamcity[publishArtifacts '$OUTPUT_DIR/*.zip']"
echo ">>> Готово: $OUTPUT_DIR/"
