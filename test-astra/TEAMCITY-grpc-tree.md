# TeamCity — GRPC build tree (replicate the production GR9xx layout)

Blueprint for recreating the existing **`GRPC`** TeamCity project (the hand-written
`GR9xx` tree) with our Conan-based builds. Target line first: **grpc 1.60.1**
(parity with `GR910 RELEASE`), then the newer 1.78.1 line ("сначала 1.60.1, дальше все").
Scope now: **GRPC only** (GRPC_SDK / GS9xx comes after, it consumes our grpc `.nupkg`).

TeamCity is configured by hand (no `.teamcity/settings.kts` in the repo), so this
doc is the source of truth pasted into the build configs. Driver mechanics:
`HELP.txt [14]/[15]`, `test-windows/TEAMCITY-grpc-windows.md`.

---

## The production tree to mirror (from the TC screenshots, 2026-06-08)

```
GRPC
├── GR900 PACKAGE   #1.60.1-alpha-8a32e7e   (meta — assembles the per-slot builds)
├── GR910 RELEASE   #1.60.1
│   ├── Windows
│   │   ├── GR100 BUILD Windows x86 StaticRT
│   │   ├── GR101 BUILD Windows x64 StaticRT
│   │   ├── GR102 BUILD Windows x86 DynamicRT
│   │   └── GR103 BUILD Windows x64 DynamicRT
│   ├── Linux
│   │   ├── GR112 BUILD Linux x86 DynamicRT
│   │   └── GR113 BUILD Linux x64 DynamicRT
│   └── Linux ARM
│       ├── GR121 BUILD Linux ARM   DynamicRT   (armv7hf)
│       └── GR122 BUILD Linux ARM64 DynamicRT   (armv8/aarch64)
```

**Slot decode (corrects the old CLAUDE.md note):** the trailing `StaticRT`/`DynamicRT`
is the runtime-CRT slot. `DynamicRT` → our deployer slot-tag **`shared`** (default);
`StaticRT` → **`static`** (`LEGACY_NUPKG_LINKAGE=static`). Content is always static `.a`.
In the *current* tree, **StaticRT exists on Windows only** (GR100/GR101); Linux and
Linux ARM ship DynamicRT only. So GR121/GR122 are **ARM DynamicRT**, not "static/GR121".

Numbering: 2nd digit = platform group (0=Windows, 1=Linux, 2=Linux ARM); within a
group lower numbers are StaticRT/x86, higher are DynamicRT/x64.

---

## Version matrix (the 1.60.1 line = legacy GR113/GR120 parity)

| pkg      | 1.60.1 line (now)             | 1.78.1 line (later)        |
|----------|-------------------------------|----------------------------|
| grpc     | 1.60.1                        | 1.78.1                     |
| protobuf | 4.25.2                        | 5.29.6                     |
| abseil   | 20230802.1                    | 20250127.0                 |
| re2      | 20230301                      | 20251105                   |
| c-ares   | 1.25.0                        | 1.34.6                     |
| openssl  | 1.1.1  (recipe `openssl-1x/`) | 3.4.5  (recipe `openssl/`) |
| zlib     | 1.3.0                         | 1.3.1                      |

The 1.60.1 line is driven by **`test-astra/run_grpc_1601_upstream.sh`** (already pins
exactly this matrix, incl. the `openssl-1x/` recipe, and self-wraps in
`docker run grpc-tc-mirror`). The 1.78.1 line is `run_test_grpc.sh`.

---

## Per-config build steps @ 1.60.1

`export REGISTRY=proget.inc.elara.local/main` once. Each config = one Command Line step.

