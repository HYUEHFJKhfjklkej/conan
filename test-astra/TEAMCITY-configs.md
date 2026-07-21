# TeamCity — build configs for ALL Conan packages (one sheet)

Every deliverable package as ready-to-paste TeamCity build configs. TeamCity is
configured **by hand** (no `.teamcity/settings.kts`), so this doc is the source of
truth pasted into each config. Companion docs: `TEAMCITY-template.md` (root templates —
create a package by setting variables, no step editing), `TEAMCITY-grpc-tree.md`
(tree shape), `test-windows/TEAMCITY-grpc-windows.md` (Windows),
`HELP.txt [24]/[25]/[27]/[28]` (driver mechanics).

Deliverables covered: **grpc 1.60.1 line**, **grpc 1.78.1 line**, **gtest**, **fmt**.
The single libs (protobuf, abseil, re2, c-ares, zlib, openssl) are **not** separate
configs — they fall out of the grpc tree (7 `.nupkg` per grpc build).

---

## Global conventions (set once per project)

- **Parameter** `REGISTRY = proget.inc.elara.local/main` (ProGet host+feed for the станок pull).
- **Parameter** `ProGet.ApiKey` = key with Add/Repackage on the `conan` feed (publish step).
- **Linux configs** run the build step **inside the станок** via TeamCity's
  *"Run step within Docker container"* — image `%REGISTRY%/library/grpc-tc-mirror-<arch>:0.1.0`.
  The build step itself is a plain **Command Line**; the driver does the conan part only
  (no docker build/pull/run — TC pulls the image). x86_64 = native gcc 8.4;
  arm/arm64 = the same station carries the linaro cross-toolchain.
