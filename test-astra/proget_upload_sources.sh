#!/bin/bash
# proget_upload_sources.sh — разовое наполнение ProGet Asset Directory всеми
# offline-тарболами <pkg>/src/*.tar.gz в раскладке, которую ждёт Conan 2
# "backup sources":
#
#     <feed>/content/<sha256>            сам тарбол (blob)
#     <feed>/content/<sha256>.json       минимальные backup-метаданные
#     <feed>/content/by-name/<pkg>/<file>   browsable-копия (опционально)
#
# После наполнения любой агент с этой строкой в $(conan config home)/global.conf:
#
#     core.sources:download_urls=["<PROGET_URL>/endpoints/<FEED>/content/", "origin"]
#
# резолвит source()-загрузки из ProGet по sha256 — conandata.yml остаётся
# 100% upstream (контракт: не править URL/sha256). Бандл src/*.tar.gz остаётся
# первым fallback'ом, пока не решим убрать его из git.
#
# Запуск с dev-VM (ProGet доступен только там). Идемпотентно: blob'ы, уже
# присутствующие на фиде, пропускаются (HEAD-проверка) — повторный прогон
# после добавления версии заливает только новый тарбол.
#
# Использование:
#   PROGET_API_KEY=...  ./test-astra/proget_upload_sources.sh
#   DRY_RUN=1           ./test-astra/proget_upload_sources.sh   # печать, без сети
#
# Env:
#   PROGET_URL       по умолч. http://proget.inc.elara.local
#   SOURCES_FEED     имя Asset Directory, по умолч. conan-sources
#                    (создать: Feeds -> Create New Feed -> Asset Directory)
#   PROGET_API_KEY   ключ с правами upload на фид (заголовок X-ApiKey)
#   PROGET_USER/PROGET_PASS   альтернатива ключу через basic-auth
#   PROGET_INSECURE  1 = curl -k (self-signed TLS; правильный фикс через
#                    установку CA — см. HELP [X])
#   BY_NAME          1 (по умолч.) = заливать ещё и by-name/<pkg>/<file>;
#                    0 = только blob'ы (вдвое меньше времени/места)
#   DRY_RUN          1 = всё посчитать и напечатать, без заливки
#
# Exit: non-zero если хоть один upload упал; итоговая таблица печатается всегда.

set -uo pipefail

PROGET_URL="${PROGET_URL:-http://proget.inc.elara.local}"
SOURCES_FEED="${SOURCES_FEED:-conan-sources}"
BY_NAME="${BY_NAME:-1}"
DRY_RUN="${DRY_RUN:-}"
API_BASE="$PROGET_URL/endpoints/$SOURCES_FEED/content"

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT_DIR="$(dirname "$SCRIPT_DIR")"

CURL_OPTS=(-fsS --connect-timeout 10)
[ "${PROGET_INSECURE:-}" = "1" ] && CURL_OPTS+=(-k)
if [ -n "${PROGET_API_KEY:-}" ]; then
    CURL_OPTS+=(-H "X-ApiKey: $PROGET_API_KEY")
elif [ -n "${PROGET_USER:-}" ]; then
    CURL_OPTS+=(-u "$PROGET_USER:${PROGET_PASS:-}")
fi

# sha256: на dev-VM/Linux есть sha256sum, на macOS — shasum.
if command -v sha256sum >/dev/null 2>&1; then
    sha256_of() { sha256sum "$1" | awk '{print $1}'; }
else
    sha256_of() { shasum -a 256 "$1" | awk '{print $1}'; }
fi

put_file() {  # put_file <локальный-путь> <удалённый-rel-путь>
    if [ -n "$DRY_RUN" ]; then
        echo "    DRY_RUN: PUT $API_BASE/$2"
        return 0
    fi
    curl "${CURL_OPTS[@]}" -X PUT --upload-file "$1" "$API_BASE/$2" >/dev/null
}

remote_exists() {  # remote_exists <удалённый-rel-путь>
    [ -n "$DRY_RUN" ] && return 1
    curl "${CURL_OPTS[@]}" -o /dev/null -I "$API_BASE/$1" >/dev/null 2>&1
}

echo "ProGet  : $API_BASE"
echo "Repo    : $ROOT_DIR"
[ -n "$DRY_RUN" ] && echo "Mode    : DRY RUN (no network)"
echo

TOTAL=0; UPLOADED=0; SKIPPED=0; FAILED=0
FAILED_LIST=""

for f in "$ROOT_DIR"/*/src/*.tar.gz; do
    [ -e "$f" ] || continue
    TOTAL=$((TOTAL + 1))
    pkg="$(basename "$(dirname "$(dirname "$f")")")"
    base="$(basename "$f")"
    sha="$(sha256_of "$f")"
    size="$(du -h "$f" | awk '{print $1}')"
    echo "[$pkg] $base ($size)"
    echo "    sha256: $sha"

    if remote_exists "$sha"; then
        echo "    already on feed — skip"
        SKIPPED=$((SKIPPED + 1))
        continue
    fi

    ok=1
    put_file "$f" "$sha" || ok=0
    if [ "$ok" = "1" ]; then
        # Минимальные backup-метаданные: для загрузки Conan'у нужен только
        # blob, а .json нужен, чтобы backup-merge при `conan upload` не ругался.
        json_tmp="$(mktemp)"
        printf '{"references": {"%s": ["%s"]}}\n' "$pkg" "$base" > "$json_tmp"
        put_file "$json_tmp" "$sha.json" || ok=0
        rm -f "$json_tmp"
    fi
    if [ "$ok" = "1" ] && [ "$BY_NAME" = "1" ]; then
        put_file "$f" "by-name/$pkg/$base" || ok=0
    fi

    if [ "$ok" = "1" ]; then
        echo "    uploaded"
        UPLOADED=$((UPLOADED + 1))
    else
        echo "    UPLOAD FAILED" >&2
        FAILED=$((FAILED + 1))
        FAILED_LIST="$FAILED_LIST $pkg/$base"
    fi
done

echo
echo "==== summary ===="
echo "total   : $TOTAL"
echo "uploaded: $UPLOADED"
echo "skipped : $SKIPPED (already on feed)"
echo "failed  : $FAILED${FAILED_LIST:+ —$FAILED_LIST}"

if [ "$TOTAL" = "0" ]; then
    echo "[FAIL] no */src/*.tar.gz found under $ROOT_DIR — wrong checkout?" >&2
    exit 1
fi
[ "$FAILED" = "0" ] || exit 1
