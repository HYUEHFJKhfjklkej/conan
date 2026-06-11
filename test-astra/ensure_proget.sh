#!/bin/bash
# ensure_proget.sh — idempotent per-run ProGet wiring for the conan home.
# Called by the build drivers right after conan lands on PATH. Safe to run
# anywhere: with no PROGET_/CONAN_REMOTE env set it is a no-op, so the Mac
# and bare dev-VM keep working exactly as before.
#
# Why per-run and not baked into the image: the conan home lives on the
# conan-cache-* docker volume (mounted over /root/.conan2), so anything
# baked into the image layer is shadowed, and FRESH_CACHE / `docker volume
# rm` wipes it. Re-asserting on every driver start is the only layout that
# survives both.
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
