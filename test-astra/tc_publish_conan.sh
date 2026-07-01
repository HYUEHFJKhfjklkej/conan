#!/bin/bash
# tc_publish_conan.sh — публикация собранных .nupkg в NuGet-фид `conan` на ProGet.
# Отдельный шаг стадии GS900 PACKAGE: обходит read-only %ProGet.PrereleaseFeed%
# (феед задан явно), ключ приходит снаружи. Ничего не собирает — только заливает.
#
# TeamCity build step (Command Line):
#   API_KEY=%ProGet.ApiKey% ./test-astra/tc_publish_conan.sh
#
# Env (все опциональны, дефолты под GS900):
#   API_KEY      ключ с правом Add/Repackage на фид (обязателен; в TC = %ProGet.ApiKey%)
#   PROGET_URL   по умолч. http://proget.inc.elara.local
#   FEED         по умолч. conan
#   NUPKG_DIR    папка с .nupkg (по умолч. nupkg), обходится рекурсивно
#   INSECURE=1   curl -k
#   DRY_RUN=1    печатать план, без сети

set -uo pipefail

API_KEY="${API_KEY:-}"
PROGET_URL="${PROGET_URL:-http://proget.inc.elara.local}"
FEED="${FEED:-conan}"
NUPKG_DIR="${NUPKG_DIR:-nupkg}"
PUSH_URL="$PROGET_URL/nuget/$FEED/package"

if [ -z "$API_KEY" ]; then
    echo "[FAIL] API_KEY не задан (в TC: API_KEY=%ProGet.ApiKey%)" >&2
    exit 2
fi
if [ ! -d "$NUPKG_DIR" ]; then
    echo "[FAIL] нет папки '$NUPKG_DIR' с .nupkg" >&2
    exit 2
fi

PKGS=()
while IFS= read -r f; do PKGS+=("$f"); done < <(find "$NUPKG_DIR" -type f -name '*.nupkg' | sort)
if [ "${#PKGS[@]}" -eq 0 ]; then
    echo "[FAIL] в '$NUPKG_DIR' нет .nupkg" >&2
    exit 1
fi

echo "Feed : $PUSH_URL"
echo "Dir  : $NUPKG_DIR  (найдено ${#PKGS[@]} .nupkg)"
[ -n "${DRY_RUN:-}" ] && echo "Mode : DRY RUN"
echo

CURL=(curl -sS --connect-timeout 10 -w '%{http_code}' -o /dev/null
      -H "X-ApiKey: $API_KEY" -H "X-NuGet-ApiKey: $API_KEY")
[ "${INSECURE:-}" = "1" ] && CURL+=(-k)

OK=0; FAIL=0
for f in "${PKGS[@]}"; do
    name="$(basename "$f")"
    if [ -n "${DRY_RUN:-}" ]; then
        echo "[DRY] PUT $PUSH_URL  <= $name"
        OK=$((OK + 1)); continue
    fi
    code="$("${CURL[@]}" -X PUT --upload-file "$f" "$PUSH_URL")"
    case "$code" in
        200|201) echo "[OK  $code] $name"; OK=$((OK + 1)) ;;
        409)     echo "[SKIP 409 уже в фиде] $name"; OK=$((OK + 1)) ;;  # версия уже есть — не ошибка
        *)       echo "[FAIL $code] $name" >&2; FAIL=$((FAIL + 1)) ;;
    esac
done

echo
echo "залито $OK/${#PKGS[@]} (ошибок: $FAIL)"
[ "$FAIL" -eq 0 ] || exit 1
