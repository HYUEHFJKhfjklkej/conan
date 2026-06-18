#!/bin/bash
# free_space.sh — освободить место на диске dev-VM (корень переполняется от
# docker build-кэша, conan-cache-volume'ов и output-* папок предыдущих сборок).
#
# Безопасно по умолчанию: трогает только кэши и build-выходы, которые
# пересобираются; .nupkg в output-* сохраняет. Показывает df до/после и сколько
# освободил.
#
# Запуск на dev-VM (docker обычно под sudo):
#   sudo bash -c 'cd /home/user/conan-master && ./test-astra/free_space.sh'
#
# Уровни (env):
#   DRY_RUN=1     только показать, что и сколько будет удалено, ничего не трогать
#   VOLUMES=0     НЕ чистить неиспользуемые docker-volume'ы (по умолч. 1 — чистить)
#   KEEP_NUPKG=0  удалить и .nupkg из output-* целиком (по умолч. 1 — сохранять)
#   IMAGES=1      дополнительно docker image prune -af — снести НЕиспользуемые
#                 образы, включая mirror/base (пересоберутся). По умолч. 0.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT_DIR="$(dirname "$SCRIPT_DIR")"

DRY_RUN="${DRY_RUN:-0}"
VOLUMES="${VOLUMES:-1}"
KEEP_NUPKG="${KEEP_NUPKG:-1}"
IMAGES="${IMAGES:-0}"

hdr() { printf '\n=== %s ===\n' "$1"; }

# docker напрямую, иначе passwordless sudo, иначе как есть (скрипт под sudo).
if docker info >/dev/null 2>&1; then DOCKER=(docker)
elif sudo -n docker info >/dev/null 2>&1; then DOCKER=(sudo -n docker)
else DOCKER=(docker); fi

# do <команда...> — выполнить, либо только напечатать под DRY_RUN.
do_() {
    if [ "$DRY_RUN" = "1" ]; then printf '   [DRY] %s\n' "$*"; else "$@"; fi
}

# Свободно на корне в КБ (для подсчёта освобождённого).
avail_kb() { df -P / | awk 'NR==2 {print $4}'; }

echo "###############################################"
echo "#  free_space.sh  (DRY_RUN=$DRY_RUN  VOLUMES=$VOLUMES  KEEP_NUPKG=$KEEP_NUPKG  IMAGES=$IMAGES)"
echo "###############################################"
hdr "Диск ДО"
df -h /
BEFORE_KB="$(avail_kb)"

hdr "Что занимает docker"
"${DOCKER[@]}" system df 2>/dev/null || echo "  (docker недоступен)"

hdr "output-* в репо"
du -sh "$ROOT_DIR"/output-* 2>/dev/null | sort -h || echo "  (нет output-*)"

# 1. Docker build-кэш — обычно самый жирный кусок.
hdr "1. docker build-кэш (builder prune)"
do_ "${DOCKER[@]}" builder prune -af

# 2. Остановленные контейнеры.
hdr "2. остановленные контейнеры"
do_ "${DOCKER[@]}" container prune -f

# 3. Неиспользуемые volume'ы (conan-cache-*). Пересоздаются на следующей сборке.
if [ "$VOLUMES" = "1" ]; then
    hdr "3. неиспользуемые docker-volume'ы (conan-cache-*)"
    do_ "${DOCKER[@]}" volume prune -f
else
    hdr "3. docker-volume'ы — пропуск (VOLUMES=0)"
fi

# 4. conan-кэши внутри output-* (бинд-маунты test_all_profiles). .nupkg остаются.
hdr "4. conan-кэши в output-*/conan-cache"
for d in "$ROOT_DIR"/output-*/conan-cache; do
    [ -e "$d" ] || continue
    echo "  rm: $d  ($(du -sh "$d" 2>/dev/null | cut -f1))"
    do_ rm -rf "$d"
done

# 5. Если KEEP_NUPKG=0 — снести output-* целиком (вместе с .nupkg).
if [ "$KEEP_NUPKG" = "0" ]; then
    hdr "5. output-* целиком (KEEP_NUPKG=0 — включая .nupkg)"
    for d in "$ROOT_DIR"/output-*; do
        [ -e "$d" ] || continue
        echo "  rm: $d  ($(du -sh "$d" 2>/dev/null | cut -f1))"
        do_ rm -rf "$d"
    done
else
    hdr "5. .nupkg в output-* сохранены (KEEP_NUPKG=1)"
fi

# 6. pip-кэш и старые build/pull-логи в /tmp.
hdr "6. pip-кэш + /tmp логи"
do_ rm -rf /root/.cache/pip "$HOME/.cache/pip"
do_ rm -f /tmp/build-*.log /tmp/pull-*.log

# 7. Опционально — неиспользуемые образы (mirror/base пересоберутся).
if [ "$IMAGES" = "1" ]; then
    hdr "7. неиспользуемые docker-образы (IMAGES=1)"
    do_ "${DOCKER[@]}" image prune -af
else
    hdr "7. образы не трогаем (IMAGES=1 чтобы снести неиспользуемые)"
fi

hdr "Диск ПОСЛЕ"
df -h /
AFTER_KB="$(avail_kb)"

if [ "$DRY_RUN" != "1" ]; then
    FREED_KB=$(( AFTER_KB - BEFORE_KB ))
    awk -v k="$FREED_KB" 'BEGIN { printf "\n[OK] Освобождено ~ %.1f ГБ\n", k/1024/1024 }'
else
    echo ""
    echo "[DRY_RUN] ничего не удалено. Убери DRY_RUN=1, чтобы выполнить."
fi
