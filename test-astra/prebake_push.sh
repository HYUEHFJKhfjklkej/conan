#!/bin/bash
# prebake_push.sh — собрать образы grpc-tc-mirror и опубликовать их в ProGet.
#
# Автоматизирует runbook HELP [10] (build -> smoke -> push -> verify pull) для
# одной или всех архитектур. Это "producer"-половина pre-bake; run_prebake.sh —
# "consumer/acceptance"-половина (свежий pull + сборка 7 .nupkg из опубликованного
# тега). E2E=1 — запускать run_prebake.sh после каждого успешного push.
#
# Closed-network: оба базовых образа берутся из ProGet, не из Docker Hub. Хост
# должен быть `docker login` в registry с правами push на main/library/* (admin
# или сервис-аккаунт с Feed Administrator на `main`). ProGet доступен только с
# dev-VM, поэтому запуск там, не на Mac.
#
# Использование (dev-VM):
#   sudo docker login proget.inc.elara.local          # один раз на сессию
#   ./test-astra/prebake_push.sh                       # все три арки
#   ./test-astra/prebake_push.sh x86_64                # одна арка
#   ./test-astra/prebake_push.sh arm arm64             # подмножество
#   PUSH=0 ./test-astra/prebake_push.sh x86_64         # только build + smoke
#   E2E=1  ./test-astra/prebake_push.sh arm64          # + acceptance-сборка
#   DRY_RUN=1 ./test-astra/prebake_push.sh             # печать, без выполнения
#
# Env:
#   REGISTRY            ProGet host + main feed. По умолч. proget.inc.elara.local/main
#   MIRROR_VER          Тег для build/push. По умолч. 0.1.0. Бампить (0.2.0, ...)
#                       при любом изменении Dockerfile/toolchain/Conan — не перезаписывать.
#   X64_BASE_IMAGE_TAG  тег gcc84-build-x86_64. По умолч. 0.1.0.
#   ARM_BASE_IMAGE_TAG  тег gcc75-build-arm. По умолч. 0.1.0.
#   ARM64_BASE_IMAGE_TAG тег gcc75-build-arm64. По умолч. 0.1.0.
#   PUSH                1 = push (по умолч.). 0 = только build + smoke.
#   VERIFY_PULL         1 = снести локальный образ и pull обратно после push (по умолч.).
#                       0 = пропустить (быстрее, но не проверяет round-trip).
#   E2E                 1 = run_prebake.sh <arch> после push (полный acceptance
#                       7 nupkg, ~15-25 мин/арка). По умолч. 0.
#   NO_CACHE            1 = docker build --no-cache.
#   DRY_RUN            1 = печатать каждую docker-команду, ничего не выполнять.

set -uo pipefail

REGISTRY="${REGISTRY:-proget.inc.elara.local/main}"
MIRROR_VER="${MIRROR_VER:-0.1.0}"
X64_BASE_IMAGE_TAG="${X64_BASE_IMAGE_TAG:-0.1.0}"
ARM_BASE_IMAGE_TAG="${ARM_BASE_IMAGE_TAG:-0.1.0}"
ARM64_BASE_IMAGE_TAG="${ARM64_BASE_IMAGE_TAG:-0.1.0}"
PUSH="${PUSH:-1}"
VERIFY_PULL="${VERIFY_PULL:-1}"
E2E="${E2E:-0}"
NO_CACHE="${NO_CACHE:-0}"
DRY_RUN="${DRY_RUN:-0}"

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT_DIR="$(dirname "$SCRIPT_DIR")"

ARCHES=("$@")
[ ${#ARCHES[@]} -eq 0 ] && ARCHES=(x86_64 arm arm64)

hdr()  { printf "\n=== %s ===\n" "$1"; }
pass() { printf "[PASS] %s\n" "$1"; }
fail() { printf "[FAIL] %s\n" "$1" >&2; exit 1; }

X64_BASE="$REGISTRY/library/gcc84-build-x86_64:$X64_BASE_IMAGE_TAG"

# Как вызывать docker (напрямую, затем sudo -n). Та же логика, что в
# run_prebake.sh: на dev-astra passwordless sudo, CI-агенты обычно в docker-группе.
# Под DRY_RUN пропускается — чтобы Mac мог прогнать поток вхолостую.
if [ "$DRY_RUN" = "1" ]; then
    DOCKER=(docker)
elif docker info >/dev/null 2>&1; then
    DOCKER=(docker)
elif sudo -n docker info >/dev/null 2>&1; then
    DOCKER=(sudo -n docker)
else
    cat >&2 <<EOF
[FAIL] cannot reach the Docker daemon. Fix one of:
   1) sudo usermod -aG docker \$USER   # then re-login / newgrp docker
   2) echo "\$USER ALL=(root) NOPASSWD: /usr/bin/docker" | sudo tee /etc/sudoers.d/\$USER-docker
EOF
    exit 1
fi

# run <docker args...> — выполнить, либо только напечатать под DRY_RUN.
run() {
    if [ "$DRY_RUN" = "1" ]; then
        printf '    DRY_RUN: %s' "${DOCKER[*]}"
        printf ' %q' "$@"
        printf '\n'
        return 0
    fi
    "${DOCKER[@]}" "$@"
}

