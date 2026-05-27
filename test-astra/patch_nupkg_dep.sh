#!/bin/bash
# Rewire one dependency entry inside a legacy .nupkg.
#
# Why this exists
# ---------------
# The upstream-mirror Conan build of grpc/1.60.1 deploys abseil under the
# `absl:0.2.0.1` slot (LEGACY_DEP_VERSION_MAP "abseil"->"0.2.0" plus
# VERSION_SUFFIX ".1" in extensions/deployers/legacy_nupkg.py). So grpc and
# protobuf resolve `absl:0.2.0.1` — the good abseil, with `cord` and the
# matching `ABSL_OPTION_INLINE_NAMESPACE_NAME`.
#
# But the legacy Bitbucket packages `upb` -> `utf8_range` were NOT rebuilt;
# their CMakeLists.var `_dependencies` still name the OLD `absl:0.2.0`
# (and `utf8_range:0.1.0`). The Elara ResolveDependencies framework
# resolves every `_dependencies` entry literally — so `utf8_range` drags
# the old abseil back onto the link line next to the new one. Two abseil
# packages, inline-namespace mismatch, `undefined reference to
# absl::lts_NNNNNNNN::...` at link time.
#
# Symptom in the consumer resolve log (grpc_sdk): BOTH
#   Found installed package 'absl.lin.gcc84.static.x86_64.0.2.0.1'
#   Found installed package 'absl.lin.gcc84.static.x86_64.0.2.0'
# appear — the second one pulled in under `Find dependencies for utf8_range`.
#
# This script surgically repoints ONE dependency token in a legacy
# .nupkg's CMakeLists.var + .nuspec, and bumps the package's own version
# so the patched artifact can be uploaded to ProGet next to the original.
#
# Usage
# -----
#   patch_nupkg_dep.sh <in.nupkg> <old-dep> <new-dep> <new-self-version>
#
#   <old-dep> / <new-dep>   dependency token in CMakeLists.var form: name:version
#   <new-self-version>      version the patched .nupkg advertises; MUST differ
#                           from the original (ProGet versions are immutable)
#
# Fixing the utf8_range / upb / absl chain — TWO runs
# ---------------------------------------------------
#   # 1. utf8_range stops dragging the old abseil:
#   ./test-astra/patch_nupkg_dep.sh \
#       utf8_range.lin.gcc84.static.x86_64.0.1.0.nupkg \
#       absl:0.2.0 absl:0.2.0.1 0.1.0.1
#
#   # 2. upb points at the patched utf8_range. Without this, step 1 is dead
#   #    weight: the resolver matches name:version literally, so upb's
#   #    `utf8_range:0.1.0` keeps resolving the UNPATCHED 0.1.0.
#   ./test-astra/patch_nupkg_dep.sh \
#       upb.lin.gcc84.static.x86_64.0.2.0.nupkg \
#       utf8_range:0.1.0 utf8_range:0.1.0.1 0.2.0.1
#
# Then upload both produced .nupkg to ProGet, clear the consumer's stale
# extracted package dirs, and re-run the grpc_sdk build.
#
# Exit codes: 0 ok / 1 usage or patch error.

set -euo pipefail

die() { echo "ERROR: $*" >&2; exit 1; }

