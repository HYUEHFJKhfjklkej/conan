#!/bin/bash
# Патчит utf8_range.<...>.0.1.0.nupkg, чтобы его CMakeLists.var _dependencies
# ссылался на absl:0.2.0.1 (наш upstream-mirror, с cord) вместо absl:0.2.0
# (legacy Bitbucket, без cord). Бампит версию до 0.1.0.1, чтобы не
# столкнуться с оригиналом в ProGet.
#
# Usage:
#   ./test-astra/patch_utf8_range_dep.sh /path/to/utf8_range.lin.gcc84.shared.x86_64.0.1.0.nupkg
#
# Output:
#   ./utf8_range.lin.gcc84.shared.x86_64.0.1.0.1.nupkg
#
# Тег linkage (shared/static) берётся из 4-го dot-сегмента имени ВХОДНОГО
# файла. По умолчанию `shared` (слот DynamicRT — аналог GR113, куда смотрят
# downstream el_conf/grpc_sdk). Скрипт также обрабатывает вход static.x86_64,
# если кто-то целится в слот StaticRT (GR121).
#
# После запуска залить новый .nupkg в ProGet (он НЕ заменяет старый —
# добавляет более высокую версию, которую резолвер предпочтёт).

set -euo pipefail

if [ $# -lt 1 ]; then
    echo "Usage: $0 <utf8_range-nupkg-path>"
    echo ""
    echo "Tip: download the existing nupkg from ProGet web UI first, or"
    echo "find a local cached copy under ~/.nuget/ or in your ProGet"
    echo "package store. Pass its full path."
    exit 1
fi

IN_NUPKG="$1"
if [ ! -f "$IN_NUPKG" ]; then
    echo "ERROR: $IN_NUPKG does not exist"
    exit 1
fi

OLD_VER="0.1.0"
NEW_VER="0.1.0.1"
OLD_ABSL_DEP="absl:0.2.0"
NEW_ABSL_DEP="absl:0.2.0.1"

# Берём linkage (static/shared) из имени входного файла, по умолчанию shared.
IN_BASENAME="$(basename "$IN_NUPKG")"
LINKAGE="$(echo "$IN_BASENAME" | awk -F. '{print $4}')"
case "$LINKAGE" in
    static|shared) ;;
    *) LINKAGE="shared" ;;
esac

OUT_BASENAME="utf8_range.lin.gcc84.${LINKAGE}.x86_64.${NEW_VER}.nupkg"
OUT_NUPKG="$(pwd)/${OUT_BASENAME}"

WORK_DIR="$(mktemp -d -t utf8-patch.XXXXXX)"
trap 'rm -rf "$WORK_DIR"' EXIT

echo "[1/5] unpack $IN_NUPKG -> $WORK_DIR"
unzip -q "$IN_NUPKG" -d "$WORK_DIR"

echo "[2/5] patch CMakeLists.var: $OLD_ABSL_DEP -> $NEW_ABSL_DEP"
CMV="$WORK_DIR/CMakeLists.var"
if [ ! -f "$CMV" ]; then
    echo "ERROR: CMakeLists.var not found in nupkg"
    exit 1
fi
if grep -qF "$OLD_ABSL_DEP" "$CMV"; then
    sed -i "s|${OLD_ABSL_DEP}\$|${NEW_ABSL_DEP}|" "$CMV"
    sed -i "s| ${OLD_ABSL_DEP} | ${NEW_ABSL_DEP} |g" "$CMV"
    sed -i "s|^${OLD_ABSL_DEP}\$|${NEW_ABSL_DEP}|" "$CMV"
    echo "  patched _dependencies"
    grep -A5 _dependencies "$CMV" | head -20 | sed 's/^/    /'
else
    echo "  WARN: $OLD_ABSL_DEP not in CMakeLists.var — already patched? showing _dependencies:"
    grep -A10 _dependencies "$CMV" | head -20 | sed 's/^/    /'
fi

echo "[3/5] patch .nuspec: <version> -> $NEW_VER, dep absl -> $NEW_ABSL_DEP"
NUSPEC=$(find "$WORK_DIR" -maxdepth 1 -name "*.nuspec" | head -1)
if [ -z "$NUSPEC" ]; then
    echo "  WARN: no .nuspec in nupkg root"
else
    # бампим <version>
    sed -i "s|<version>${OLD_VER}</version>|<version>${NEW_VER}</version>|" "$NUSPEC"
    # бампим версию dep absl внутри <dependencies>
    sed -i 's|<dependency id="absl"[^/]*version="0\.2\.0"[^/]*/>|<dependency id="absl" version="0.2.0.1" />|' "$NUSPEC"
    grep -E '<version>|<dependency' "$NUSPEC" | sed 's/^/    /'
fi

echo "[4/5] repack -> $OUT_NUPKG"
rm -f "$OUT_NUPKG"
(cd "$WORK_DIR" && zip -qr "$OUT_NUPKG" .)

echo "[5/5] verify"
unzip -l "$OUT_NUPKG" | head -5 | sed 's/^/    /'
echo ""
echo "    CMakeLists.var _dependencies section in repacked nupkg:"
unzip -p "$OUT_NUPKG" CMakeLists.var | grep -A8 _dependencies | sed 's/^/    /'

echo ""
echo "[DONE] $OUT_NUPKG"
echo ""
echo "Next: upload to ProGet (web UI → Default feed → Add Package → upload .nupkg)"
echo "Then on dev-VM:"
echo "    rm -rf ~/utf8_range.lin.gcc84.${LINKAGE}.x86_64.0.1.0/"
echo "    rm -rf ~/utf8_range.lin.gcc84.${LINKAGE}.x86_64.0.1.0.1/  # in case"
echo "    cd ~/grpc_sdk/.build/lin.gcc.${LINKAGE}.x64 && rm -rf CMakeCache.txt CMakeFiles/ && bash 1.sh"
echo ""
echo "ProGet will keep both versions (0.1.0 and 0.1.0.1); resolver picks the"
echo "higher one because no consumer pins to exact 0.1.0."
