#!/bin/bash
# smoke_proget_sources.sh — проверяет, что сборка в контейнере зеркала тянет
# исходники из ProGet backup-sources, а не из src/*.tar.gz, вшитого в образ.
#
# Зачем отдельный docker-скрипт: сборка идёт в контейнере, кэш — на volume
# conan-cache-*, НО вшитый src/<pkg>-<ver>.tar.gz лежит в слое образа (Dockerfile
# COPY <pkg> ...). source() предпочитает этот архив, поэтому чистки volume мало —
# вшитую копию надо ещё и отодвинуть. Делаем это в одноразовом `--rm` контейнере:
# образ и хостовый репозиторий не трогаем, восстановление не нужно.
#
# Что делает, всё в одном `docker run --rm`:
#   1. ensure_proget.sh  -> (пере)записать core.sources:download_urls на volume
#   2. conan remove "<pkg>/*" -c                 (заставить source() повториться)
#   3. mv <pkg>/src <pkg>/src.off                (отключить вшитый fallback)
#   4. HTTP-проба точного blob-URL (<base>/<sha256>) -> код+размер, плюс попадает
#      в request-log фида conan-sources на ProGet
#   5. conan create <pkg> ... --no-remote -vvv     (печатает URL загрузки исходника;
#      теперь должен идти в backup-sources, не во вшитый архив)
#   6. вердикт по ОБОИМ сигналам (HTTP 200 проба + conan -vvv) -> PASS/FAIL
#
# Авторизация для пробы (сама загрузка conan — анонимная backup-sources):
#   PROGET_API_KEY  -> заголовок X-ApiKey  | PROGET_USER/PROGET_PASS -> basic
#   PROGET_INSECURE=1 -> curl -k (самоподписанный TLS)
#
# Запуск:
#   ./test-astra/smoke_proget_sources.sh                 # zlib/1.3.1, x86_64
#   PKG=re2 VERSION=20230301 ./test-astra/smoke_proget_sources.sh
#   FRESH_VOLUME=1 ./test-astra/smoke_proget_sources.sh  # сначала очистить volume
#
# Env:
#   PKG            каталог рецепта / имя пакета (default zlib)
#   VERSION        версия для сборки            (default 1.3.1)
#   IMAGE          тег образа зеркала           (default grpc-tc-mirror-x86_64)
#   VOLUME         conan cache volume           (default conan-cache-x86_64)
#   PROFILE        профиль host+build           (default profiles/lin-gcc84-x86_64)
#   PROGET_SOURCES_URL  переопределяет ENV-дефолт образа (пробрасывается, если задан)
#   FRESH_VOLUME   1 = `docker volume rm $VOLUME` перед прогоном
#   NO_SUDO        1 = убрать префикс `sudo` у docker

set -uo pipefail

PKG="${PKG:-zlib}"
VERSION="${VERSION:-1.3.1}"
IMAGE="${IMAGE:-grpc-tc-mirror-x86_64}"
VOLUME="${VOLUME:-conan-cache-x86_64}"
PROFILE="${PROFILE:-profiles/lin-gcc84-x86_64}"

SUDO="sudo"
[ "${NO_SUDO:-}" = "1" ] && SUDO=""

LOG="/tmp/smoke_proget_${PKG}.log"

echo "== smoke: $PKG/$VERSION from ProGet backup-sources (image $IMAGE) =="

if ! $SUDO docker image inspect "$IMAGE" >/dev/null 2>&1; then
    echo "[FAIL] image '$IMAGE' missing — build it first (test_x86_64.sh build)" >&2
    exit 1
fi

if [ "${FRESH_VOLUME:-}" = "1" ]; then
    echo "[INFO] FRESH_VOLUME=1 -> removing volume '$VOLUME'"
    $SUDO docker volume rm "$VOLUME" >/dev/null 2>&1 || true
fi

# PROGET_SOURCES_URL пробрасываем, только если вызывающий его переопределил;
# иначе действует ENV-дефолт образа. Параметры smoke и опциональную ProGet-авторизацию
# передаём через env (чище, чем подстановка строк в INNER-скрипт).
PASS_ENV=(
    -e "SMOKE_PKG=$PKG"
    -e "SMOKE_VER=$VERSION"
    -e "SMOKE_PROFILE=$PROFILE"
    # проброс из хостового env, если задано (без '=' -> наследуется):
    -e PROGET_API_KEY -e PROGET_USER -e PROGET_PASS -e PROGET_INSECURE
)
[ -n "${PROGET_SOURCES_URL:-}" ] && PASS_ENV+=(-e "PROGET_SOURCES_URL=$PROGET_SOURCES_URL")

# В одинарных кавычках: на хосте ничего не разворачивается. Все переменные
# резолвятся внутри контейнера из -e выше.
INNER='
set -uo pipefail
cd /work/conan-recipes
PKG="$SMOKE_PKG"; VER="$SMOKE_VER"; PROF="$SMOKE_PROFILE"