| GR | Slot | Build step (Command Line) | Status |
|----|------|---------------------------|--------|
| **GR113** Linux x64 DynRT | shared | `./test-astra/run_grpc_1601_upstream.sh` | **READY** — tested 1.60.1 driver, native x86_64. Artefacts → `output-grpc-1601-upstream/*.nupkg` (7). |
| **GR112** Linux x86 DynRT | shared | `PROFILE=profiles/lin-gcc84-i686 OUTPUT_DIR=output-grpc-1601-i686 ./test-astra/run_grpc_1601_upstream.sh` | **READY\*** — same driver, i686 profile. *i686 (gcc -m32 + 32-bit multilib in the mirror) never validated — first run is bring-up. |
| **GR121** Linux ARM DynRT | shared | TODO — `run_grpc_1601_upstream.sh` is native-only (`-pr:b=$PROFILE`, x64 mirror). Needs the cross plumbing `test_arm_cross.sh` has (arm mirror + `PROFILE_BUILD=lin-gcc84-x86_64` + `CONAN_USER_TOOLCHAIN=linaro-arm.cmake`) wired to the 1.60.1 matrix. | TODO |
| **GR122** Linux ARM64 DynRT | shared | TODO — same as GR121, arm64 (`linaro-aarch64.cmake`). | TODO |
| **GR103** Win x64 DynRT | shared | `test_win.bat` on the 1.60.1 line (`win-v143-x64`/`v142`). Needs a 1.60.1 selector in `run_test_grpc.bat` (it hardcodes 1.78.1). | TODO — Windows never validated. |
| **GR102** Win x86 DynRT | shared | as GR103, `win-v142-x86`. | TODO |
| **GR101** Win x64 StaticRT | **static** | as GR103 + `-s compiler.runtime=static` + `LEGACY_NUPKG_LINKAGE=static`. Needs a static-runtime profile (current win profiles pin `runtime=dynamic`). | TODO |
| **GR100** Win x86 StaticRT | **static** | as GR101, x86. | TODO |

**Artifact rule** (mirror the production folders): `output-grpc-1601-*/*.nupkg => <slot-folder>`.
**Agent req:** Linux+Docker for GR1xx Linux/ARM; Windows+MSVC toolset for GR10x.

---

## What to do first (matches "сначала 1.60.1")

1. **GR113** — wire `run_grpc_1601_upstream.sh` as a build step, get 7 `.nupkg` green,
   byte-diff vs the legacy GR113 set (`diff_two_dirs.sh`, see `HELP [13]` step 3 / `[9]`).
   This is the anchor — confirms the 1.60.1 line is byte-compatible before fanning out.
2. **GR112** — same driver, `lin-gcc84-i686`. Fix i686 multilib in the mirror if needed.
3. Then the "дальше все": GR121/GR122 (ARM 1.60.1 cross), GR100-103 (Windows 1.60.1 +
   StaticRT slot), and the whole 1.78.1 line.

## Lead decisions (not invented here)

- **Cutover:** replace the existing hand-written `GR1xx` configs in place, or add the
  Conan ones in parallel (e.g. a separate `GRPC_CONAN` project / `GR1xx-conan` ids)
  and switch downstream once green. Per standing rule this is the team lead's call.
- **ProGet publish + version coexistence** (overwrite vs `LEGACY_NUPKG_VERSION_SUFFIX=.1`).

---

## Driver gaps to close for full tree coverage

1. **1.60.1 ARM cross** — generalise `run_grpc_1601_upstream.sh` (or add a wrapper) to
   accept `PROFILE_BUILD` + `CONAN_USER_TOOLCHAIN` + `MIRROR_IMAGE=grpc-tc-mirror-arm{,64}`,
   exactly like `test_arm_cross.sh` does for the 1.78.1 line.
2. **1.60.1 on Windows** — add a line selector to `run_test_grpc.bat` (it hardcodes the
   1.78.1 versions), same idea as a `GRPC_LINE` switch.
3. **Windows StaticRT** — a `win-v1xx-x{86,64}-static` profile (`compiler.runtime=static`)
   + `LEGACY_NUPKG_LINKAGE=static` for GR100/GR101.
4. **i686** — confirm the gcc84 mirror has 32-bit multilib for `lin-gcc84-i686`.
