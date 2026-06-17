#!/bin/bash
# ensure_proget.sh — идемпотентная привязка ProGet к conan home на каждый прогон.
# Вызывается build-драйверами сразу после появления conan в PATH. Безопасен
# везде: без env PROGET_/CONAN_REMOTE это no-op, так что Mac и голая dev-VM
# работают как раньше.
#
# Связь с запечённым global.conf: Dockerfile.grpc-tc-mirror зашивает строку
# backup-sources в /root/.conan2/global.conf образа. Это покрывает обычный
# `docker run` (без volume) и СВЕЖИЙ named volume (Docker засевает пустой volume
# из слоя образа). Но ПЕРЕИСПОЛЬЗОВАННЫЙ conan-cache-* volume, смонтированный
# поверх /root/.conan2, перекрывает этот слой и несёт свой global.conf, а
# `docker volume rm` / FRESH_CACHE его сбрасывает. Поэтому скрипт переустанавливает
# строку на каждом старте драйвера — единственная схема, переживающая все случаи,
# включая голую dev-VM / Mac, где образа нет вообще.
#
# Env:
#   PROGET_SOURCES_URL     база backup-sources, напр.
#                          http://proget.inc.elara.local/endpoints/conan-sources/content/
#                          (Dockerfile.grpc-tc-mirror задаёт по умолчанию;
#                          отключить через -e PROGET_SOURCES_URL="")
#   CONAN_REMOTE           имя remote для регистрации (напр. proget); пусто = пропустить
#   CONAN_REMOTE_URL       URL remote, напр. http://proget.inc.elara.local/conan/conan
#   CONAN_REMOTE_INSECURE  1 = передать --insecure (самоподписанный TLS)
#
# Аутентификация remote — нативная для conan, здесь не настраивается:
#   env CONAN_LOGIN_USERNAME / CONAN_PASSWORD, либо `conan remote login`.

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
