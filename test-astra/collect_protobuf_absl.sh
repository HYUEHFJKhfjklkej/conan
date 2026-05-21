#!/bin/bash
# One-shot collector for the protobuf <-> abseil link-failure context.
# Dumps every piece of evidence into a single text file so you can paste
# it back in a single message.
#
# What it grabs (all read-only, no docker, no conan-create):
#   - host / conan / cmake / gcc / ld versions
#   - relevant env vars (CONAN_*, PROFILE*, REGISTRY, etc.)
#   - every protobuf build dir under /root/.conan2/p/b/proto*/b:
#       CMakeCache.txt (filtered), flags.make for libprotoc/protoc/libprotobuf,
#       protoc link.txt, conan_toolchain.cmake (filtered),
#       last lines of CMakeOutput.log / CMakeError.log
#   - every abseil/absl package dir under /root/.conan2/p:
#       lib/ layout, conaninfo.txt, nm-defined absl::lts_* tags,
#       nm-undefined absl::lts_* tags
#   - command_line_interface.cc.o undefined-ref summary
#   - all conanfile.py `requires(...absl|abseil...)` lines in the tree
#   - conan list output for abseil/absl/protobuf
#
# Usage:
#   ./test-astra/collect_protobuf_absl.sh                # default OUT path
#   OUT=/tmp/my.txt ./test-astra/collect_protobuf_absl.sh
#   BUILD_DIR=/.../proto<hash>/b ./test-astra/collect_protobuf_absl.sh
#
# Exit codes: always 0 unless the OUT file cannot be written.

set -uo pipefail

CONAN_ROOT="${CONAN_ROOT:-/root/.conan2}"
TS="$(date +%Y%m%d-%H%M%S)"
OUT="${OUT:-/tmp/protobuf-absl-collect-$TS.txt}"

# Write to OUT; mirror banner to stderr so the user can see progress.
: > "$OUT" || { echo "cannot write $OUT" >&2; exit 1; }

# section helpers ----------------------------------------------------------
S() { echo ""; echo "================================================================"; echo "== $*"; echo "================================================================"; }
SUB() { echo ""; echo "---- $* ----"; }
RUN() {
    local label="$1"; shift
    echo ""; echo "\$ $label"
    "$@" 2>&1 || echo "(exit $?)"
}

