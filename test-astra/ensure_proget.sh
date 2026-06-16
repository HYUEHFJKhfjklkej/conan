#!/bin/bash
# ensure_proget.sh — idempotent per-run ProGet wiring for the conan home.
# Called by the build drivers right after conan lands on PATH. Safe to run
# anywhere: with no PROGET_/CONAN_REMOTE env set it is a no-op, so the Mac
# and bare dev-VM keep working exactly as before.
#
# Relationship to the baked global.conf: Dockerfile.grpc-tc-mirror bakes the
# backup-sources line into the image's /root/.conan2/global.conf, which covers
# a plain `docker run` (no volume) and a FRESH named volume (Docker seeds an
# empty volume from the image layer). But a REUSED conan-cache-* volume mounted
# over /root/.conan2 shadows that layer and carries its own global.conf, and
# `docker volume rm` / FRESH_CACHE resets it. So this script re-asserts the
# line on every driver start — that is the one layout that survives all cases,
# including the bare dev-VM / Mac where there is no image at all.
#
# Env:
#   PROGET_SOURCES_URL     backup-sources base, e.g.
#                          http://proget.inc.elara.local/endpoints/conan-sources/content/
#                          (Dockerfile.grpc-tc-mirror sets this by default;
#                          override with -e PROGET_SOURCES_URL="" to disable)
#   CONAN_REMOTE           remote name to register (e.g. proget); empty = skip
#   CONAN_REMOTE_URL       remote URL, e.g. http://proget.inc.elara.local/conan/conan
#   CONAN_REMOTE_INSECURE  1 = pass --insecure (self-signed TLS)
#
# Auth for the remote is conan-native, no wiring needed here:
#   CONAN_LOGIN_USERNAME / CONAN_PASSWORD env vars, or `conan remote login`.

set -uo pipefail

command -v conan >/dev/null 2>&1 || exit 0
CONAN_HOME_DIR="$(conan config home 2>/dev/null)" || exit 0
[ -n "$CONAN_HOME_DIR" ] || exit 0

# --- backup-sources -----------------------------------------------------
URL="${PROGET_SOURCES_URL:-}"
if [ -n "$URL" ]; then
    CONF="$CONAN_HOME_DIR/global.conf"
    LINE="core.sources:download_urls=[\"$URL\", \"origin\"]"
    mkdir -p "$CONAN_HOME_DIR"
    if [ -f "$CONF" ] && grep -q '^core\.sources:download_urls=' "$CONF"; then
        if grep -qF "$LINE" "$CONF"; then
            echo "[INFO] ensure_proget: backup-sources already configured -> $URL"
        else
            grep -v '^core\.sources:download_urls=' "$CONF" > "$CONF.tmp" \
                && mv "$CONF.tmp" "$CONF"
            printf '%s\n' "$LINE" >> "$CONF"
            echo "[INFO] ensure_proget: backup-sources URL updated -> $URL"
        fi
    else
        printf '%s\n' "$LINE" >> "$CONF"
        echo "[INFO] ensure_proget: backup-sources enabled -> $URL"
    fi
else
    echo "[INFO] ensure_proget: PROGET_SOURCES_URL empty — backup-sources OFF"
fi

# --- conan remote -------------------------------------------------------
REMOTE="${CONAN_REMOTE:-}"
REMOTE_URL="${CONAN_REMOTE_URL:-}"
if [ -n "$REMOTE" ] && [ -n "$REMOTE_URL" ]; then
    if ! conan remote list 2>/dev/null | grep -q "^$REMOTE:"; then
        EXTRA=()
        [ "${CONAN_REMOTE_INSECURE:-}" = "1" ] && EXTRA=(--insecure)
        if conan remote add "$REMOTE" "$REMOTE_URL" "${EXTRA[@]}"; then
            echo "[INFO] ensure_proget: remote '$REMOTE' -> $REMOTE_URL"
        else
            echo "[WARN] ensure_proget: conan remote add $REMOTE failed" >&2
        fi
    fi
fi
exit 0
