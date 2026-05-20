#!/bin/bash
#
# fix_legacy_protobuf_absl.sh
#
# Чинит link-фейл `legacy/protobuf 4.25.2` (undefined references к
# `absl::lts_20230802::*`). Корень: Elara `legacy/absl/0.2.0` собран с
# `ABSL_OPTION_INLINE_NAMESPACE_NAME = lts_20240116`, а headers protobuf
# 4.25.2 захардкоднуты под `lts_20230802`.
#
# Решение: подменить в legacy/protobuf зависимость с `absl/0.2.0` на наш
# upstream `abseil/20230802.1` (LTS 20230802, ровно совпадает с namespace
# который ожидает protoc).
#
# Запуск (от обычного user'a; sudo внутри для docker):
#   bash transfer-to-dev-vm/fix_legacy_protobuf_absl.sh
#
# Идемпотентно: бэкапит .bak.<ts>, повторный запуск ничего не сломает.
#
set -euo pipefail

ROOT_DIR="${ROOT_DIR:-$HOME/conan-master}"
TS="$(date +%Y%m%d-%H%M%S)"
cd "$ROOT_DIR"

echo "ROOT_DIR=$ROOT_DIR"
echo

# ---------------------------------------------------------------- step 1
echo "=========================================="
echo "[1/5] Pre-flight: tarball + recipe files"
echo "=========================================="

if [ ! -f abseil/src/20230802.1.tar.gz ]; then
    cat <<EOF
ERROR: нет abseil/src/20230802.1.tar.gz

Способ A (если на dev-VM есть интернет):
  curl -L -o $ROOT_DIR/abseil/src/20230802.1.tar.gz \\
       https://github.com/abseil/abseil-cpp/archive/20230802.1.tar.gz
  echo "987ce98f02eefbaf930d6e38ab16aa05737234d7afbab2d5c4ea7adbe50c28ed  abseil/src/20230802.1.tar.gz" | sha256sum -c

Способ B (closed-network, через transfer-папку):
  # на mac скачать
  curl -L -o /tmp/20230802.1.tar.gz \\
       https://github.com/abseil/abseil-cpp/archive/20230802.1.tar.gz
  base64 < /tmp/20230802.1.tar.gz > transfer-to-dev-vm/20230802.1.tar.gz.b64
  # перенести transfer-to-dev-vm/20230802.1.tar.gz.b64 на dev-VM, потом:
  base64 -d < 20230802.1.tar.gz.b64 > $ROOT_DIR/abseil/src/20230802.1.tar.gz

После этого — перезапустить этот скрипт.
EOF
    exit 1
fi
echo "  [OK] abseil/src/20230802.1.tar.gz"

if [ ! -f legacy/protobuf/conanfile.py ]; then
    echo "ERROR: legacy/protobuf/conanfile.py отсутствует."
    echo "Сначала: bash test-astra/prepare_legacy_from_bitbucket.sh"
    exit 1
fi
echo "  [OK] legacy/protobuf/conanfile.py"

echo

# ---------------------------------------------------------------- step 2
echo "=========================================="
echo "[2/5] Patch legacy/protobuf/conanfile.py"
echo "=========================================="

if grep -q 'absl/0\.2\.0' legacy/protobuf/conanfile.py; then
    cp -a legacy/protobuf/conanfile.py "legacy/protobuf/conanfile.py.bak.$TS"
    sed -i 's|absl/0\.2\.0|abseil/20230802.1|g' legacy/protobuf/conanfile.py
    echo "  [PATCHED] backup: legacy/protobuf/conanfile.py.bak.$TS"
else
    echo "  [SKIP] absl/0.2.0 уже не упоминается (либо уже патчена, либо нет своего requirements())"
fi
grep -n "abseil/20230802\|absl/0\." legacy/protobuf/conanfile.py || true

echo

# ---------------------------------------------------------------- step 3
echo "=========================================="
echo "[3/5] Patch test-astra/run_legacy_versions.sh"
echo "=========================================="