{
echo "protobuf <-> abseil link-failure collector"
echo "generated:  $(date -Iseconds 2>/dev/null || date)"
echo "host:       $(hostname 2>/dev/null) ($(uname -a 2>/dev/null))"
echo "user:       $(id 2>/dev/null)"
echo "pwd:        $(pwd)"
echo "conan_root: $CONAN_ROOT"
echo "out:        $OUT"

# ---- [0] am I inside docker? --------------------------------------------
S "[0] docker / host detection (the answer to 'is this in the mirror?')"
SUB "/.dockerenv marker"
if [ -e /.dockerenv ]; then
    echo "INSIDE-DOCKER  (/.dockerenv exists)"
else
    echo "ON-HOST       (/.dockerenv absent)"
fi
SUB "/proc/1/cgroup (docker / containerd hints)"
if [ -r /proc/1/cgroup ]; then
    head -5 /proc/1/cgroup 2>/dev/null
fi
SUB "/etc/os-release (Astra → host, Debian Stretch → docker mirror)"
if [ -f /etc/os-release ]; then
    grep -E '^(NAME|PRETTY_NAME|VERSION_ID|ID)=' /etc/os-release
fi
SUB "hostname / id / conan home"
hostname 2>/dev/null
id 2>/dev/null
command -v conan >/dev/null && conan config home 2>/dev/null
SUB "which gcc + gcc -dumpversion + libc"
which gcc 2>/dev/null
which g++ 2>/dev/null
gcc -dumpversion 2>/dev/null
ldd --version 2>/dev/null | head -1
SUB "mounts that look like conan-cache volumes"
mount 2>/dev/null | grep -E 'conan|/root/\.conan2|/work' | head -10

# ---- [0b] toolchain & env -----------------------------------------------
S "[0b] versions & environment"
RUN "conan --version" conan --version
RUN "cmake --version" cmake --version
RUN "g++ --version | head -2" bash -c 'g++ --version | head -2'
RUN "ld --version | head -2" bash -c 'ld --version | head -2'
RUN "python3 --version" python3 --version
SUB "env (CONAN_*, PROFILE*, REGISTRY, IMAGE_TAG, BUILD_DIR)"
env | grep -E '^(CONAN_|PROFILE|REGISTRY|IMAGE_TAG|BUILD_DIR|HOME|PATH=)' | sort

# ---- [1] active conan profile -------------------------------------------
S "[1] conan profile show (host & build)"
if command -v conan >/dev/null 2>&1; then
    RUN "conan profile show -pr lin-gcc84-x86_64" \
        conan profile show -pr lin-gcc84-x86_64
    RUN "conan profile show -pr default" \
        conan profile show -pr default
else
    echo "conan not on PATH"
fi

# ---- [2] every protobuf build dir ---------------------------------------
S "[2] protobuf build dirs under $CONAN_ROOT/p/b/proto*/b"
mapfile -t PROTO_BUILDS < <(ls -dt "$CONAN_ROOT"/p/b/proto*/b 2>/dev/null)
if [ -n "${BUILD_DIR:-}" ]; then
    PROTO_BUILDS=("$BUILD_DIR" "${PROTO_BUILDS[@]}")
fi
if [ "${#PROTO_BUILDS[@]}" -eq 0 ]; then
    echo "(none)"
else
    for B in "${PROTO_BUILDS[@]}"; do echo "  $B"; done
fi

for B in "${PROTO_BUILDS[@]:-}"; do
    [ -d "$B" ] || continue
    S "[2.x] protobuf build: $B"

    SUB "ls -la (top)"
    ls -la "$B" 2>/dev/null | head -30

    SUB "CMakeCache.txt — relevant vars"
    grep -E '^(CMAKE_TOOLCHAIN_FILE|CMAKE_CXX_STANDARD|CMAKE_CXX_COMPILER|CMAKE_BUILD_TYPE|CMAKE_INSTALL_PREFIX|protobuf_|absl_|BUILD_SHARED_LIBS|CMAKE_PREFIX_PATH)' \
        "$B/CMakeCache.txt" 2>/dev/null | head -60

    SUB "conan_toolchain.cmake — CXX_STANDARD + user_toolchain block"
    for tc in "$B/generators/conan_toolchain.cmake" "$B/conan_toolchain.cmake"; do
        if [ -f "$tc" ]; then
            echo "file: $tc"
            grep -nE 'CMAKE_CXX_STANDARD|CMAKE_CXX_STANDARD_REQUIRED|CMAKE_TOOLCHAIN_FILE|include\(.*linaro' "$tc" | head -10
            break
        fi
    done

    SUB "CMakeDeps generators dir (filenames)"
    ls -la "$B/generators/" 2>/dev/null | head -30

    SUB "flags.make for libprotoc / protoc / libprotobuf"
    for f in \
        "$B/CMakeFiles/libprotoc.dir/flags.make" \
        "$B/CMakeFiles/protoc.dir/flags.make" \
        "$B/CMakeFiles/libprotobuf.dir/flags.make"
    do
        if [ -f "$f" ]; then
            echo "== $f =="
            cat "$f" | head -40
        fi
    done

    SUB "protoc link.txt (full command line that fails)"
    for L in \
        "$B/CMakeFiles/protoc.dir/link.txt" \
        "$B/CMakeFiles/libprotoc.dir/link.txt"
    do
        if [ -f "$L" ]; then
            echo "== $L =="
            cat "$L"
        fi
    done

    SUB "CMakeOutput.log tail (last 80 lines)"
    if [ -f "$B/CMakeFiles/CMakeOutput.log" ]; then
        tail -80 "$B/CMakeFiles/CMakeOutput.log"
    fi

    SUB "CMakeError.log tail (last 80 lines)"
    if [ -f "$B/CMakeFiles/CMakeError.log" ]; then
        tail -80 "$B/CMakeFiles/CMakeError.log"
    fi

    SUB "command_line_interface.cc.o — undefined absl::lts_* refs"
    CLI="$B/CMakeFiles/libprotoc.dir/src/google/protobuf/compiler/command_line_interface.cc.o"
    if [ -f "$CLI" ]; then
        echo "object: $CLI"
        echo "size: $(stat -c '%s bytes' "$CLI" 2>/dev/null)"
        echo ""
        echo "-- absl::lts_* tags in undefined refs --"
        nm -C -u "$CLI" 2>/dev/null | grep -oE 'absl::lts_[0-9]+' | sort -u
        echo ""
        echo "-- first 20 undefined absl refs (demangled) --"
        nm -C -u "$CLI" 2>/dev/null | grep 'absl::' | head -20
    else
        echo "(absent)"
    fi

    SUB "any other .o in libprotoc that references absl::lts_*"
    if [ -d "$B/CMakeFiles/libprotoc.dir" ]; then
        find "$B/CMakeFiles/libprotoc.dir" -name '*.o' 2>/dev/null \
            | while read -r O; do
                T=$(nm -C -u "$O" 2>/dev/null | grep -oE 'absl::lts_[0-9]+' | sort -u | tr '\n' ' ')
                [ -n "$T" ] && echo "  $T  $O"
            done | head -20
    fi
done

# ---- [3] every abseil/absl package in cache -----------------------------
S "[3] abseil/absl packages under $CONAN_ROOT/p/"
mapfile -t ABSL_DIRS < <(ls -dt "$CONAN_ROOT"/p/absei*/p "$CONAN_ROOT"/p/absl*/p 2>/dev/null | sort -u)
if [ "${#ABSL_DIRS[@]}" -eq 0 ]; then
    echo "(none)"
else
    for A in "${ABSL_DIRS[@]}"; do echo "  $A"; done
fi

for A in "${ABSL_DIRS[@]:-}"; do
    [ -d "$A" ] || continue
    S "[3.x] abseil package: $A"

    SUB "ls -la lib/ (and lib/native/ if present)"
    ls -la "$A/lib/" 2>/dev/null | head -40
    if [ -d "$A/lib/native" ]; then
        ls -la "$A/lib/native/" 2>/dev/null | head -40
    fi

    SUB "conaninfo.txt (settings) — package_id breakdown"
    PKG_DIR="$(dirname "$A")"
    if [ -f "$PKG_DIR/conaninfo.txt" ]; then
        cat "$PKG_DIR/conaninfo.txt"
    elif [ -f "$A/conaninfo.txt" ]; then
        cat "$A/conaninfo.txt"
    else
        # walk up — Conan 2 may place conaninfo elsewhere
        find "$A/.." -maxdepth 2 -name conaninfo.txt 2>/dev/null | head -3 | while read -r I; do
            echo "== $I =="
            cat "$I"
        done
    fi

    SUB "options.h fragments (USE_STD_STRING_VIEW + INLINE_NAMESPACE_NAME)"
    for OPT in "$A/include/absl/base/options.h"; do
        if [ -f "$OPT" ]; then
            grep -nE 'ABSL_OPTION_USE_STD_STRING_VIEW|ABSL_OPTION_INLINE_NAMESPACE_NAME|ABSL_OPTION_USE_INLINE_NAMESPACE' "$OPT" \
                | grep -vE '^[ 0-9:]+\s*//'
        fi
    done

    A_STRINGS=""
    for cand in "$A/lib/libabsl_strings.a" "$A/lib/native/libabsl_strings.a" \
                "$A/lib/libabsl_strings.so" "$A/lib/native/libabsl_strings.so"; do
        if [ -f "$cand" ]; then A_STRINGS="$cand"; break; fi
    done
    SUB "libabsl_strings (.a or .so): $A_STRINGS"
    if [ -n "$A_STRINGS" ]; then
        echo "size: $(stat -c '%s bytes' "$A_STRINGS" 2>/dev/null)"
        echo ""
        echo "-- absl::lts_* tags DEFINED in this lib --"
        nm -C --defined-only "$A_STRINGS" 2>/dev/null | grep -oE 'absl::lts_[0-9]+' | sort -u
        echo ""
        echo "-- absl::lts_* tags UNDEFINED in this lib --"
        nm -C -u "$A_STRINGS" 2>/dev/null | grep -oE 'absl::lts_[0-9]+' | sort -u
        echo ""
        echo "-- sample defined ByAnyChar / StrReplaceAll / SubstituteAndAppendArray --"
        nm -C --defined-only "$A_STRINGS" 2>/dev/null \
            | grep -E 'ByAnyChar::Find|StrReplaceAll|substitute_internal::SubstituteAndAppendArray' \
            | head -6
    fi
done

# ---- [4] all recipes' requires for absl/abseil --------------------------
S "[4] all conanfile.py requires(...absl|abseil...) in tree"
for ROOT in \
    "$HOME/conan-master" \
    "/work/conan-recipes" \
    "$(pwd)" \
    "$(pwd)/.." \
    "$(pwd)/../.."
do
    [ -d "$ROOT" ] || continue
    SUB "tree: $ROOT"
    find "$ROOT" -maxdepth 4 -name conanfile.py 2>/dev/null \
        | while read -r F; do
            H=$(grep -nE 'requires\(.*(abseil|absl)' "$F" 2>/dev/null)
            [ -n "$H" ] && { echo "-- $F --"; echo "$H"; }
        done
done

# ---- [5] conan list ------------------------------------------------------
S "[5] conan list (abseil, absl, protobuf — all revs and pids)"
if command -v conan >/dev/null 2>&1; then
    RUN "conan list 'abseil/*#*:*'" conan list 'abseil/*#*:*'
    RUN "conan list 'absl/*#*:*'" conan list 'absl/*#*:*'
    RUN "conan list 'protobuf/*#*:*'" conan list 'protobuf/*#*:*'
fi

# ---- [6] tail of any nearby build logs ----------------------------------
S "[6] any build log tails in /tmp /work /root"
for LOG in /tmp/*.log /tmp/*conan* /work/*.log /root/*.log; do
    [ -f "$LOG" ] || continue
    if grep -q 'undefined reference.*absl::lts_' "$LOG" 2>/dev/null; then
        SUB "$LOG (last 50 lines, has undefined references)"
        tail -50 "$LOG"
    fi
done

# ---- [7] git status of conan-master / conan-recipes ---------------------
S "[7] git status of recipe trees"
for ROOT in \
    "$HOME/conan-master" \
    "/work/conan-recipes" \
    "$(pwd)" \
    "$(pwd)/.."
do
    if [ -d "$ROOT/.git" ]; then
        SUB "$ROOT"
        ( cd "$ROOT" && git rev-parse --abbrev-ref HEAD 2>/dev/null \
            && git log --oneline -3 2>/dev/null \
            && git status --short 2>/dev/null | head -20 )
    fi
done

echo ""
echo "================================================================"
echo "== END OF COLLECT — file ready"
echo "================================================================"
echo "out: $OUT"
} >> "$OUT" 2>&1

echo ""
echo "[ok] collected to: $OUT"
echo "[ok] size:         $(wc -l < "$OUT") lines, $(stat -c '%s' "$OUT" 2>/dev/null) bytes"
echo ""
echo "Send this file back in a single message:"
echo "    cat $OUT          # paste contents"
echo "    # or, if too large:"
echo "    gzip -c $OUT | base64 -w0 ; echo"
