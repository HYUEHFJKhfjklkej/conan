#!/bin/bash
# tc_publish_conan.sh — публикация собранных .nupkg в NuGet-фид `conan` на ProGet.
# Отдельный шаг стадии GS900 PACKAGE: обходит read-only %ProGet.PrereleaseFeed%
# (феед задан явно), ключ приходит снаружи. Ничего не собирает — только заливает.
#
# Заливка — python3 (multipart PUT, как в легаси GS900-шаге): на билд-агентах
# ba-deb12-* нет curl, но есть python3 — легаси publish по той же причине питоновый.
#
# TeamCity build step (Command Line):
#   API_KEY=%ProGet.ApiKey% bash ./test-astra/tc_publish_conan.sh
#
# Env (все опциональны, дефолты под GS900):
#   API_KEY      ключ с правом Add/Repackage на фид (обязателен; в TC = %ProGet.ApiKey%)
#   PROGET_URL   по умолч. http://proget.inc.elara.local
#   FEED         по умолч. conan
#   NUPKG_DIR    папка с .nupkg (по умолч. nupkg), обходится рекурсивно
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

if [ -n "${DRY_RUN:-}" ]; then
    for f in "${PKGS[@]}"; do echo "[DRY] PUT $PUSH_URL  <= $(basename "$f")"; done
    echo; echo "залито ${#PKGS[@]}/${#PKGS[@]} (ошибок: 0)"
    exit 0
fi

python3 - "$API_KEY" "$PUSH_URL" "${PKGS[@]}" <<'PY'
import sys, os, http.client, ssl
from urllib.parse import urlparse

key, url = sys.argv[1], sys.argv[2]
pkgs = sys.argv[3:]
u = urlparse(url)
B = "ProGetConanBoundary12345"

ok = fail = 0
for f in pkgs:
    fn = os.path.basename(f)
    cd = 'form-data; name="package"; filename="%s"' % fn
    head = ("--%s\r\nContent-Disposition: %s\r\n"
            "Content-Type: application/octet-stream\r\n\r\n" % (B, cd)).encode()
    tail = ("\r\n--%s--\r\n" % B).encode()
    total = len(head) + os.path.getsize(f) + len(tail)
    try:
        if u.scheme == "https":
            c = http.client.HTTPSConnection(u.hostname, u.port or 443,
                                            context=ssl._create_unverified_context())
        else:
            c = http.client.HTTPConnection(u.hostname, u.port or 80)
        c.putrequest("PUT", u.path, skip_accept_encoding=True)
        c.putheader("X-ApiKey", key)
        c.putheader("X-NuGet-ApiKey", key)
        c.putheader("Content-Type", "multipart/form-data; boundary=" + B)
        c.putheader("Content-Length", str(total))
        c.endheaders()
        c.send(head)
        with open(f, "rb") as fh:
            while True:
                b = fh.read(1048576)
                if not b:
                    break
                c.send(b)
        c.send(tail)
        r = c.getresponse()
        code = r.status
        r.read()
        c.close()
    except Exception as e:
        print("[FAIL] %s = %s" % (fn, e), file=sys.stderr)
        fail += 1
        continue
    if code in (200, 201):
        print("[OK  %d] %s" % (code, fn)); ok += 1
    elif code == 409:
        # версия уже в фиде — не ошибка. ВНИМАНИЕ: 409 не сравнивает байты; пересборка
        # с фиксом под тем же номером НЕ доедет до фида — нужен version-suffix bump.
        print("[SKIP 409 уже в фиде] %s" % fn); ok += 1
    else:
        print("[FAIL %d] %s" % (code, fn), file=sys.stderr); fail += 1

print()
print("залито %d/%d (ошибок: %d)" % (ok, len(pkgs), fail))
sys.exit(0 if fail == 0 else 1)
PY
