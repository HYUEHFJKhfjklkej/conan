#!/bin/bash
# clear_cache.sh — wipe the Conan cache so a rebuild re-runs source() and can
# pull tarballs from ProGet backup-sources instead of reusing what is cached.
#
# Two modes (auto-picked by env):
#   venv   (default)  conan remove "<pattern>" -c        — bare dev-VM / Mac
#   docker (VOLUME=)  sudo docker volume rm "<VOLUME>"   — mirror containers
#
# IMPORTANT — clearing the cache is necessary but NOT sufficient to fetch from
# ProGet. The recipe's source() prefers the bundled src/<pkg>-<ver>.tar.gz and
# only falls into get() (-> backup-sources -> ProGet) when that file is absent.
# To actually exercise the ProGet path you must ALSO move the bundled archive
# aside, e.g.  `mv zlib/src zlib/src.off`  (restore afterwards). See HELP [16].
#
# Usage:
#   ./test-astra/clear_cache.sh                 # venv: conan remove "*" -c
#   ./test-astra/clear_cache.sh "zlib/*"        # venv: remove just zlib
#   VOLUME=conan-cache-x86_64 ./test-astra/clear_cache.sh   # docker volume
#
# Env:
#   VOLUME   docker volume name to remove (switches to docker mode). Known:
#            conan-cache-x86_64 / -arm / -arm64 / -arm-diag /
#            conan-cache-legacy-x86_64 / -grpc-1601-upstream / -grpc-1781-upstream
#   NO_SUDO  1 = drop the `sudo` prefix on docker (rootless / already root)

set -uo pipefail

VOLUME="${VOLUME:-}"

if [ -n "$VOLUME" ]; then
    # ----- docker volume mode --------------------------------------------
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

# ----- venv (local conan) mode -------------------------------------------
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
