#!/bin/bash
# Проверяет, что опубликованный в ProGet образ grpc-tc-mirror собирает семь
# .nupkg end-to-end (без обвязки test_arm_cross.sh, просто `docker run` по
# закреплённому тегу). Эталонный acceptance-тест перед передачей образа в TeamCity.
#
# Использование:
#   ./run_prebake.sh arm
#   ./run_prebake.sh arm64
#   ./run_prebake.sh x86_64
#
# Обязательный env:
#   REGISTRY     ProGet host + main feed (напр. proget.example/main).
#                По умолч. proget.inc.elara.local/main
#
# Опциональный env:
#   MIRROR_VER   тег grpc-tc-mirror-{arm,arm64,x86_64} для проверки. По умолч. 0.1.0
#   MIN_FREE_GB  требуемое свободное место в /var/lib/docker. По умолч. 30
#
# Вывод:
#   семь .nupkg в output-${ARCH}-prebake/ при успехе.
#
# Зачем это (а не просто `test_arm_cross.sh build`): test_arm_cross.sh
# пересобирает образ из Dockerfile.grpc-tc-mirror на месте, т.е. тестирует
# "образ, как он собрался бы СЕЙЧАС". Для передачи в TC нужно проверить
# "образ ровно как его хранит ProGet" — закреплённый тег 0.1.0, свежий pull,
# без локального кэша слоёв.

set -uo pipefail

ARCH="${1:-}"

if [[ -z "$ARCH" ]]; then
    sed -n '2,30p' "$0"
    exit 2
fi

case "$ARCH" in
    arm)
        PROFILE="/work/conan-recipes/profiles/lin-gcc75-arm-linaro"
        USER_TC="/work/conan-recipes/profiles/toolchains/linaro-arm.cmake"
        ;;
    arm64)
        PROFILE="/work/conan-recipes/profiles/lin-gcc-aarch64-linaro"
        USER_TC="/work/conan-recipes/profiles/toolchains/linaro-aarch64.cmake"
        ;;
    x86_64)
        # Нативная сборка: host-профиль = build-профиль, без cross-toolchain.
        PROFILE="/work/conan-recipes/profiles/lin-gcc84-x86_64"
        USER_TC=""
        ;;
    *)
        echo "[FAIL] arch must be 'arm', 'arm64' or 'x86_64', got '$ARCH'" >&2
        exit 2
        ;;
esac

REGISTRY="${REGISTRY:-proget.inc.elara.local/main}"
MIRROR_VER="${MIRROR_VER:-0.1.0}"
MIN_FREE_GB="${MIN_FREE_GB:-30}"

# Базовый URL backup-sources (HELP [16]). Прокидывается в контейнер ЯВНО:
# голый `-e VAR` при незаданной VAR на хосте заставляет docker СБРОСИТЬ
# дефолт из ENV образа вместо наследования. `-` (не `:-`): явная пустая
# строка тоже отключает backup-sources для этого прогона.
PROGET_SOURCES_URL="${PROGET_SOURCES_URL-http://proget.inc.elara.local/endpoints/conan-sources/content/}"
PROFILE_BUILD="/work/conan-recipes/profiles/lin-gcc84-x86_64"

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT_DIR="$(dirname "$SCRIPT_DIR")"
OUTPUT_DIR="$ROOT_DIR/output-${ARCH}-prebake"
IMAGE="$REGISTRY/library/grpc-tc-mirror-${ARCH}:$MIRROR_VER"
CACHE_VOLUME="conan-cache-${ARCH}-prebake"

hdr() { printf "\n=== %s ===\n" "$1"; }
pass() { printf "[PASS] %s\n" "$1"; }
fail() { printf "[FAIL] %s\n" "$1" >&2; exit 1; }

# Как вызывать docker. На dev-astra passwordless sudo; у CI-агентов обычно
# нет, но build-юзер часто в группе `docker` (или работает как root). Пробуем
# напрямую, затем sudo -n; если ничего не вышло — падаем с пояснением.
if docker info >/dev/null 2>&1; then
    DOCKER=(docker)
elif sudo -n docker info >/dev/null 2>&1; then
    DOCKER=(sudo -n docker)
else
    cat >&2 <<EOF
[FAIL] cannot reach the Docker daemon. Options to fix on this host:
   1) Add the build user to the docker group (recommended for CI agents):
          sudo usermod -aG docker \$USER
          # log out + back in, or: newgrp docker
   2) Or grant passwordless sudo for docker:
          echo "\$USER ALL=(root) NOPASSWD: /usr/bin/docker" \\
              | sudo tee /etc/sudoers.d/\$USER-docker
   3) Or run this script as root (not advised).
