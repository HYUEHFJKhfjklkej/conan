#!/bin/bash
# Patch utf8_range.<...>.0.1.0.nupkg so its CMakeLists.var _dependencies
# refers to absl:0.2.0.1 (our upstream-mirror, has cord) instead of
# absl:0.2.0 (legacy Bitbucket, missing cord). Bump version to 0.1.0.1
# so it does not collide with the original in ProGet.
#
# Usage:
#   ./test-astra/patch_utf8_range_dep.sh /path/to/utf8_range.lin.gcc84.shared.x86_64.0.1.0.nupkg
#
# Output:
#   ./utf8_range.lin.gcc84.shared.x86_64.0.1.0.1.nupkg
#
# Linkage tag (shared/static) is derived from the INPUT filename's 4th
# dot-segment. Default is `shared` (DynamicRT slot — GR113-equivalent,
# where downstream el_conf/grpc_sdk look). The script also handles a
# static.x86_64 input if someone is targeting StaticRT (GR121) slot.
#
# After running, upload the new .nupkg to ProGet (it does NOT replace
# the old one — it adds a higher version that resolver will prefer).

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

# Derive linkage (static/shared) from input filename, default static.
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
    # bump <version>
    sed -i "s|<version>${OLD_VER}</version>|<version>${NEW_VER}</version>|" "$NUSPEC"
    # bump absl dep version inside <dependencies>
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
