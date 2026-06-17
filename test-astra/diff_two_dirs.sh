#!/bin/bash
# Исчерпывающее сравнение двух деревьев каталогов — ищет ЛЮБОЕ отличие
# (содержимое, права, владелец, xattr, ACL, симлинки, кодировка,
# переводы строк, SELinux-контекст, лишние/недостающие файлы).
#
# Нужно, когда два дерева выглядят одинаково, но downstream-тулинг ведёт
# себя по-разному. Классика IN-658: два `proto/` с побитово одинаковыми
# .proto (md5 совпадает), где один работает с protoc, а другой нет.
#
# Usage:
#   ./test-astra/diff_two_dirs.sh <good-dir> <bad-dir>
#
# Вывод сгруппирован по проверкам: "[OK]" — деревья совпали по этой оси,
# "[DIFF]" печатает отличие. Exit code = число провалившихся проверок.

set -u

if [ $# -ne 2 ]; then
    echo "usage: $0 <good-dir> <bad-dir>"
    exit 2
fi

GOOD="$1"
BAD="$2"

if [ ! -d "$GOOD" ] || [ ! -d "$BAD" ]; then
    echo "ERROR: both args must be existing directories"
    exit 2
fi

FAILS=0
section() {
    echo
    echo "=================================================="
    echo "[$1]"
    echo "=================================================="
}
ok()   { echo "  [OK] $1"; }
diff_() {
    echo "  [DIFF] $1"
    FAILS=$((FAILS+1))
}

# ---------------------------------------------------------------- 1. дерево
section "1. file tree (names + types)"
TG="$(mktemp)"
TB="$(mktemp)"
( cd "$GOOD" && find . -printf '%y %p\n' | LC_ALL=C sort ) > "$TG"
( cd "$BAD"  && find . -printf '%y %p\n' | LC_ALL=C sort ) > "$TB"
if diff -q "$TG" "$TB" >/dev/null 2>&1; then
    ok "trees identical ($(wc -l < "$TG") entries each)"
else
    diff_ "trees differ — full diff below:"
    diff "$TG" "$TB" | sed 's/^/      /'
fi
rm -f "$TG" "$TB"

# ---------------------------------------------------------------- 2. содержимое
section "2. file content (md5)"
TG="$(mktemp)"
TB="$(mktemp)"
( cd "$GOOD" && find . -type f -exec md5sum {} \; | LC_ALL=C sort -k2 ) > "$TG"
( cd "$BAD"  && find . -type f -exec md5sum {} \; | LC_ALL=C sort -k2 ) > "$TB"
if diff -q "$TG" "$TB" >/dev/null 2>&1; then
    ok "all $(wc -l < "$TG") files bit-identical"
else
    diff_ "content differs — diff (md5 hash + file):"
    diff "$TG" "$TB" | sed 's/^/      /'
fi
rm -f "$TG" "$TB"

# ---------------------------------------------------------------- 3. права
section "3. permissions (mode bits)"
TG="$(mktemp)"
TB="$(mktemp)"
( cd "$GOOD" && find . -printf '%m %p\n' | LC_ALL=C sort -k2 ) > "$TG"
( cd "$BAD"  && find . -printf '%m %p\n' | LC_ALL=C sort -k2 ) > "$TB"
if diff -q "$TG" "$TB" >/dev/null 2>&1; then
    ok "permissions match"
else
    diff_ "permissions differ:"
    diff "$TG" "$TB" | sed 's/^/      /'
fi
rm -f "$TG" "$TB"

# ---------------------------------------------------------------- 4. владелец/группа
section "4. owner / group"
TG="$(mktemp)"
TB="$(mktemp)"
( cd "$GOOD" && find . -printf '%u:%g %p\n' | LC_ALL=C sort -k2 ) > "$TG"
( cd "$BAD"  && find . -printf '%u:%g %p\n' | LC_ALL=C sort -k2 ) > "$TB"
if diff -q "$TG" "$TB" >/dev/null 2>&1; then
    ok "owner/group match"
else
    diff_ "owner/group differ:"
    diff "$TG" "$TB" | sed 's/^/      /'
fi
rm -f "$TG" "$TB"

# ---------------------------------------------------------------- 5. симлинки
section "5. symlinks"
SG=$(cd "$GOOD" && find . -type l 2>/dev/null | wc -l)
SB=$(cd "$BAD"  && find . -type l 2>/dev/null | wc -l)
if [ "$SG" = "$SB" ] && [ "$SG" = "0" ]; then
    ok "no symlinks in either tree"
elif [ "$SG" = "$SB" ]; then
    ok "both trees have $SG symlinks — comparing targets:"
    TG="$(mktemp)"
    TB="$(mktemp)"
    ( cd "$GOOD" && find . -type l -printf '%p -> %l\n' | LC_ALL=C sort ) > "$TG"
    ( cd "$BAD"  && find . -type l -printf '%p -> %l\n' | LC_ALL=C sort ) > "$TB"
    if diff -q "$TG" "$TB" >/dev/null 2>&1; then
        ok "  symlink targets match"
    else
        diff_ "  symlink targets differ:"
        diff "$TG" "$TB" | sed 's/^/      /'
    fi
    rm -f "$TG" "$TB"
else
    diff_ "symlink count differs: good=$SG bad=$SB"
    echo "    [good $GOOD symlinks]"
    ( cd "$GOOD" && find . -type l -printf '%p -> %l\n' ) | sed 's/^/      /'
    echo "    [bad  $BAD  symlinks]"
    ( cd "$BAD"  && find . -type l -printf '%p -> %l\n' ) | sed 's/^/      /'
fi

# ---------------------------------------------------------------- 6. xattr
section "6. extended attributes (xattr)"
if ! command -v getfattr >/dev/null 2>&1; then
    echo "  [SKIP] getfattr not installed — run: sudo apt install attr"
else
    TG="$(mktemp)"
    TB="$(mktemp)"
    ( cd "$GOOD" && find . -type f -exec getfattr -d --absolute-names {} \; 2>/dev/null ) > "$TG"
    ( cd "$BAD"  && find . -type f -exec getfattr -d --absolute-names {} \; 2>/dev/null ) > "$TB"
    # убираем абсолютный префикс, чтобы сравнивать относительные деревья
    sed -i "s|$GOOD|<root>|g" "$TG"
    sed -i "s|$BAD|<root>|g" "$TB"
    if diff -q "$TG" "$TB" >/dev/null 2>&1; then
        SIZE=$(wc -c < "$TG")
        if [ "$SIZE" = "0" ]; then
            ok "no xattr on either tree"
        else
            ok "xattr identical"
        fi
    else
        diff_ "xattr differ:"
        diff "$TG" "$TB" | sed 's/^/      /'
    fi
    rm -f "$TG" "$TB"
fi

# ---------------------------------------------------------------- 7. ACL
section "7. POSIX ACL"
if ! command -v getfacl >/dev/null 2>&1; then
    echo "  [SKIP] getfacl not installed — run: sudo apt install acl"
else
    TG="$(mktemp)"
    TB="$(mktemp)"
    ( cd "$GOOD" && find . -print0 | xargs -0 getfacl -p --skip-base 2>/dev/null ) > "$TG"
    ( cd "$BAD"  && find . -print0 | xargs -0 getfacl -p --skip-base 2>/dev/null ) > "$TB"
    if diff -q "$TG" "$TB" >/dev/null 2>&1; then
        SIZE=$(wc -c < "$TG")
        if [ "$SIZE" = "0" ]; then
            ok "no non-default ACLs"
        else
            ok "ACLs identical"
        fi
    else
        diff_ "ACLs differ:"
        diff "$TG" "$TB" | sed 's/^/      /'
    fi
    rm -f "$TG" "$TB"
fi

# ---------------------------------------------------------------- 8. SELinux
section "8. SELinux context"
if ! command -v getenforce >/dev/null 2>&1 && [ ! -f /sys/fs/selinux/enforce ]; then
    echo "  [SKIP] SELinux not active"
else
    TG="$(mktemp)"
    TB="$(mktemp)"
    ( cd "$GOOD" && find . -printf '%p\n' | xargs ls -lZ 2>/dev/null | awk '{print $NF, $(NF-1)}' | LC_ALL=C sort ) > "$TG"
    ( cd "$BAD"  && find . -printf '%p\n' | xargs ls -lZ 2>/dev/null | awk '{print $NF, $(NF-1)}' | LC_ALL=C sort ) > "$TB"
    if diff -q "$TG" "$TB" >/dev/null 2>&1; then
        ok "SELinux contexts match (or absent)"
    else
        diff_ "SELinux contexts differ:"
        diff "$TG" "$TB" | sed 's/^/      /'
    fi
    rm -f "$TG" "$TB"
fi

# ---------------------------------------------------------------- 9. тип файла (file)
section "9. file(1) type"
TG="$(mktemp)"
TB="$(mktemp)"
( cd "$GOOD" && find . -type f -print0 | xargs -0 file --mime 2>/dev/null | LC_ALL=C sort ) > "$TG"
( cd "$BAD"  && find . -type f -print0 | xargs -0 file --mime 2>/dev/null | LC_ALL=C sort ) > "$TB"
if diff -q "$TG" "$TB" >/dev/null 2>&1; then
    ok "all files report same MIME type & encoding"
else
    diff_ "MIME/encoding differs:"
    diff "$TG" "$TB" | sed 's/^/      /'
fi
rm -f "$TG" "$TB"

# ---------------------------------------------------------------- 10. переводы строк + BOM
section "10. line endings (CRLF) + BOM"
detect_le() {
    local dir="$1"
    cd "$dir" || return
    find . -type f -print0 | while IFS= read -r -d '' f; do
        # счёт CR против LF — если есть CR, значит CRLF
        cr=$(tr -cd '\r' < "$f" | wc -c)
        lf=$(tr -cd '\n' < "$f" | wc -c)
        bom=""
        if [ "$(head -c3 "$f" | od -An -t x1 | tr -d ' \n')" = "efbbbf" ]; then
            bom="BOM"
        fi
        if [ "$cr" -gt 0 ]; then
            echo "CRLF $bom $f"
        else
            echo "LF   $bom $f"
        fi
    done | LC_ALL=C sort
}
TG="$(mktemp)"; TB="$(mktemp)"
detect_le "$GOOD" > "$TG"
detect_le "$BAD"  > "$TB"
if diff -q "$TG" "$TB" >/dev/null 2>&1; then
    ok "line endings + BOM identical"
else
    diff_ "line endings or BOM differ:"
    diff "$TG" "$TB" | sed 's/^/      /'
fi
rm -f "$TG" "$TB"

# ---------------------------------------------------------------- 11. realpath
section "11. canonical paths (symlink resolution)"
# проверяем, не лежит ли само дерево на пути через симлинк
RG=$(realpath "$GOOD")
RB=$(realpath "$BAD")
echo "  GOOD: $GOOD"
echo "  realpath: $RG"
echo "  BAD:  $BAD"
echo "  realpath: $RB"
if [ "$RG" = "$GOOD" ] && [ "$RB" = "$BAD" ]; then
    ok "neither root path goes through a symlink"
else
    diff_ "one or both root paths involve symlinks — protoc may fail on canonicalized form"
fi

# ---------------------------------------------------------------- 12. inode-инфо
section "12. inode info (hardlinks, sparse)"
TG="$(mktemp)"
TB="$(mktemp)"
( cd "$GOOD" && find . -type f -printf '%n %s %p\n' | LC_ALL=C sort -k3 ) > "$TG"
( cd "$BAD"  && find . -type f -printf '%n %s %p\n' | LC_ALL=C sort -k3 ) > "$TB"
if diff -q "$TG" "$TB" >/dev/null 2>&1; then
    ok "hardlink count + size identical"
else
    diff_ "inode meta differs:"
    diff "$TG" "$TB" | sed 's/^/      /'
fi
rm -f "$TG" "$TB"

# ---------------------------------------------------------------- итог
echo
echo "=================================================="
if [ "$FAILS" = "0" ]; then
    echo "VERDICT: trees are indistinguishable on every checked axis."
    echo "         Difference must be in env/process invocation, not in the files."
else
    echo "VERDICT: $FAILS check(s) found differences. Look above for [DIFF] lines."
fi
echo "=================================================="
exit "$FAILS"