# base_image_for <arch> -> печатает Stage-2 BASE_IMAGE для этой арки.
base_image_for() {
    case "$1" in
        x86_64) echo "$X64_BASE" ;;  # native: Stage 1 и 2 используют один gcc84-образ
        arm)    echo "$REGISTRY/library/gcc75-build-arm:$ARM_BASE_IMAGE_TAG" ;;
        arm64)  echo "$REGISTRY/library/gcc75-build-arm64:$ARM64_BASE_IMAGE_TAG" ;;
        *)      return 1 ;;
    esac
}

# smoke_one <arch> <image> — проверить собранный образ перед push. Ловит типовые
# поломки: нет /opt/x64-native-gcc в Stage 2, python3/conan не в PATH, нет
# вшитого global.conf. Для arm/arm64 дополнительно проверяет наличие linaro
# cross-gcc; у x86_64 cross-toolchain'а нет, эта проверка пропускается.
smoke_one() {
    local arch="$1" image="$2"
    hdr "smoke $image"
    if [ "$DRY_RUN" = "1" ]; then
        run run --rm "$image" bash -c "true"
        pass "smoke (dry-run)"
        return 0
    fi
    local need_linaro=1
    [ "$arch" = "x86_64" ] && need_linaro=0
    "${DOCKER[@]}" run --rm "$image" bash -c '
        set -e
        echo "-- python3 --";  /opt/python/bin/python3 --version
        echo "-- conan --";    conan --version
        echo "-- x64 native gcc --"; /opt/x64-native-gcc/bin/gcc --version | head -1
        echo "-- baked global.conf --"; grep -F core.sources:download_urls /root/.conan2/global.conf || echo "(none baked)"
        echo "-- PROFILE env --"; echo "[$PROFILE]"
        if [ "'"$need_linaro"'" = "1" ]; then
            echo "-- target gcc --"
            ls /opt/linaro-*/*/bin/*-gcc 2>/dev/null | head -3 \
                || { echo "[FAIL] no linaro cross-gcc in image" >&2; exit 1; }
        fi
    ' || fail "smoke failed for $image — do not push"
    pass "smoke ok: $image"
}

OK_ARCHES=()
for ARCH in "${ARCHES[@]}"; do
    BASE_IMAGE="$(base_image_for "$ARCH")" \
        || fail "arch must be one of: x86_64 arm arm64 (got '$ARCH')"
    IMAGE="$REGISTRY/library/grpc-tc-mirror-${ARCH}:$MIRROR_VER"

    hdr "build $IMAGE"
    echo "ARCH       = $ARCH"
    echo "BASE_IMAGE = $BASE_IMAGE"
    echo "X64_BASE   = $X64_BASE"
    echo "IMAGE      = $IMAGE"

    BUILD_ARGS=(build
        --build-arg "X64_BASE_IMAGE=$X64_BASE"
        --build-arg "BASE_IMAGE=$BASE_IMAGE"
        -f "$ROOT_DIR/Dockerfile.grpc-tc-mirror-$ARCH"
        -t "$IMAGE")
    [ "$NO_CACHE" = "1" ] && BUILD_ARGS+=(--no-cache)
    BUILD_ARGS+=("$ROOT_DIR")
    run "${BUILD_ARGS[@]}" || fail "docker build failed for $ARCH"
    pass "built $IMAGE"

    smoke_one "$ARCH" "$IMAGE"

    if [ "$PUSH" = "1" ]; then
        hdr "push $IMAGE"
        run push "$IMAGE" \
            || fail "docker push failed for $IMAGE — check 'docker login $REGISTRY' and Feed Administrator rights on 'main'"
        pass "pushed $IMAGE"

        if [ "$VERIFY_PULL" = "1" ]; then
            hdr "verify fresh pull $IMAGE"
            run image rm "$IMAGE" >/dev/null 2>&1 || true
            run pull "$IMAGE" || fail "fresh pull failed for $IMAGE"
            pass "round-trip ok: $IMAGE"
        fi
    else
        echo "[SKIP] PUSH=0 — not publishing $IMAGE"
    fi

    if [ "$E2E" = "1" ]; then
        hdr "e2e acceptance $ARCH (run_prebake.sh)"
        if [ "$DRY_RUN" = "1" ]; then
            echo "    DRY_RUN: REGISTRY=$REGISTRY MIRROR_VER=$MIRROR_VER $SCRIPT_DIR/run_prebake.sh $ARCH"
        else
            REGISTRY="$REGISTRY" MIRROR_VER="$MIRROR_VER" \
                "$SCRIPT_DIR/run_prebake.sh" "$ARCH" \
                || fail "e2e acceptance failed for $ARCH"
        fi
        pass "e2e ok: $ARCH"
    fi

    OK_ARCHES+=("$ARCH")
done

hdr "done"
echo "arches processed: ${OK_ARCHES[*]}"
echo "tag: $MIRROR_VER   registry: $REGISTRY/library/grpc-tc-mirror-<arch>"
[ "$PUSH" = "1" ] || echo "(PUSH=0 — nothing was published)"
[ "$DRY_RUN" = "1" ] && echo "(DRY_RUN — nothing was executed)"