SCRIPT=""
for cand in test-astra/run_legacy_versions.sh "$ROOT_DIR/run_legacy_versions.sh"; do
    [ -f "$cand" ] && SCRIPT="$cand" && break
done

if [ -z "$SCRIPT" ]; then
    echo "  [WARN] run_legacy_versions.sh не найден — будет использован прямой conan create в шаге 5"
elif grep -q '"absl/0\.2\.0"' "$SCRIPT" || grep -q 'abseil/20240116\.2' "$SCRIPT"; then
    cp -a "$SCRIPT" "$SCRIPT.bak.$TS"
    sed -i \
        -e 's|"absl/0\.2\.0", transitive_headers=True)|"abseil/20230802.1", transitive_headers=True)|g' \
        -e 's|--requires=abseil/20240116\.2|--requires=abseil/20230802.1|g' \
        "$SCRIPT"
    echo "  [PATCHED] $SCRIPT  (backup: $SCRIPT.bak.$TS)"
    grep -n 'absl\|abseil' "$SCRIPT" | head -20
else
    echo "  [SKIP] $SCRIPT — references уже подменены"
fi

echo

# ---------------------------------------------------------------- step 4
echo "=========================================="
echo "[4/5] Очистка кэша: protobuf/4.25.2 + absl/0.2.0 + abseil/20240116.2"
echo "=========================================="

DOCKER="docker"
if ! docker info >/dev/null 2>&1; then
    if sudo -n docker info >/dev/null 2>&1; then
        DOCKER="sudo docker"
    else
        echo "  [ERROR] docker недоступен без пароля sudo. Пропускаю чистку кэша."
        echo "  Если cache hit даст старый failed build folder — clean его руками:"
        echo "    sudo docker run --rm -v conan-cache-legacy-x86_64:/root/.conan2 \\"
        echo "        --entrypoint bash grpc-tc-mirror -c 'conan remove \"protobuf/4.25.2\" --confirm'"
        DOCKER=""
    fi
fi

if [ -n "$DOCKER" ]; then
    $DOCKER run --rm \
        --entrypoint bash \
        -v conan-cache-legacy-x86_64:/root/.conan2 \
        grpc-tc-mirror \
        -c 'conan remove "protobuf/4.25.2" --confirm 2>/dev/null || true; \
            conan remove "absl/0.2.0" --confirm 2>/dev/null || true; \
            conan remove "abseil/20240116.2" --confirm 2>/dev/null || true; \
            echo "[CACHE] список после чистки:"; \
            conan list "*/*" --no-remote 2>/dev/null | grep -E "^(protobuf|abseil|absl)" || true'
fi

echo

# ---------------------------------------------------------------- step 5
echo "=========================================="
echo "[5/5] Rebuild legacy-protobuf"
echo "=========================================="

if [ -n "$SCRIPT" ]; then
    echo "  $ sudo bash $SCRIPT legacy-protobuf"
    sudo bash "$SCRIPT" legacy-protobuf
else
    echo "  [FALLBACK] прямой conan create через docker"
    $DOCKER run --rm \
        --entrypoint bash \
        -v "$ROOT_DIR:/work/conan-recipes" \
        -v conan-cache-legacy-x86_64:/root/.conan2 \
        -e IN_MIRROR=1 \
        grpc-tc-mirror \
        -c "cd /work/conan-recipes && \
            conan export abseil --version=20230802.1 --no-remote && \
            conan export legacy/protobuf --version=4.25.2 --no-remote && \
            conan create legacy/protobuf --version=4.25.2 \
                -pr:h=profiles/lin-gcc84-x86_64 -pr:b=profiles/lin-gcc84-x86_64 \
                -s build_type=Release --build=missing --no-remote 2>&1 | tail -200"
fi

echo
echo "=========================================="
echo "[DONE] fix_legacy_protobuf_absl"
echo "=========================================="
echo
echo "Артефакты:"
ls -lh "$ROOT_DIR"/output-legacy/*.nupkg 2>/dev/null | tail -20 || echo "  (пусто — pack ещё не запускался)"
echo
echo "Логи провалов (если упало) — в output-legacy/logs/"
