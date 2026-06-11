#!/bin/bash
# proget_push_nupkg.sh — push built legacy .nupkg files to a ProGet NuGet
# feed. Default feed is a SANDBOX one (nuget-sandbox) so experiments never
# touch the production feed the downstream products consume — publishing
# there (overwrite vs LEGACY_NUPKG_VERSION_SUFFIX=.1) is the lead's call.
#
# Push endpoint per Inedo docs:
#     PUT https://<host>/nuget/<feed>/package   (body = the .nupkg)
# UNVERIFIED until run once against the real ProGet.
#
# Usage (dev-VM):
#   PROGET_API_KEY=<key> ./test-astra/proget_push_nupkg.sh output-grpc-1601-upstream
#   PROGET_API_KEY=<key> NUGET_FEED=nuget-sandbox ./test-astra/proget_push_nupkg.sh output/
#
# Env:
#   PROGET_URL       default https://proget.inc.elara.local
#   NUGET_FEED       default nuget-sandbox (create first: Feeds -> Create
#                    New Feed -> NuGet). NEVER point this at the production
#                    feed without the lead's sign-off.
#   PROGET_API_KEY   API key with Feed API rights (sent as X-ApiKey and
#                    X-NuGet-ApiKey — different ProGet versions read
#                    different headers)
#   PROGET_USER/PROGET_PASS   basic-auth alternative
#   PROGET_INSECURE  1 = curl -k
#   DRY_RUN          1 = print PUTs, no network

set -uo pipefail

DIR="${1:-}"
if [ -z "$DIR" ] || [ ! -d "$DIR" ]; then
    echo "usage: $0 <dir-with-nupkg>   (e.g. output-grpc-1601-upstream)" >&2
    exit 2
fi

PROGET_URL="${PROGET_URL:-https://proget.inc.elara.local}"
NUGET_FEED="${NUGET_FEED:-nuget-sandbox}"
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