EOF
    exit 1
fi
echo "docker invocation: ${DOCKER[*]}"

hdr "config"
echo "ARCH          = $ARCH"
echo "REGISTRY      = $REGISTRY"
echo "MIRROR_VER    = $MIRROR_VER"
echo "IMAGE         = $IMAGE"
echo "PROFILE       = $PROFILE"
echo "PROFILE_BUILD = $PROFILE_BUILD"
echo "USER_TC       = $USER_TC"
echo "OUTPUT_DIR    = $OUTPUT_DIR"
echo "CACHE_VOLUME  = $CACHE_VOLUME"
echo "MIN_FREE_GB   = $MIN_FREE_GB"

hdr "1. disk-space pre-flight"
# Зеркало пишет ~5 GB conan-cache + ~2 GB временных файлов компилятора в
# docker-раздел. Сразу выходим, если места не хватает.
DOCKER_DIR="$("${DOCKER[@]}" info --format '{{.DockerRootDir}}' 2>/dev/null || echo /var/lib/docker)"
FREE_KB=$(df --output=avail -k "$DOCKER_DIR" 2>/dev/null | tail -1 | tr -d ' ')
FREE_GB=$(( FREE_KB / 1024 / 1024 ))
echo "free on $DOCKER_DIR: ${FREE_GB} GB"
if (( FREE_GB < MIN_FREE_GB )); then
    cat <<EOF >&2
[FAIL] less than ${MIN_FREE_GB} GB free in $DOCKER_DIR.
       Free up space before re-running:
           sudo docker image prune -f
           sudo docker builder prune -f
       And, if still tight, drop stale :latest mirror tags from
       earlier test_arm_cross.sh runs (no longer needed once
       ${MIRROR_VER} is pinned in ProGet):
           sudo docker image rm \\
               grpc-tc-mirror grpc-tc-mirror-arm \\
               grpc-tc-mirror-arm64 grpc-tc-mirror-armv7hf 2>/dev/null
       Override the threshold with MIN_FREE_GB=<n> $0 $ARCH.
EOF
    exit 1
fi
pass "${FREE_GB} GB free (>= ${MIN_FREE_GB} GB)"

hdr "2. fresh pull from ProGet"
# Сначала сносим локальную копию — нам нужен реальный round-trip с ProGet,
# а не устаревший кэш слоёв.
"${DOCKER[@]}" image rm "$IMAGE" >/dev/null 2>&1 || true
if ! "${DOCKER[@]}" pull "$IMAGE"; then
    fail "docker pull $IMAGE — did the push complete, and is this host logged in to ProGet? Try: ${DOCKER[*]} login ${REGISTRY%%/*}"
fi
pass "pulled $IMAGE"

hdr "3. end-to-end build"
mkdir -p "$OUTPUT_DIR"
echo "log → $OUTPUT_DIR/build.log"
echo "starting at $(date +%H:%M:%S), expect 15-25 min"

if "${DOCKER[@]}" run --rm \
        -v "$ROOT_DIR":/work/conan-recipes \
        -v "$OUTPUT_DIR":/work/conan-recipes/output \
        -v "$CACHE_VOLUME":/root/.conan2 \
        -e PROFILE="$PROFILE" \
        -e PROFILE_BUILD="$PROFILE_BUILD" \
        -e CONAN_USER_TOOLCHAIN="$USER_TC" \
        -e CONAN_REMOTE -e CONAN_REMOTE_URL -e CONAN_REMOTE_INSECURE \
        -e UPLOAD_AFTER -e CONAN_LOGIN_USERNAME -e CONAN_PASSWORD \
        -e PROGET_SOURCES_URL="$PROGET_SOURCES_URL" \
        "$IMAGE" \
        bash /work/conan-recipes/test-astra/run_test_grpc.sh \
        2>&1 | tee "$OUTPUT_DIR/build.log"; then
    pass "docker run completed"
else
    fail "docker run failed — tail $OUTPUT_DIR/build.log and check HELP [10]"
fi

hdr "4. verify .nupkg artefacts"
COUNT=$(ls -1 "$OUTPUT_DIR"/*.nupkg 2>/dev/null | wc -l)
if (( COUNT != 7 )); then
    ls -lh "$OUTPUT_DIR"/*.nupkg 2>/dev/null || true
    fail "expected 7 .nupkg in $OUTPUT_DIR, got $COUNT"
fi
ls -lh "$OUTPUT_DIR"/*.nupkg
pass "7 .nupkg in $OUTPUT_DIR"

hdr "done — image $IMAGE is production-ready for TC handoff"
