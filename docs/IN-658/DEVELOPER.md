# IN-658 — Developer's Guide

Audience: next person to work on `conan-recipes`. Brief technical orientation. For high-level overview see `CONFLUENCE.md`; for current status see `STATUS.md`.

## Repo orientation

```
conan-recipes/
├── <pkg>/conanfile.py          ─ one per third-party lib (zlib, abseil, …)
├── <pkg>/conandata.yml         ─ upstream URLs/sha256 + local patches
├── <pkg>/src/<archive>.tar.gz  ─ offline source bundle
├── <pkg>/patches/<ver>/        ─ local patches (registered in conandata.yml)
├── extensions/deployers/
│   └── legacy_nupkg.py         ─ single source of truth for .nupkg layout
├── profiles/
│   ├── lin-gcc84-x86_64        ─ host=build profile for native x64 Linux
│   ├── lin-gcc75-arm-linaro    ─ ARM cross host profile (with linaro 7.5)
│   ├── lin-gcc75-arm64-linaro  ─ ARM64 cross host profile
│   └── toolchains/             ─ linaro CMake toolchain files
├── test-astra/
│   ├── run_grpc_1601_upstream.sh ─ main build entry for grpc/1.60.1 tree
│   ├── test_arm_cross.sh       ─ ARM cross-build harness
│   ├── HELP.txt                ─ numbered diagnostic blocks [0]–[12]
│   ├── diff_two_dirs.sh        ─ exhaustive tree comparator (added IN-658)
│   ├── TESTING_ARM.md          ─ ARM runbook
│   └── NEXT_STEPS.md           ─ historical ARM development log
├── docs/IN-658/                ─ this directory
├── Dockerfile.grpc-tc-mirror   ─ multi-stage Docker for ARM cross
└── README.md                   ─ project overview (Russian)
```

## Hard contracts (don't break)

1. **Legacy `.nupkg` byte-compat.** Names, internal structure (`lib/native/...`), `.nuspec` `<id>` field — must match the old TeamCity scheme. `legacy_nupkg.py` enforces.
2. **Offline / `--no-remote`.** Closed-network builds. No `conan-center` reachable, no internet URLs in `conandata.yml`. All source archives in `<pkg>/src/`.
3. **Canonical-first.** Recipes mirror `conan-center-index`. Local changes via `<pkg>/patches/<version>/*.patch` registered in `conandata.yml`. **Don't modify** `conandata.yml` source URLs/sha256.
4. **Two platforms in lockstep.** Every change in `test-astra/` should mirror to `test-windows/` (`*.sh` ↔ `*.bat`).

## What IN-658 added (read the deployer code)

Open `extensions/deployers/legacy_nupkg.py` and look for these features (all added by IN-658 commits 2026-05-22 → 2026-05-26):

### `_legacy_component_names()` — line ~399
Maps raw library basenames (`z`, `absl_strings`) to the names Elara CMake framework expects in `components` list of `CMakeLists.var`. Mirrors file renaming done by `_add_lib_aliases()`. **Both** original and alias emitted (for protobuf both `protoc` and `protolib` appear in components).

### `LIB_FILENAME_ALIASES` — line ~290
Per-package map of upstream-name → legacy-name. Used to create symlinks alongside originals.
- `zlib: {"z": "zlib"}` — `libz.so → libzlib.so` symlink.
- `protobuf: {"protoc": "protolib"}` — `libprotoc.so → libprotolib.so` symlink (Elara fork split libprotoc into a separately-named libprotolib.a).

To add a new alias, just extend this dict. The `_add_lib_aliases()` function (called inside `_copy_libs()`) creates symlinks; `_legacy_component_names()` ensures the component name appears in CMakeLists.var.

