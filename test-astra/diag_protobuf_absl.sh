#!/bin/bash
# Diagnostic for `protoc` failing to link with abseil — the
# `undefined reference to absl::lts_NNNNNNNN::ByAnyChar::Find(
#    absl::lts_NNNNNNNN::string_view, unsigned long)` family of errors
# in command_line_interface.cc.o.
#
# Read first
# ----------
# This repo has seen this error twice for two different root causes —
# the script prints which one you're in.
#
#   (A) Inline-namespace mismatch.  abseil bakes its LTS tag into the
#       inline namespace via ABSL_OPTION_INLINE_NAMESPACE_NAME (see
#       absl/base/options.h). For 20230802.1 that name is `lts_20230802`.
#       If `legacy/absl/0.2.0` (or any non-matching abseil) ends up on
#       the link line — e.g. built with `lts_20240116` — protoc's TUs
#       (compiled against headers that declared `lts_20230802`) ask for
#       symbols the .a does not export, and the linker fails on every
#       absl call. This is what `fix_legacy_protobuf_absl.sh` repairs
#       by swapping `legacy/protobuf`'s requires from `absl/0.2.0` →
#       `abseil/20230802.1`.
#
#   (B) cppstd mismatch on `absl::string_view`. At c++17 abseil aliases
#       absl::string_view to std::string_view (mangling uses
#       std::basic_string_view). At c++<17 it is abseil's own class
#       (mangling uses absl::lts_*::string_view). If only some of the
#       string-typed signatures fail and the LTS tag in the symbol
#       matches the one in the .a, this is the case — not (A).
#
# (A) is the common one in this repo. (B) is a secondary check.
#
# Usage
# -----
# Run inside the same container/shell where the link failed (REGISTRY
# mirror image for a CI repro, or the dev-VM for a local repro), from
# any cwd — the script discovers the build dir under /root/.conan2/p/b.
#
#   ./test-astra/diag_protobuf_absl.sh        # auto-detect build dir
#   BUILD_DIR=/path/to/proto<hash>/b ./test-astra/diag_protobuf_absl.sh
#
# Exit codes
#   0  diagnostic ran end-to-end; verdict printed
#   2  no protobuf build dir found in /root/.conan2/p/b (build never started)
#   3  no abseil/absl package found in /root/.conan2/p (abseil never installed)

set -uo pipefail

CONAN_ROOT="${CONAN_ROOT:-/root/.conan2}"

echo "================================================================"
echo " protobuf <-> abseil ABI diagnostic"
echo " conan root: $CONAN_ROOT"
echo "================================================================"
echo ""

# ---- [1] locate protobuf build dir ----------------------------------
echo "== [1] protobuf build dir =="
if [ -n "${BUILD_DIR:-}" ]; then
    BUILD="$BUILD_DIR"
    echo "(using BUILD_DIR=$BUILD from env)"
else
    BUILD="$(ls -dt "$CONAN_ROOT"/p/b/proto*/b 2>/dev/null | head -1)"
fi
if [ -z "$BUILD" ] || [ ! -d "$BUILD" ]; then
    echo "[fail] no protobuf build dir under $CONAN_ROOT/p/b/proto*/b"
    echo "       (the build probably never reached the CMake configure step)"
    exit 2
fi
echo "build_root: $BUILD"
echo "all candidates:"
ls -1d "$CONAN_ROOT"/p/b/proto*/b 2>/dev/null | sed 's/^/    /'
echo ""

# ---- [2] which LTS tag command_line_interface.cc actually wants -----
# Pull from CMake's saved error output if any, else read the .o
# directly to see the inline-namespace tag mangled into the calls.
echo "== [2] inline namespace tag baked into command_line_interface.cc.o =="
CLI_OBJ="$BUILD/CMakeFiles/libprotoc.dir/src/google/protobuf/compiler/command_line_interface.cc.o"
if [ -f "$CLI_OBJ" ]; then
    echo "object: $CLI_OBJ"
    REF_TAGS=$(nm -C -u "$CLI_OBJ" 2>/dev/null \
        | grep -oE 'absl::lts_[0-9]+' \
        | sort -u)
    if [ -n "$REF_TAGS" ]; then
        echo "$REF_TAGS" | sed 's/^/    refs    /'
    else
        echo "    (no undefined absl::lts_* refs — either link succeeded"
        echo "     or .o was compiled before the conflict bites)"
    fi
else
    echo "    (command_line_interface.cc.o absent — compile never ran)"
fi
echo ""

# ---- [3] which LTS tag is actually inside the abseil .a we link to --
echo "== [3] inline namespace tag exported by each abseil .a in cache =="
ABSL_P_DIRS=$(ls -dt "$CONAN_ROOT"/p/absei*/p "$CONAN_ROOT"/p/absl*/p 2>/dev/null | sort -u)
if [ -z "$ABSL_P_DIRS" ]; then
    echo "[fail] no abseil/absl package under $CONAN_ROOT/p/"
    exit 3
fi
for ABSL in $ABSL_P_DIRS; do
    A="$ABSL/lib/libabsl_strings.a"
    LEGACY_A="$ABSL/lib/native/libabsl_strings.a"
    [ -f "$A" ] || A="$LEGACY_A"
    if [ ! -f "$A" ]; then
        echo "-- $ABSL : (no libabsl_strings.a)"
        continue
    fi
    DEF_TAGS=$(nm -C --defined-only "$A" 2>/dev/null \
        | grep -oE 'absl::lts_[0-9]+' \
        | sort -u)
    if [ -z "$DEF_TAGS" ]; then
        echo "-- $ABSL : (no absl::lts_* symbols defined — unexpected layout)"
        continue
    fi
    echo "-- $ABSL"
    echo "$DEF_TAGS" | sed 's/^/    exports /'