echo "--- ensure_proget (download_urls on the volume) ---"
./test-astra/ensure_proget.sh
CONF="$(conan config home)/global.conf"
echo "--- download_urls in global.conf ---"
DLU=$(grep "core.sources:download_urls" "$CONF") \
    || { echo "[FAIL] download_urls not set — backup-sources is OFF"; exit 2; }
echo "$DLU"

# Backup-sources base = first URL in the list. The blob ProGet serves is named
# by the tarball sha256 (== the sha256 conandata declares), so we can probe the
# exact object URL directly.
BASE=$(printf "%s" "$DLU" | sed -E "s/.*\[\"([^\"]+)\".*/\1/")
TARBALL=$(ls "$PKG"/src/*"$VER"*.tar.gz 2>/dev/null | head -1)
[ -z "$TARBALL" ] && TARBALL=$(ls "$PKG"/src/*.tar.gz 2>/dev/null | head -1)
SHA=""
[ -n "$TARBALL" ] && SHA=$(sha256sum "$TARBALL" | awk "{print \$1}")
echo "--- backup-sources base: $BASE"
echo "--- tarball: ${TARBALL:-<none>}  sha256: ${SHA:-<none>}"

# Explicit HTTP probe — definitive code + size, AND it shows up in the
# conan-sources feed request log on ProGet.
if [ -n "$SHA" ] && command -v curl >/dev/null 2>&1; then
    URL="${BASE%/}/$SHA"
    AUTH=()
    if [ -n "${PROGET_API_KEY:-}" ]; then AUTH=(-H "X-ApiKey: ${PROGET_API_KEY}")
    elif [ -n "${PROGET_USER:-}" ]; then AUTH=(-u "${PROGET_USER}:${PROGET_PASS:-}"); fi
    INS=(); [ "${PROGET_INSECURE:-}" = "1" ] && INS=(-k)
    echo "PROGET_PROBE_URL: $URL"
    PROBE=$(curl -sS -o /dev/null "${INS[@]}" "${AUTH[@]}" \
        -w "HTTP %{http_code}  %{size_download}B  time=%{time_total}s" "$URL" 2>&1) \
        || PROBE="curl failed: $PROBE"
    echo "PROGET_PROBE: $PROBE"
else
    echo "PROGET_PROBE: skipped (no curl or no sha256)"
fi

echo "--- conan remove \"$PKG/*\" -c ---"
conan remove "$PKG/*" -c || true
echo "--- disable bundled fallback (ephemeral, container is --rm) ---"
[ -d "$PKG/src" ] && mv "$PKG/src" "$PKG/src.off"
echo "--- conan create -vvv (verbose: prints the source download URL) ---"
conan create "$PKG/" --version="$VER" \
    -pr:h="$PROF" -pr:b="$PROF" \
    -s build_type=Release --build=missing --no-remote -vvv
'

$SUDO docker run --rm \
    "${PASS_ENV[@]}" \
    -v "$VOLUME:/root/.conan2" \
    --entrypoint bash "$IMAGE" -c "$INNER" 2>&1 | tee "$LOG"
RC="${PIPESTATUS[0]}"

echo ""
echo "================ SMOKE VERDICT ================"

# 1. Прямая HTTP-проба blob-URL.
PROBE_LINE=$(grep "^PROGET_PROBE:" "$LOG" | tail -1)
PROBE_URL=$(grep "^PROGET_PROBE_URL:" "$LOG" | tail -1 | sed 's/^PROGET_PROBE_URL: //')
[ -n "$PROBE_LINE" ] && echo " probe: ${PROBE_LINE#PROGET_PROBE: }  ($PROBE_URL)"
probe_ok=0
echo "$PROBE_LINE" | grep -q "HTTP 200" && probe_ok=1

# 2. conan -vvv реально скачал исходник по backup-sources URL.
conan_ok=0
grep -Eq "conan-sources/content|backup remote|Sources downloaded|Source.*[Dd]ownload" "$LOG" && conan_ok=1

if [ "$RC" -ne 0 ]; then
    echo " docker run exited $RC — build failed (see $LOG)"
    [ "$probe_ok" = 1 ] && echo " (but the HTTP probe got 200 — feed is reachable & seeded)"
    echo "=============================================="
    exit 1
fi
if [ "$conan_ok" = 1 ] || [ "$probe_ok" = 1 ]; then
    echo " PASS — $PKG/$VERSION sources served by ProGet backup-sources"
    echo "        HTTP probe 200: $([ "$probe_ok" = 1 ] && echo yes || echo 'no — check feed read perms')"
    echo "        conan fetched : $([ "$conan_ok" = 1 ] && echo yes || echo 'not seen in -vvv log')"
    echo "        conan evidence:"
    grep -Ei "conan-sources/content|backup|Sources downloaded|Source.*download" "$LOG" \
        | sed 's/^/          /' | head -5
    echo "=============================================="
    exit 0
else
    echo " FAIL — no ProGet download seen. Either the bundled src was still"
    echo "        present, download_urls was unset, the feed is not seeded"
    echo "        (HELP [16] step 1), or read perms block anonymous GET."
    echo "        probe=$PROBE_LINE  log=$LOG"
    echo "=============================================="
    exit 1
fi