### `proto/` mirror — step 1b in deploy(), line ~503
Walks `package/include/` recursively, copies every `*.proto` into `staging/proto/<same-relative-path>`. Excludes upstream extras the Elara fork strips:
- `compiler/plugin.proto` (protoc plugin API; breaks downstream when present).
- `java/...` (Java-specific well-knowns with edition-2023 syntax our protoc can't parse).

Skip-list lives in `_PROTO_EXCLUDE_DIRS` set inside the function.

### `_make_keepdirs()` — line ~423
Now SKIPS dirs that already have content. `.keepdir` is only needed to force ZIP retention of empty dirs; when proto/ etc. are populated, the marker is dead weight (and breaks downstream tooling that globs the dir).

### Legacy version/name maps — top of file (lines ~30-80)
```python
LEGACY_NAME_MAP = {
    "abseil": "absl",
    "gtest": "googletest",
    "c-ares": "cares",
}
LEGACY_DEP_NAME_MAP = {
    "abseil": "absl",
}
LEGACY_DEP_VERSION_MAP = {
    "abseil": "0.2.0",
}
VERSION_SUFFIX = os.environ.get("LEGACY_NUPKG_VERSION_SUFFIX", "")
```

`LEGACY_NAME_MAP` renames the package itself (`abseil` → `absl` in the emitted `.nupkg` filename / `.nuspec` `<id>`). `LEGACY_DEP_NAME_MAP` and `LEGACY_DEP_VERSION_MAP` rename it when it appears as a transitive dependency in another package's `_dependencies` list in `CMakeLists.var` — these maps are consulted by the deployer when walking `dep.dependencies.host.items()` to emit each dep entry with the legacy-form `<name>:<version>` plus `VERSION_SUFFIX`. To add a new legacy alias, extend both `LEGACY_NAME_MAP` and `LEGACY_DEP_NAME_MAP`; for a version override, extend `LEGACY_DEP_VERSION_MAP`.

## How abseil coarse-aggregation works (`abseil/conanfile.py`)

Upstream abseil ships ~150 fine-grained `libabsl_<X>.a` libraries. Legacy Elara `absl/0.2.0` exposes 21 coarse libs (one per top-level `absl/<subdir>/`). Function `_aggregate_legacy_coarse()` in `abseil/conanfile.py`:

1. Walks `<source>/absl/` for each top-level entry's `CMakeLists.txt`.
2. Parses `absl_cc_library(NAME <X> ...)` blocks via regex to map `absl_<X> → subdir`.
3. Groups `libabsl_<target>.a` files by their owning subdir.
4. `ar x` extracts `.o` files; `ar rcs` merges per-subdir into `lib<subdir>.a` under `lib/legacy-coarse/`.

Result: 21 archives ready for legacy framework to link via `-lstrings`, `-llog`, etc.

The deployer's `LEGACY_LIBDIR_OVERRIDE = {"abseil": "legacy-coarse"}` makes deployer read from that subfolder.

## Where to start when adding/updating a recipe

1. Mirror from `https://github.com/conan-io/conan-center-index/tree/master/recipes/<pkg>`.
2. **Preserve two locally-added edits** in `conanfile.py` (see README §"Добавление нового пакета"):
   ```python
   exports_sources = "src/*.tar.gz"
   
   def _offline_source_archive(self):
       # match conandata.yml URL filename → src/<that>.tar.gz
   
   def source(self):
       _local = self._offline_source_archive()
       if _local:
           unzip(self, _local, strip_root=True)
       else:
           get(self, **self.conan_data["sources"][self.version], strip_root=True)
       apply_conandata_patches(self)
   ```
3. Drop the upstream archive in `<pkg>/src/`.
4. If naming/versioning differs from Elara legacy, add to `LEGACY_NAME_MAP` + `LEGACY_DEP_NAME_MAP` (both, see explanation above) and to `LEGACY_DEP_VERSION_MAP` (for version overrides) in `legacy_nupkg.py`.
5. Add to `EXPORTS` in `test-astra/run_grpc_1601_upstream.sh` if it's part of the grpc tree.

## When debugging — start with HELP.txt

`test-astra/HELP.txt` has numbered diagnostic blocks `[0]`–`[12]`. Each is self-contained and describes a known problem class. Add new ones rather than leaving diagnostic commands in chat. The blocks already cover:
- `[8]`–`[8l]` ARM toolchain propagation
- `[9]` ELF arch acceptance check
- `[11]` protoc-linking abseil (inline namespace / cppstd mismatch)
- `[12]` reinstall stale `.1`-slots on dev-VM

## Tools added in IN-658

### `test-astra/diff_two_dirs.sh`
Exhaustive comparator across 12 axes (tree, md5, perms, owner, xattr, ACL, SELinux, MIME, line endings, symlinks, realpath, inode). Use when two trees "look the same" but downstream tooling treats them differently. Was crucial for discovering that the proto/ extras (`compiler/plugin.proto`, `java/...`, stale `.keepdir`) broke protoc despite identical content.

### `LEGACY_NUPKG_VERSION_SUFFIX` env var
Appends suffix to every emitted `.nupkg` filename + nuspec `<version>` + `_dependencies` entries. Use `.1` to coexist with legacy on ProGet:
```bash
LEGACY_NUPKG_VERSION_SUFFIX=.1 ./test-astra/run_grpc_1601_upstream.sh
```

## Memory references (Claude session)

Persistent context in `~/.claude/projects/-Users-zero-Documents-projects-elara-work/memory/`:

- `project_lzlib_components_naming.md` — why `_legacy_component_names()` exists.
- `project_protobuf_absl_namespace.md` — inline-namespace mismatch class.
- `project_absl_component_granularity.md` — why coarse-aggregation, alternatives compared.
- `project_legacy_nupkg_proto_layout.md` — proto/ mirror.
- `project_legacy_protolib_alias.md` — libprotolib symlink alias.
- `project_dev_vm_package_resolution_pitfalls.md` — resolver asymmetry, stale slots, transitive pins.
- `project_grpc_sdk_integration_validated.md` — closure of grpc_sdk x86_64 chain.
- `project_grpc_sdk_typed_test_fixture_collision.md` — known-not-our test bug.
- `project_in658_grpc_dockerised.md` — Docker tc-mirror background.
- `reference_tc_toolchain.md` — TC image internals.
- `reference_elara_cmake_framework.md` — framework cmake-vars.
- `reference_layout.md` — project layout.

These memories preserve "why" decisions and known-bad patterns. Re-read before re-debugging the same class.

## Outstanding work (handover)

1. **ARM x86 cross-build** — infrastructure ready, run `./test-astra/test_arm_cross.sh build arm/arm64` and validate artifacts.
2. **Windows MSVC build** — not yet attempted post-Conan-migration; profiles in `test-windows/` are stubs.
3. **Production rollout** — coordinate with lead on `.1`-suffix strategy (see `STATUS.md` §2 and `DOWNSTREAM-MIGRATION.md`).
4. **TC migration** — replace GR121/GR122 configs (see `feedback_tc_layout_needs_lead` memory — needs lead sign-off).

## Don't repeat these mistakes

1. **Don't `shutil.copytree` `include/` and forget about `proto/`** — Elara framework expects `.proto` files in top-level `proto/`, not include/.
2. **Don't trust md5sum-equality as "trees are identical"** — extras (`.keepdir`, `compiler/plugin.proto`, `java_features.proto`) breaks downstream even when present-vs-absent files match by md5 on the COMMON ones.
3. **Don't sed-hack on `/home/<user>/<legacy-pkg>/CMakeLists.var` on dev-VM as a "solution"** — those edits don't propagate. Fix in `legacy_nupkg.py` (deployer) or in source recipes, push, rebuild.
4. **Don't bump abseil version without checking inline-namespace** — `ABSL_OPTION_INLINE_NAMESPACE_NAME` defines the C++ inline namespace; cross-version mix kills linking. Match downstream's grpc-line expectation (currently `lts_20230802` for grpc 1.60.x).
5. **Don't add diagnostic commands to chat only** — they get lost. Put them in `test-astra/HELP.txt` as a numbered block and push.

## Contact

If stuck, ping previous maintainer or check the Claude memory files. Each session of debugging is captured there.
