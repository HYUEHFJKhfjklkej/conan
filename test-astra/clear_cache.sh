#!/bin/bash
# clear_cache.sh — чистит кэш Conan, чтобы пересборка заново отработала source()
# и могла тянуть тарболы из ProGet backup-sources вместо закэшированных.
#
# Два режима (выбираются по env):
#   venv   (по умолчанию)  conan remove "<pattern>" -c        — голая dev-VM / Mac
#   docker (VOLUME=)       sudo docker volume rm "<VOLUME>"   — mirror-контейнеры
#
# ВАЖНО: чистки кэша недостаточно, чтобы тянуть из ProGet. source() в рецепте
# предпочитает локальный src/<pkg>-<ver>.tar.gz и уходит в get() (-> backup-sources
# -> ProGet) только когда этого файла нет. Чтобы реально пройти путь через ProGet,
# нужно ещё убрать локальный архив, напр. `mv zlib/src zlib/src.off` (потом вернуть).
# См. HELP [16].
#
# Usage:
#   ./test-astra/clear_cache.sh                 # venv: conan remove "*" -c
#   ./test-astra/clear_cache.sh "zlib/*"        # venv: только zlib
#   VOLUME=conan-cache-x86_64 ./test-astra/clear_cache.sh   # docker volume
#
# Env:
#   VOLUME   имя docker volume для удаления (включает docker-режим). Известные:
#            conan-cache-x86_64 / -arm / -arm64 / -arm-diag /
#            conan-cache-legacy-x86_64 / -grpc-1601-upstream / -grpc-1781-upstream
#   NO_SUDO  1 = убрать префикс `sudo` у docker (rootless / уже root)

set -uo pipefail

VOLUME="${VOLUME:-}"

if [ -n "$VOLUME" ]; then
    # ----- docker volume режим -------------------------------------------
    SUDO="sudo"
    [ "${NO_SUDO:-}" = "1" ] && SUDO=""
    echo "[INFO] clear_cache: removing docker volume '$VOLUME'"
    if $SUDO docker volume rm "$VOLUME" >/dev/null 2>&1; then
        echo "[OK]   volume '$VOLUME' removed (next run starts from a fresh cache)"
    else
        echo "[INFO] volume '$VOLUME' not present (or in use) — nothing to remove"
    fi
    echo "[NOTE] global.conf download_urls lives on this volume too; ensure_proget.sh"
    echo "       re-adds it on the next driver start (PROGET_SOURCES_URL default)."
    echo "[NOTE] also move the bundled src/ aside inside the container to hit ProGet."
    exit 0
fi

# ----- venv (локальный conan) режим --------------------------------------
PATTERN="${1:-*}"

command -v conan >/dev/null 2>&1 || {
    echo "[FAIL] conan not on PATH — activate the venv first (source venv/bin/activate)" >&2
    exit 1
}

echo "[INFO] clear_cache: conan remove \"$PATTERN\" -c"
conan remove "$PATTERN" -c
echo "[OK]   cache cleared for pattern: $PATTERN"
echo "[NOTE] to fetch sources from ProGet, also disable the bundled fallback, e.g.:"
echo "         mv zlib/src zlib/src.off   # then conan create ...   then restore"
echo "       and confirm download_urls is set:"
echo "         grep download_urls \"\$(conan config home)/global.conf\""