[ $# -eq 4 ] || die "usage: $0 <in.nupkg> <old-dep name:ver> <new-dep name:ver> <new-self-version>"

IN_NUPKG="$1"; OLD_DEP="$2"; NEW_DEP="$3"; NEW_VER="$4"

[ -f "$IN_NUPKG" ]      || die "$IN_NUPKG not found"
[[ "$OLD_DEP" == *:* ]] || die "old-dep must be name:version, got '$OLD_DEP'"
[[ "$NEW_DEP" == *:* ]] || die "new-dep must be name:version, got '$NEW_DEP'"
command -v unzip >/dev/null || die "unzip not on PATH"
command -v zip   >/dev/null || die "zip not on PATH"

OLD_DEP_NAME="${OLD_DEP%%:*}"
NEW_DEP_NAME="${NEW_DEP%%:*}"
OLD_DEP_VER="${OLD_DEP#*:}"
NEW_DEP_VER="${NEW_DEP#*:}"
[ "$OLD_DEP_NAME" = "$NEW_DEP_NAME" ] || \
    echo "NOTE: dep name changes ${OLD_DEP_NAME} -> ${NEW_DEP_NAME}; .nuspec <id> name segment is NOT rewritten"

# regex-escape a literal for use inside a sed -E `s@...@...@` command
# (dep tokens contain ':' so ':' cannot be the delimiter — we use '@').
esc() { printf '%s' "$1" | sed 's/[][\.*^$(){}?+|@]/\\&/g'; }

# in-place edit portable across GNU and BSD sed (no `sed -i`)
sed_inplace() { local f="$1"; shift; sed -E "$@" "$f" > "$f.tmp" && mv "$f.tmp" "$f"; }

OLD_DEP_RE="$(esc "$OLD_DEP")"
OLD_DEP_VER_RE="$(esc "$OLD_DEP_VER")"

WORK="$(mktemp -d -t nupkg-patch.XXXXXX)"
trap 'rm -rf "$WORK"' EXIT

echo "[1/6] unpack $IN_NUPKG"
unzip -q "$IN_NUPKG" -d "$WORK"

# Legacy nupkgs put the control files at archive root; be tolerant of a
# nested wrapper dir all the same.
CMV="$(find "$WORK" -name CMakeLists.var -type f | head -1)"
NUSPEC="$(find "$WORK" -name '*.nuspec' -type f | head -1)"
[ -n "$CMV" ]    || die "CMakeLists.var not found inside nupkg"
[ -n "$NUSPEC" ] || die ".nuspec not found inside nupkg"
CMV_REL="${CMV#$WORK/}"; NUSPEC_REL="${NUSPEC#$WORK/}"
echo "      CMakeLists.var: $CMV_REL"
echo "      nuspec        : $NUSPEC_REL"

echo "[2/6] CMakeLists.var: ${OLD_DEP} -> ${NEW_DEP}"
# Match the dep token only as a whole token: not preceded by an identifier
# char, not followed by a digit or dot — so `absl:0.2.0` never matches
# inside `absl:0.2.0.1`.
sed_inplace "$CMV" "s@(^|[^A-Za-z0-9_])${OLD_DEP_RE}([^0-9.]|\$)@\1${NEW_DEP}\2@g"
if grep -qE "(^|[^A-Za-z0-9_])${OLD_DEP_RE}([^0-9.]|$)" "$CMV"; then
    echo "      WARN: '${OLD_DEP}' still present after patch — unexpected"
elif grep -qF "$NEW_DEP" "$CMV"; then
    echo "      ok"
else
    echo "      WARN: neither old nor new dep token found — was '${OLD_DEP}' ever here?"
fi
sed -n '/_dependencies/,/)/p' "$CMV" | sed 's/^/        /'

echo "[3/6] .nuspec: dependency '${OLD_DEP_NAME}' version ${OLD_DEP_VER} -> ${NEW_DEP_VER}"
# Legacy .nuspec dep id is `<name>.<os>.<comp>.<linkage>.<arch>`; one capture
# group spans the whole prefix so the platform suffix is kept intact.
sed_inplace "$NUSPEC" \
  "s@(<dependency[^>]*id=\"${OLD_DEP_NAME}[^\"]*\"[^>]*version=\")${OLD_DEP_VER_RE}(\")@\1${NEW_DEP_VER}\2@"
if grep -qE "id=\"${OLD_DEP_NAME}[^\"]*\"[^>]*version=\"$(esc "$NEW_DEP_VER")\"" "$NUSPEC"; then
    grep -oE "<dependency[^>]*id=\"${OLD_DEP_NAME}[^>]*/>" "$NUSPEC" | head -1 | sed 's/^/      patched: /'
else
    echo "      WARN: no <dependency id=\"${OLD_DEP_NAME}...\"> matched in .nuspec (id segment differs?)"
fi

echo "[4/6] bump self-version"
OLD_VER="$(sed -nE 's:.*<version>([^<]*)</version>.*:\1:p' "$NUSPEC" | head -1)"
[ -n "$OLD_VER" ] || die "could not read <version> from .nuspec"
[ "$OLD_VER" != "$NEW_VER" ] || \
    die "new-self-version equals current ($OLD_VER) — ProGet versions are immutable, pick a higher one"
echo "      ${OLD_VER} -> ${NEW_VER}"
sed_inplace "$NUSPEC" "s@<version>$(esc "$OLD_VER")</version>@<version>${NEW_VER}</version>@"

echo "[5/6] repack"
IN_BASE="$(basename "$IN_NUPKG")"; STEM="${IN_BASE%.nupkg}"
case "$STEM" in
    *".$OLD_VER") OUT_STEM="${STEM%.$OLD_VER}.$NEW_VER" ;;
    *) OUT_STEM="${STEM}.${NEW_VER}"
       echo "      WARN: input name does not end in .${OLD_VER}; output named ${OUT_STEM}.nupkg" ;;
esac
OUT_NUPKG="$(pwd)/${OUT_STEM}.nupkg"
rm -f "$OUT_NUPKG"
( cd "$WORK" && zip -qr "$OUT_NUPKG" . )

echo "[6/6] verify repacked archive"
echo "      CMakeLists.var _dependencies:"
unzip -p "$OUT_NUPKG" "$CMV_REL" | sed -n '/_dependencies/,/)/p' | sed 's/^/        /'
echo "      .nuspec <version> + <dependency>:"
unzip -p "$OUT_NUPKG" "$NUSPEC_REL" | grep -E '<version>|<dependency' | sed 's/^/        /'

echo ""
echo "[DONE] $OUT_NUPKG"
echo ""
echo "Upload to ProGet (Default feed -> Add Package). The original ${OLD_VER}"
echo "stays untouched; this adds ${NEW_VER} alongside it."
echo ""
echo "REMINDER — the Elara resolver matches name:version LITERALLY."
echo "Bumping this package to ${NEW_VER} does nothing on its own: every"
echo "parent that depends on it still names the OLD version in its own"
echo "_dependencies and keeps resolving the OLD .nupkg. You MUST also patch"
echo "each parent's dependency entry to point at <thispkg>:${NEW_VER}"
echo "(for the utf8_range/upb/absl chain that is the two runs in the header)."
