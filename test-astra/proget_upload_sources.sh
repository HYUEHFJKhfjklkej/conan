#!/bin/bash
# proget_upload_sources.sh — one-time seeding of a ProGet Asset Directory
# with every offline source tarball from <pkg>/src/*.tar.gz, laid out the
# way Conan 2 "backup sources" expects:
#
#     <feed>/content/<sha256>            the tarball itself (blob)
#     <feed>/content/<sha256>.json       minimal backup metadata
#     <feed>/content/by-name/<pkg>/<file>   human-browsable copy (optional)
#
# After seeding, any agent with this line in $(conan config home)/global.conf:
#
#     core.sources:download_urls=["<PROGET_URL>/endpoints/<FEED>/content/", "origin"]
#
# resolves source() downloads from ProGet by sha256 — conandata.yml stays
# 100% upstream (contract: never edit conandata URLs/sha256). The bundled
# src/*.tar.gz copies keep working as the first-priority fallback until we
# decide to drop them from git.
#
# Run from the dev-VM (ProGet is reachable only there). Idempotent: blobs
# already present on the feed are skipped (HEAD check), so re-running after
# adding a new version uploads only the new tarball.
#
# Usage:
#   PROGET_API_KEY=...  ./test-astra/proget_upload_sources.sh
#   DRY_RUN=1           ./test-astra/proget_upload_sources.sh   # print, no network
#
# Env:
#   PROGET_URL       default https://proget.inc.elara.local
#   SOURCES_FEED     Asset Directory name, default conan-sources
#                    (create first: Feeds -> Create New Feed -> Asset Directory)
#   PROGET_API_KEY   API key with upload rights on the feed (X-ApiKey header)
#   PROGET_USER/PROGET_PASS   basic-auth alternative to the API key
#   PROGET_INSECURE  1 = curl -k (self-signed TLS; see HELP [X] for the
#                    proper CA-install fix)
#   BY_NAME          1 (default) = also upload by-name/<pkg>/<file> copies;
#                    0 = blobs only (halves upload time/space)
#   DRY_RUN          1 = compute and print everything, no uploads
#
# Exit: non-zero if any upload failed; summary table always printed.

set -uo pipefail

PROGET_URL="${PROGET_URL:-https://proget.inc.elara.local}"
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

# sha256 tool: dev-VM/Linux has sha256sum, macOS has shasum.
if command -v sha256sum >/dev/null 2>&1; then
    sha256_of() { sha256sum "$1" | awk '{print $1}'; }
else
    sha256_of() { shasum -a 256 "$1" | awk '{print $1}'; }
fi

put_file() {  # put_file <local-path> <remote-rel-path>
    if [ -n "$DRY_RUN" ]; then
        echo "    DRY_RUN: PUT $API_BASE/$2"
        return 0
    fi
    curl "${CURL_OPTS[@]}" -X PUT --upload-file "$1" "$API_BASE/$2" >/dev/null
}

remote_exists() {  # remote_exists <remote-rel-path>
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
        # Minimal backup-sources metadata; Conan only needs the blob to
        # download, the .json keeps `conan upload` backup merges happy.
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