done
echo ""

# ---- [4] check which abseil ref the protobuf recipe pulls -----------
# both for the canonical protobuf recipe and the legacy one
echo "== [4] which abseil version protobuf is required to use =="
for RECIPE in \
    "$HOME/conan-master/protobuf/conanfile.py" \
    "$HOME/conan-master/legacy/protobuf/conanfile.py" \
    "/work/conan-recipes/protobuf/conanfile.py" \
    "/work/conan-recipes/legacy/protobuf/conanfile.py" \
    "./protobuf/conanfile.py" \
    "./legacy/protobuf/conanfile.py" \
    "../protobuf/conanfile.py" \
    "../legacy/protobuf/conanfile.py"
do
    if [ -f "$RECIPE" ]; then
        echo "-- $RECIPE"
        grep -nE 'requires\(.*(abseil|absl)' "$RECIPE" \
            | head -4 | sed 's/^/    /'
    fi
done
echo ""

# ---- [5] -std= flags that landed on the failing TU ------------------
echo "== [5] -std= flag that CMake actually emitted (cppstd cross-check) =="
for f in \
    "$BUILD/CMakeFiles/libprotoc.dir/flags.make" \
    "$BUILD/CMakeFiles/protoc.dir/flags.make" \
    "$BUILD/CMakeFiles/libprotobuf.dir/flags.make"
do
    if [ -f "$f" ]; then
        echo "-- $f --"
        grep -E -- '-std=c\+\+|-std=gnu\+\+|CXX_STANDARD' "$f" \
            | sed 's/^/    /' \
            || echo "    (no -std flag in this file — uses CMake default)"
    fi
done
echo ""

# ---- [6] CMakeCache.txt: did the Conan toolchain land? --------------
echo "== [6] CMakeCache.txt — toolchain and CXX_STANDARD =="
if [ -f "$BUILD/CMakeCache.txt" ]; then
    grep -E \
        'CMAKE_TOOLCHAIN_FILE|CMAKE_CXX_STANDARD|protobuf_ABSL_PROVIDER|protobuf_BUILD_LIBPROTOC' \
        "$BUILD/CMakeCache.txt" | head -20 | sed 's/^/    /'
else
    echo "    (CMakeCache.txt absent — configure did not finish)"
fi
echo ""

# ---- [7] full list of abseil/absl package_ids in cache --------------
echo "== [7] every abseil/absl in cache with its build settings =="
if command -v conan >/dev/null 2>&1; then
    conan list 'abseil/*#*:*' 'absl/*#*:*' -f json 2>/dev/null \
      | python3 -c '
import json, sys
try:
    d = json.load(sys.stdin)
except Exception as e:
    print("    (could not parse conan-list json:", e, ")"); sys.exit(0)
cache = d.get("Local Cache", {})
if not cache:
    print("    (no abseil/absl entries in conan list output)"); sys.exit(0)
for ref, r in cache.items():
    for rev, rr in r.get("revisions", {}).items():
        for pid, pp in rr.get("packages", {}).items():
            s = pp.get("info", {}).get("settings", {})
            print(f"    {ref}  pid={pid}  cppstd={s.get(\"compiler.cppstd\")}  build_type={s.get(\"build_type\")}")
'
else
    echo "    (conan binary not on PATH)"
fi
echo ""

# ---- [8] verdict ----------------------------------------------------
echo "== [8] verdict — cross-read [2] vs [3] first, [5] second =="
cat <<'EOF'
    Read the LTS tags in [2] (what protoc refs) and [3] (what each
    abseil .a in cache exports).

    [2] lts_20230802   AND   any [3] entry shows lts_20240116 (or other)
        -> Inline-namespace mismatch, the (A) case. Legacy/wrong abseil
           is on the link line.
           Fix:
             # if `legacy/protobuf` requires absl/0.2.0:
             bash test-astra/fix_legacy_protobuf_absl.sh
             # else find what pulled the wrong abseil:
             grep -RnE 'requires.*(absl/|abseil/)' \
                  protobuf/ legacy/ grpc/ 2>/dev/null

    [2] lts_20230802   AND   [3] also lts_20230802 (single match)
        -> Not (A). Check [5]:
             -std=c++14 anywhere -> cppstd mismatch, the (B) case.
                                    Fix: ensure profile cppstd=17 reaches
                                    the compiler. [6] CMakeCache.txt must
                                    have CMAKE_TOOLCHAIN_FILE pointing at
                                    conan_toolchain.cmake; that file must
                                    contain `set(CMAKE_CXX_STANDARD 17)`.
                                    If both are correct but compile flag
                                    still drops to c++14, a patch in
                                    protobuf is overriding it.
             -std=c++17 everywhere -> not ABI mismatch on string_view.
                                    Look for missing absl components on
                                    the link line, or stray bundled
                                    abseil headers under third_party/.

    [2] empty (no undefined refs in .o)
        -> The .o is fine; the error came at a later .o or the link of
           protoc itself. Inspect another TU under
           $BUILD/CMakeFiles/libprotoc.dir/src/google/protobuf/compiler/
           and rerun, or set BUILD_DIR= explicitly.

    Multiple [3] entries with different LTS tags
        -> Two abseil packages cached. Even if Conan resolved to the
           right one for THIS build, leftovers can be confusing.
           Tidy up after you confirm the fix:
             conan remove 'abseil/*' -c
             conan remove 'absl/*' -c
EOF
echo ""
echo "diag complete."
