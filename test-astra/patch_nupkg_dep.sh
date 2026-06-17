#!/bin/bash
# Переписывает одну запись зависимости внутри legacy .nupkg.
#
# Зачем это нужно
# ---------------
# Conan-сборка grpc/1.60.1 из upstream-mirror кладёт abseil в слот
# `absl:0.2.0.1` (LEGACY_DEP_VERSION_MAP "abseil"->"0.2.0" плюс
# VERSION_SUFFIX ".1" в extensions/deployers/legacy_nupkg.py). Поэтому grpc и
# protobuf резолвят `absl:0.2.0.1` — правильный abseil, с `cord` и
# совпадающим `ABSL_OPTION_INLINE_NAMESPACE_NAME`.
#
# Но legacy-пакеты с Bitbucket `upb` -> `utf8_range` НЕ пересобраны; их
# CMakeLists.var `_dependencies` всё ещё называют СТАРЫЙ `absl:0.2.0`
# (и `utf8_range:0.1.0`). Фреймворк Elara ResolveDependencies резолвит
# каждую запись `_dependencies` буквально — поэтому `utf8_range` тащит
# старый abseil обратно на link line рядом с новым. Два пакета abseil,
# несовпадение inline-namespace, `undefined reference to
# absl::lts_NNNNNNNN::...` при линковке.
#
# Симптом в resolve-логе consumer (grpc_sdk): присутствуют ОБА
#   Found installed package 'absl.lin.gcc84.shared.x86_64.0.2.0.1'
#   Found installed package 'absl.lin.gcc84.shared.x86_64.0.2.0'
# — второй подтянут под `Find dependencies for utf8_range`.
#
# Скрипт точечно перенаправляет ОДИН токен зависимости в CMakeLists.var +
# .nuspec legacy .nupkg и бампит собственную версию пакета, чтобы
# пропатченный артефакт можно было залить в ProGet рядом с оригиналом.
#
# Usage
# -----
#   patch_nupkg_dep.sh <in.nupkg> <old-dep> <new-dep> <new-self-version>
#
#   <old-dep> / <new-dep>   токен зависимости в форме CMakeLists.var: name:version
#   <new-self-version>      версия пропатченного .nupkg; ДОЛЖНА отличаться от
#                           оригинала (версии в ProGet неизменяемы)
#
# Починка цепочки utf8_range / upb / absl — ДВА прогона
# -----------------------------------------------------
#   # 1. utf8_range перестаёт тащить старый abseil:
#   ./test-astra/patch_nupkg_dep.sh \
#       utf8_range.lin.gcc84.shared.x86_64.0.1.0.nupkg \
#       absl:0.2.0 absl:0.2.0.1 0.1.0.1
#
#   # 2. upb указывает на пропатченный utf8_range. Без этого шаг 1 бесполезен:
#   #    резолвер сопоставляет name:version буквально, поэтому `utf8_range:0.1.0`
#   #    из upb продолжает резолвить НЕпропатченную 0.1.0.
#   ./test-astra/patch_nupkg_dep.sh \
#       upb.lin.gcc84.shared.x86_64.0.2.0.nupkg \
#       utf8_range:0.1.0 utf8_range:0.1.0.1 0.2.0.1
#
# Затем залить оба .nupkg в ProGet, вычистить у consumer устаревшие
# распакованные каталоги пакетов и перезапустить сборку grpc_sdk.
#
# Exit codes: 0 ok / 1 ошибка usage или патча.

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

# экранируем литерал для regex внутри sed -E `s@...@...@`
# (токены dep содержат ':', поэтому делимитером берём '@', а не ':').
esc() { printf '%s' "$1" | sed 's/[][\.*^$(){}?+|@]/\\&/g'; }

# in-place правка, переносимая между GNU и BSD sed (без `sed -i`)
sed_inplace() { local f="$1"; shift; sed -E "$@" "$f" > "$f.tmp" && mv "$f.tmp" "$f"; }

OLD_DEP_RE="$(esc "$OLD_DEP")"
OLD_DEP_VER_RE="$(esc "$OLD_DEP_VER")"

WORK="$(mktemp -d -t nupkg-patch.XXXXXX)"
trap 'rm -rf "$WORK"' EXIT

echo "[1/6] unpack $IN_NUPKG"
unzip -q "$IN_NUPKG" -d "$WORK"

# Legacy nupkg держат control-файлы в корне архива; на всякий случай
# допускаем и вложенный wrapper-каталог.
CMV="$(find "$WORK" -name CMakeLists.var -type f | head -1)"
NUSPEC="$(find "$WORK" -name '*.nuspec' -type f | head -1)"
[ -n "$CMV" ]    || die "CMakeLists.var not found inside nupkg"
[ -n "$NUSPEC" ] || die ".nuspec not found inside nupkg"
CMV_REL="${CMV#$WORK/}"; NUSPEC_REL="${NUSPEC#$WORK/}"
echo "      CMakeLists.var: $CMV_REL"
echo "      nuspec        : $NUSPEC_REL"

echo "[2/6] CMakeLists.var: ${OLD_DEP} -> ${NEW_DEP}"
# Матчим токен dep только целиком: без предшествующего символа идентификатора
# и без последующей цифры/точки — чтобы `absl:0.2.0` не совпадал внутри
# `absl:0.2.0.1`.
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
# id зависимости в legacy .nuspec: `<name>.<os>.<comp>.<linkage>.<arch>`; одна
# capture-группа захватывает весь префикс, чтобы platform-суффикс не потерялся.
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