- **Windows configs** run **natively** on a Windows MSVC agent (no docker). Provision once:
  MSVC toolset for the profile + Conan 2.29.0 (`test-windows\setup.bat` installs it offline
  from `packages\`).
- **Slot-tag** defaults to `shared` (DynamicRT — what downstream Elara reads). For the
  StaticRT slot set `LEGACY_NUPKG_LINKAGE=static`. Content is always static `.a`.
- **Coexistence** with legacy `.nupkg` already on ProGet: set
  `LEGACY_NUPKG_VERSION_SUFFIX=.1` (appends to version + `_dependencies` refs).
- **Publish step** (Command Line, after the build step) — same for every config:
  ```
  API_KEY=%ProGet.ApiKey% NUPKG_DIR=<the config's output dir> ./test-astra/tc_publish_conan.sh
  ```
  (Windows: run the `.bat` equivalent / call the ProGet push from the agent.)

---

## grpc 1.60.1 line  (parity with legacy GR910)

Stack: grpc 1.60.1, protobuf 4.25.2, abseil 20230802.1, re2 20230301, c-ares 1.25.0,
openssl 1.1.11 (`openssl-1x/`), zlib 1.3.0.

| Config | Platform | Docker image (Linux) / Profile (Win) | Build step (Command Line) | Artifact rule |
|---|---|---|---|---|
| grpc-1601 Linux x64   | Linux x86_64 | `grpc-tc-mirror-x86_64:0.1.0` | `ARCH=x86_64 ./test-astra/build_1601_nodocker.sh` | `output-grpc-1601-x86_64/*.nupkg => x86_64` |
| grpc-1601 Linux arm   | Linux armv7hf | `grpc-tc-mirror-arm:0.1.0`    | `ARCH=arm ./test-astra/build_1601_nodocker.sh`    | `output-grpc-1601-arm/*.nupkg => arm` |
| grpc-1601 Linux arm64 | Linux aarch64 | `grpc-tc-mirror-arm64:0.1.0`  | `ARCH=arm64 ./test-astra/build_1601_nodocker.sh`  | `output-grpc-1601-arm64/*.nupkg => arm64` |
| grpc-1601 Win x64     | Windows x64  | `win-v143-x64` | `set PROFILE_NAME=win-v143-x64 & test-windows\run_grpc_1601_win.bat` | `output-grpc-1601-win\*.nupkg => win-x64` |
| grpc-1601 Win x86     | Windows x86  | `win-v142-x86` | `set PROFILE_NAME=win-v142-x86 & test-windows\run_grpc_1601_win.bat` | `output-grpc-1601-win\*.nupkg => win-x86` |

7 `.nupkg` per Linux config. Names: `<pkg>.lin.gcc84.shared.x86_64.<ver>.nupkg` (x64),
`<pkg>.lin.gcc75.shared.{arm,arm64}-linaro.<ver>.nupkg` (ARM).

## grpc 1.78.1 line  (newest)

Stack: grpc 1.78.1, protobuf 5.29.6, abseil 20250127.0, re2 20251105, c-ares 1.34.6,
openssl 3.4.5 (`openssl/`), zlib 1.3.1. Offline sources for all seven verified present.

| Config | Platform | Docker image (Linux) / Profile (Win) | Build step (Command Line) | Artifact rule |
|---|---|---|---|---|
| grpc-1781 Linux x64   | Linux x86_64 | `grpc-tc-mirror-x86_64:0.1.0` | `ARCH=x86_64 ./test-astra/build_1781_nodocker.sh` | `output-grpc-1781-x86_64/*.nupkg => x86_64` |
| grpc-1781 Linux arm   | Linux armv7hf | `grpc-tc-mirror-arm:0.1.0`    | `ARCH=arm ./test-astra/build_1781_nodocker.sh`    | `output-grpc-1781-arm/*.nupkg => arm` |
| grpc-1781 Linux arm64 | Linux aarch64 | `grpc-tc-mirror-arm64:0.1.0`  | `ARCH=arm64 ./test-astra/build_1781_nodocker.sh`  | `output-grpc-1781-arm64/*.nupkg => arm64` |
| grpc-1781 Win x64     | Windows x64  | `win-v143-x64` | `set PROFILE_NAME=win-v143-x64 & test-windows\run_grpc_1781_win.bat` | `output-grpc-1781-win\*.nupkg => win-x64` |
| grpc-1781 Win x86     | Windows x86  | `win-v142-x86` | `set PROFILE_NAME=win-v142-x86 & test-windows\run_grpc_1781_win.bat` | `output-grpc-1781-win\*.nupkg => win-x86` |

## gtest  (standalone, single pkg → googletest.*.nupkg)

Version 1.17.0 (driver default). Deployer renames `gtest → googletest`.

| Config | Platform | Docker image (Linux) / Profile (Win) | Build step (Command Line) | Artifact rule |
|---|---|---|---|---|
| gtest Linux x64   | Linux x86_64 | `grpc-tc-mirror-x86_64:0.1.0` | `ARCH=x86_64 ./test-astra/build_gtest_nodocker.sh` | `output-gtest-x86_64/*.nupkg => x86_64` |
| gtest Linux arm   | Linux armv7hf | `grpc-tc-mirror-arm:0.1.0`    | `ARCH=arm ./test-astra/build_gtest_nodocker.sh`    | `output-gtest-arm/*.nupkg => arm` |
| gtest Linux arm64 | Linux aarch64 | `grpc-tc-mirror-arm64:0.1.0`  | `ARCH=arm64 ./test-astra/build_gtest_nodocker.sh`  | `output-gtest-arm64/*.nupkg => arm64` |
| gtest Win x64     | Windows x64  | `win-v143-x64` | `set PROFILE_NAME=win-v143-x64 & test-windows\run_gtest_win.bat` | `output-gtest-win\*.nupkg => win-x64` |
| gtest Win x86     | Windows x86  | `win-v142-x86` | `set PROFILE_NAME=win-v142-x86 & test-windows\run_gtest_win.bat` | `output-gtest-win\*.nupkg => win-x86` |

Runbook detail: `HELP.txt [28]`.

## fmt  (standalone, single pkg → fmt.*.nupkg)

Version 11.2.0. No `LEGACY_NAME_MAP` entry — legacy slot name = `fmt` (confirm vs
legacy-cmake-framework it isn't `fmtlib`).

| Config | Platform | Docker image (Linux) / Profile (Win) | Build step (Command Line) | Artifact rule |
|---|---|---|---|---|
| fmt Linux x64   | Linux x86_64 | `grpc-tc-mirror-x86_64:0.1.0` | `ARCH=x86_64 ./test-astra/build_fmt_nodocker.sh` | `output-fmt-x86_64/*.nupkg => x86_64` |
| fmt Linux arm   | Linux armv7hf | `grpc-tc-mirror-arm:0.1.0`    | `ARCH=arm ./test-astra/build_fmt_nodocker.sh`    | `output-fmt-arm/*.nupkg => arm` |
| fmt Linux arm64 | Linux aarch64 | `grpc-tc-mirror-arm64:0.1.0`  | `ARCH=arm64 ./test-astra/build_fmt_nodocker.sh`  | `output-fmt-arm64/*.nupkg => arm64` |
| fmt Win x64     | Windows x64  | `win-v143-x64` | `set PROFILE_NAME=win-v143-x64 & test-windows\run_fmt_win.bat` | `output-fmt-win\*.nupkg => win-x64` |
| fmt Win x86     | Windows x86  | `win-v142-x86` | `set PROFILE_NAME=win-v142-x86 & test-windows\run_fmt_win.bat` | `output-fmt-win\*.nupkg => win-x86` |

---

## Status / caveats

- **Linux** (all packages, x86_64 validated; arm/arm64 validated on the grpc tree) —
  legacy-name byte-compat OK (`gcc84`/`gcc75`, `-linaro`, name/version maps).
- **Windows — NOT YET VALIDATED** (all packages). Two things before Windows artifacts
  are legacy-compatible:
  1. `_short_compiler` in `legacy_nupkg.py` emits `v{compiler.version}` → `v192/v193/v194`
     instead of legacy `v142/v143` (breaks both the filename **and** the internal
     `lib/native/…` dir + `.nuspec <id>`). Fix = msvc→toolset map in the deployer
     (`192→v142`, `193/194→v143`); **do not** touch profiles. One place, fixes every package.
  2. Run the Windows leg to green at least once.
- **grpc version pinning fragility**: grpc's `conanfile.py` (`>1.69` branch) uses open
  ranges (`abseil/[*]`, `protobuf/[>=5.27 <7]` — accepts 6.x, and 6.33.5 is in conandata,
  `re2/[>=20251105]`). Exact versions are enforced only by the **driver** (cache-clean +
  seed exact versions). Don't build grpc 1.78 outside the driver, or with a dirty cache +
  `SKIP_CACHE_CLEAN=1`. Optional hardening: pin `protobuf/[>=5.27.0 <6]`.

## Lead decisions (not encoded here)

Where these land in the TC tree (own project vs alongside legacy `GRPC` vs replacing
GR1xx), publish policy (overwrite vs `LEGACY_NUPKG_VERSION_SUFFIX=.1`), and Windows
StaticRT slots — go through the team lead (`TEAMCITY-grpc-tree.md`).
