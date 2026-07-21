#!/bin/bash
# proget_create_nupkg_feed.sh — создать ОТДЕЛЬНЫЙ NuGet-фид на ProGet под
# собранные Conan-ом legacy .nupkg, изолированный от боевого фида
# downstream-продуктов (чтобы conan-сборки не затирали production).
#
# Версионного гейта НЕТ: NuGet-фиды работают на любой версии ProGet, включая
# текущий 5.2.30 (Windows). Это «создать фид» поверх уже существующего пуша —
# proget_push_nupkg.sh заливает .nupkg в <NUGET_FEED> (PUT /nuget/<feed>/package).
# Здесь: идемпотентное создание самого фида + (опц.) проверка пушем и листингом.
#
# Management API (Inedo docs):
#     POST <url>/api/management/feeds/create   (тело = JSON, заголовок X-ApiKey)
#     GET  <url>/api/management/feeds/get/<name>
# NuGet-эндпоинт фида: <url>/nuget/<feed>.
#
# Использование (dev-VM — ProGet доступен только оттуда):
#   PROGET_API_KEY=<key> ./test-astra/proget_create_nupkg_feed.sh
#   DRY_RUN=1            ./test-astra/proget_create_nupkg_feed.sh   # печать, без сети
#   # создать + сразу проверить, залив собранные .nupkg:
#   PROGET_API_KEY=<key> PUSH_DIR=output-grpc-1601-upstream \
#       ./test-astra/proget_create_nupkg_feed.sh
#
# Env:
#   PROGET_URL       по умолч. http://proget.inc.elara.local
#   NUGET_FEED       имя создаваемого фида, по умолч. conan
#   PROGET_API_KEY   ключ с правами Feed Management API (заголовок X-ApiKey)
#   PROGET_USER/PROGET_PASS   альтернатива ключу через basic-auth
#   PROGET_INSECURE  1 = curl -k (self-signed TLS)
#   VERIFY           1 (по умолч.) = после создания проверить листингом фида;
#                    если задан PUSH_DIR — сперва залить туда .nupkg
#   PUSH_DIR         каталог с .nupkg для проверки (делегирует proget_push_nupkg.sh)
#   DRY_RUN          1 = печатать запросы, без сети
#
# СТАТУС: UNVERIFIED — create через Management API на живом ProGet не прогонялся.
# Сперва DRY_RUN=1, свериться с ответами, потом боевой. Exit non-zero на ошибке.

set -euo pipefail

PROGET_URL="${PROGET_URL:-http://proget.inc.elara.local}"
NUGET_FEED="${NUGET_FEED:-conan}"
VERIFY="${VERIFY:-1}"
PUSH_DIR="${PUSH_DIR:-}"
DRY_RUN="${DRY_RUN:-}"

MGMT_BASE="$PROGET_URL/api/management/feeds"
NUGET_BASE="$PROGET_URL/nuget/$NUGET_FEED"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

# Базовые curl-опции БЕЗ -f: для статус-проб нужен код ответа, а -f глотает
# тело ошибки и ломает разбор 404 vs 200.
CURL_BASE=(-sS --connect-timeout 10)
[ "${PROGET_INSECURE:-}" = "1" ] && CURL_BASE+=(-k)

AUTH=()
if [ -n "${PROGET_API_KEY:-}" ]; then
    AUTH=(-H "X-ApiKey: $PROGET_API_KEY")
elif [ -n "${PROGET_USER:-}" ]; then
    AUTH=(-u "$PROGET_USER:${PROGET_PASS:-}")
fi

say()  { echo "[INFO] $*"; }
warn() { echo "[WARN] $*" >&2; }
die()  { echo "[FAIL] $*" >&2; exit 1; }

echo "ProGet : $PROGET_URL"
echo "Feed   : $NUGET_FEED  ($NUGET_BASE)  [type: nuget]"
[ -n "$DRY_RUN" ] && echo "Mode   : DRY RUN (no network)"
echo

