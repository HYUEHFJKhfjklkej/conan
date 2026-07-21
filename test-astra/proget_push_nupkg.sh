#!/bin/bash
# proget_push_nupkg.sh — залить собранные legacy .nupkg в NuGet-фид ProGet.
# По умолчанию фид `conan` (NuGet-тип, заведён под собранные .nupkg) — это
# отдельный от production-фида downstream-продуктов канал, публикация в
# production (overwrite vs LEGACY_NUPKG_VERSION_SUFFIX=.1) решается лидом.
#
# Push-эндпоинт (Inedo docs):
#     PUT https://<host>/nuget/<feed>/package   (тело = .nupkg)
# Не проверено на живом ProGet.
#
# Использование (dev-VM):
#   PROGET_API_KEY=<key> ./test-astra/proget_push_nupkg.sh output-grpc-1601-upstream
#   PROGET_API_KEY=<key> NUGET_FEED=conan ./test-astra/proget_push_nupkg.sh output/
#
# Env:
#   PROGET_URL       по умолч. http://proget.inc.elara.local
#   NUGET_FEED       по умолч. conan (создан proget_create_nupkg_feed.sh или
#                    вручную: Feeds -> Create New Feed -> NuGet). НИКОГДА не
#                    указывать на production-фид без согласия лида.
#   PROGET_API_KEY   ключ с правами Feed API (шлётся как X-ApiKey и
#                    X-NuGet-ApiKey — разные версии ProGet читают разные заголовки)
#   PROGET_USER/PROGET_PASS   альтернатива через basic-auth
#   PROGET_INSECURE  1 = curl -k
#   DRY_RUN          1 = печатать PUT'ы, без сети

set -uo pipefail

DIR="${1:-}"
if [ -z "$DIR" ] || [ ! -d "$DIR" ]; then
    echo "usage: $0 <dir-with-nupkg>   (e.g. output-grpc-1601-upstream)" >&2
    exit 2
fi

PROGET_URL="${PROGET_URL:-http://proget.inc.elara.local}"
NUGET_FEED="${NUGET_FEED:-conan}"
DRY_RUN="${DRY_RUN:-}"
PUSH_URL="$PROGET_URL/nuget/$NUGET_FEED/package"

CURL_OPTS=(-fsS --connect-timeout 10)
[ "${PROGET_INSECURE:-}" = "1" ] && CURL_OPTS+=(-k)
if [ -n "${PROGET_API_KEY:-}" ]; then
    CURL_OPTS+=(-H "X-ApiKey: $PROGET_API_KEY" -H "X-NuGet-ApiKey: $PROGET_API_KEY")
elif [ -n "${PROGET_USER:-}" ]; then
    CURL_OPTS+=(-u "$PROGET_USER:${PROGET_PASS:-}")
fi

echo "Feed : $PUSH_URL"
echo "Dir  : $DIR"
[ -n "$DRY_RUN" ] && echo "Mode : DRY RUN"
echo

TOTAL=0; PUSHED=0; FAILED=0
for f in "$DIR"/*.nupkg; do
    [ -e "$f" ] || continue
    TOTAL=$((TOTAL + 1))
    echo "[PUSH] $(basename "$f")"
    if [ -n "$DRY_RUN" ]; then
        echo "    DRY_RUN: PUT $PUSH_URL"
        PUSHED=$((PUSHED + 1))
        continue
    fi
    if curl "${CURL_OPTS[@]}" -X PUT --upload-file "$f" "$PUSH_URL" >/dev/null; then
        PUSHED=$((PUSHED + 1))
    else
        echo "    FAILED" >&2
        FAILED=$((FAILED + 1))
    fi
done

echo
echo "pushed $PUSHED/$TOTAL (failed: $FAILED)"
if [ "$TOTAL" = "0" ]; then
    echo "[FAIL] no .nupkg in $DIR" >&2
    exit 1
fi
[ "$FAILED" = "0" ] || exit 1