# --- 1. Создать фид (идемпотентно) ------------------------------------------
feed_exists() {
    if [ -n "$DRY_RUN" ]; then
        echo "    DRY_RUN: GET $MGMT_BASE/get/$NUGET_FEED"
        return 1   # в DRY_RUN считаем, что фида нет — печатаем и create
    fi
    local code
    code="$(curl "${CURL_BASE[@]}" ${AUTH[@]+"${AUTH[@]}"} -o /dev/null \
        -w '%{http_code}' "$MGMT_BASE/get/$NUGET_FEED" || echo 000)"
    [ "$code" = "200" ]
}

create_feed() {
    local body code resp tmp
    body='{"name":"'"$NUGET_FEED"'","feedType":"nuget","active":true,"description":"Conan-built legacy .nupkg — IN-658 (separate from production)"}'
    if [ -n "$DRY_RUN" ]; then
        echo "    DRY_RUN: POST $MGMT_BASE/create"
        echo "             body: $body"
        return 0
    fi
    tmp="$(mktemp)"
    code="$(curl "${CURL_BASE[@]}" ${AUTH[@]+"${AUTH[@]}"} -X POST \
        -H 'Content-Type: application/json' --data "$body" \
        -o "$tmp" -w '%{http_code}' "$MGMT_BASE/create" || echo 000)"
    resp="$(cat "$tmp")"; rm -f "$tmp"
    case "$code" in
        2*)      say "фид '$NUGET_FEED' создан (HTTP $code)" ;;
        000)     die "не достучались до $MGMT_BASE/create — ProGet поднят и доступен с dev-VM?" ;;
        401|403) die "create вернул HTTP $code — ключ без прав Feed Management API" ;;
        *)       die "create вернул HTTP $code: $resp" ;;
    esac
}

# --- 2. Проверка: (опц.) залить .nupkg + листинг фида ------------------------
verify_feed() {
    # 2a. если задан PUSH_DIR — делегируем заливку существующему скрипту, но
    #     в НАШ фид (у proget_push_nupkg.sh дефолт nuget-sandbox — переопределяем).
    if [ -n "$PUSH_DIR" ]; then
        [ -d "$PUSH_DIR" ] || die "PUSH_DIR='$PUSH_DIR' не каталог"
        say "заливаю .nupkg из $PUSH_DIR в фид $NUGET_FEED (proget_push_nupkg.sh)"
        if [ -n "$DRY_RUN" ]; then
            echo "    DRY_RUN: NUGET_FEED=$NUGET_FEED $SCRIPT_DIR/proget_push_nupkg.sh $PUSH_DIR"
        else
            NUGET_FEED="$NUGET_FEED" "$SCRIPT_DIR/proget_push_nupkg.sh" "$PUSH_DIR" \
                || die "пуш .nupkg в '$NUGET_FEED' не прошёл — см. вывод выше"
        fi
    fi

    # 2b. листинг фида через OData (v2): фид жив и (если пушили) непустой.
    if [ -n "$DRY_RUN" ]; then
        echo "    DRY_RUN: GET $NUGET_BASE/Packages()  (ожидаем HTTP 200; счёт <entry>)"
        return 0
    fi
    local xml count
    xml="$(curl "${CURL_BASE[@]}" ${AUTH[@]+"${AUTH[@]}"} "$NUGET_BASE/Packages()" || true)"
    count="$(printf '%s' "$xml" | grep -c '<entry' || true)"
    say "фид отвечает; пакетов в листинге: $count"
    if [ -n "$PUSH_DIR" ] && [ "$count" = "0" ]; then
        warn "залили .nupkg, но листинг пуст — у ProGet/NuGet индексация бывает \
с задержкой; проверь UI или повтори листинг. Если стабильно 0 — права ключа."
    fi
}

# === поток ==================================================================
if feed_exists; then
    say "фид '$NUGET_FEED' уже существует — создание пропущено (идемпотентность)"
else
    create_feed
fi

if [ "$VERIFY" = "1" ]; then
    verify_feed
else
    say "VERIFY=0 — проверка пропущена (фид создан)"
fi

echo
say "готово. Заливать сборки в этот фид: NUGET_FEED=$NUGET_FEED ./test-astra/proget_push_nupkg.sh <output-dir>"
