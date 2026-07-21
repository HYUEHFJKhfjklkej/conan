# TeamCity — root templates for creating Conan packages

`FMT_CONAN`, `GRPC_CONAN`, `GTEST_CONAN` are the **same skeleton**: one `PUBLISH`
config + `Linux` / `Linux ARM` / `Windows` sub-projects, each holding a
`<PKG> BUILD Conan <arch>` leaf. To **create a new package** you should not re-draw
any step — define **three Build Configuration Templates once in the Root project**,
then every leaf is *based on template* and sets only a few **human-readable variables**
(package name, version, arch). Nothing about the build is retyped.

TeamCity is configured by hand (no `settings.kts`), so this is the paste-sheet.
Companion: `TEAMCITY-configs.md` (concrete per-package values), `TEAMCITY-grpc-tree.md`
(tree placement — lead decision), `HELP.txt [26]/[28]` (publish/feed + gtest driver).

**Design rule:** everything that changes between packages/versions is a `%param%`.
A leaf config's Parameters tab is the *only* thing you edit — steps and artifact rules
live in the template and read the params. Versions stay written as `1.17.0`, never
hidden inside a script name.

---

## 0. Root project — set once, inherited by every child

**VCS root** (Root project): `conan-recipes` git, default branch = the branch TC
builds (`develop` in the current configs). Every template attaches to it.

**Parameters** (Root → Parameters; children inherit; override only where noted):

| Name | Kind | Value |
|---|---|---|
| `REGISTRY` | config | `proget.inc.elara.local/main` |
| `PROGET_URL` | config | `http://proget.inc.elara.local` |
| `FEED` | config | `conan` |
| `ProGet.ApiKey` | **password** | key with Add/Repackage on the `conan` feed |
| `env.LEGACY_NUPKG_LINKAGE` | config | `shared` (StaticRT slot → `static`) |
| `env.LEGACY_NUPKG_VERSION_SUFFIX` | config | *(empty; `.1` = coexist with legacy on ProGet)* |

---

## The variables (what you actually type per package)

Only three are "human" knobs; the rest are **derived** in the template and never touched.

| Variable | Human-readable | Example | Used for |
|---|---|---|---|
| `pkg.name` | ✅ package | `gtest` | driver name, output dir, artifact rule |
| `pkg.version` | ✅ version | `1.17.0` | passed to the driver as `PKG_VERSION` |
| `pkg.arch` | ✅ arch | `x86_64` \| `arm` \| `arm64` | profile/toolchain + docker image |
| `docker.image` | derived | `%REGISTRY%/library/grpc-tc-mirror-%pkg.arch%:0.1.0` | Linux "Run step within Docker" |
| `pkg.driver` | derived | `build_%pkg.name%_nodocker.sh` | Linux build step |
| `pkg.output` | derived | `output-%pkg.name%-%pkg.arch%` | output dir + artifact path |

Derived params are set **once, in the template**, as literal expressions over the human
ones — a child never re-enters them. Adding gtest 1.18.0 later = change one field,
`pkg.version = 1.18.0`. The value is the version, verbatim.

> **Version is a real variable only for single-package recipes** (gtest, fmt, and future
> standalone libs — zlib, openssl, …). The drivers read `PKG_VERSION` (generic fallback
> added to `build_<pkg>_nodocker.sh`). **grpc is the exception** — see the grpc-line note
> at the bottom; its stack is a pinned 7-package set, so "version" = which driver, plus a
> display-only `pkg.version` for readability.

---

## UI click-path — create the templates once (no DSL, no XML)

The server is hand-configured, so build the templates in the UI once; every leaf then
inherits. Do it in the **`<Root project>`** so all `*_CONAN` subprojects see them.

### A. Root parameters (once)

`Administration → <Root project> → Parameters → Add new parameter`, add each row from
§0 above. For `ProGet.ApiKey`: `Edit → Spec → Type = Password`.

### B. Template 1 — `Conan Build Linux` (the leaf builder)

1. `Administration → <Root project> → (project settings page)`. In the **Build
   Configuration Templates** block (next to *Create build configuration*) click
   **Create template**. Name: `Conan Build Linux`. Save.
2. **Version Control Settings → Attach VCS root →** the `conan-recipes` root (branch
   `develop`). Checkout rules: default.
3. **Parameters → Add new parameter**, one per row. For the human ones set
   `Edit → Display = Prompt` (so a leaf is asked to fill them) and `Type = Text`:

   | Name | Value | Spec (Edit dialog) |
   |---|---|---|
   | `pkg.name` | *(empty)* | Display **Prompt**, Type Text, Label "package (gtest/fmt/…)" |
   | `pkg.version` | *(empty)* | Display **Prompt**, Type Text, Label "version, e.g. 1.17.0" |
   | `pkg.arch` | `x86_64` | Display **Prompt**, Type Select, options `x86_64 arm arm64` |
   | `docker.image` | `%REGISTRY%/library/grpc-tc-mirror-%pkg.arch%:0.1.0` | Display **Hidden** (derived) |
   | `pkg.driver` | `build_%pkg.name%_nodocker.sh` | Display **Hidden** (derived) |
   | `pkg.output` | `output-%pkg.name%-%pkg.arch%` | Display **Hidden** (derived) |

   *Hidden* = derived, never shown to the leaf. *Prompt* = the three knobs the leaf fills.
4. **Build Steps → Add build step → Command Line**.
   - Step name: `conan build`.
   - Run: **Custom script**.
   - Custom script:
     ```
     ARCH=%pkg.arch% PKG_VERSION=%pkg.version% ./test-astra/%pkg.driver%
     ```
   - Scroll to **Docker Settings** (a.k.a. *Run step within Docker container*):
     - Run step within a Docker container: `%docker.image%`
     - Docker image platform: **Linux**
     - ✅ Pull image explicitly (or leave default — the image is on `%REGISTRY%`).
   - Save.
5. **General Settings → Artifact paths:**
   ```
   %pkg.output%/*.nupkg => %pkg.arch%
   ```
6. **Agent Requirements → Add requirement:** `docker.server.version` **exists**
   (Linux agent with Docker). Add `teamcity.agent.jvm.os.name` **contains** `Linux` if you
   have mixed agents. Save.

Template 1 is done. A leaf = `Create build configuration → Based on template → Conan Build
Linux`, then fill the 3 prompted params.

### C. Template 2 — `Conan Build Windows`

Same as B, but step **not** in Docker (native MSVC agent):
- Parameters (Prompt): `pkg.name`, `pkg.version`, `win.profile` (default `win-v143-x64`),
  `win.slot` (default `win-x64`). Hidden/derived: `pkg.driver.win = run_%pkg.name%_win.bat`,
  `pkg.output.win = output-%pkg.name%-win`.
- Build step **Command Line**, custom script:
  ```
  set PROFILE_NAME=%win.profile% & set PKG_VERSION=%pkg.version% & test-windows\%pkg.driver.win%
  ```
  Leave Docker Settings empty.
- Artifact paths: `%pkg.output.win%\*.nupkg => %win.slot%`
- Agent Requirements: `teamcity.agent.jvm.os.name` **contains** `Windows`.

### D. Template 3 — `Publish to Conan ProGet`

- No prompted params (uses inherited `ProGet.ApiKey` / `PROGET_URL` / `FEED`).
- Build step **Command Line**, custom script:
  ```
  API_KEY=%ProGet.ApiKey% PROGET_URL=%PROGET_URL% FEED=%FEED% NUPKG_DIR=nupkg ./test-astra/tc_publish_conan.sh
  ```
- **Artifact dependencies are per-leaf, so leave them out of the template** — wire them in
  each concrete Publish config (Dependencies → Artifact Dependencies → each arch leaf →
  `*.nupkg => nupkg/`). Everything else (step, params) comes from the template.
- Optional: **Triggers → Finish Build Trigger** on the arch leaves.

> Once the three templates exist, the whole §"Create a new package" checklist below is:
> `Based on template` × 4–5 + fill prompts. No step is ever retyped.

---

## Template 1 — `_TPL Conan Build Linux`

Covers every Linux / Linux ARM leaf (`<PKG> BUILD Conan x86_64 / ARM / ARM64`).

**Template parameters** — human knobs (child overrides) + derived (child leaves as-is):

| Param | Set by child? | Value / expression |
|---|---|---|
| `pkg.name` | ✅ | e.g. `gtest` |
| `pkg.version` | ✅ | e.g. `1.17.0` |
| `pkg.arch` | ✅ | `x86_64` \| `arm` \| `arm64` |
| `pkg.driver` | no (derived) | `build_%pkg.name%_nodocker.sh` |
| `pkg.output` | no (derived) | `output-%pkg.name%-%pkg.arch%` |
| `docker.image` | no (derived) | `%REGISTRY%/library/grpc-tc-mirror-%pkg.arch%:0.1.0` |

**Build step** — *Command Line*, "Run step within Docker container" = `%docker.image%`:
```
ARCH=%pkg.arch% PKG_VERSION=%pkg.version% ./test-astra/%pkg.driver%
```
x86_64 = native gcc 8.4 in the image; arm/arm64 = same station's linaro cross-toolchain.
The driver does the Conan part only — TC pulls the image; no docker build/run in the step.

**Artifact paths** (General Settings):
```
%pkg.output%/*.nupkg => %pkg.arch%
```

**Agent requirements**: Linux agent with Docker. (ARM leaves cross-compile on the same
x86_64 station — no ARM hardware.)

---

## Template 2 — `_TPL Conan Build Windows`

The `<PKG> BUILD <PKG> Windows x64` leaf. Runs **natively** on an MSVC agent (no Docker).
Provision once: MSVC toolset + Conan 2.29.0 (`test-windows\setup.bat`, offline from `packages\`).

| Param | Set by child? | Value / expression |
|---|---|---|
| `pkg.name` | ✅ | `gtest` |
| `pkg.version` | ✅ | `1.17.0` |
| `win.profile` | ✅ | `win-v143-x64` (x86 slot: `win-v142-x86`) |
| `win.slot` | ✅ | `win-x64` (or `win-x86`) |
| `pkg.driver.win` | no (derived) | `run_%pkg.name%_win.bat` |
| `pkg.output.win` | no (derived) | `output-%pkg.name%-win` |

**Build step** — *Command Line* (native):
```
set PROFILE_NAME=%win.profile% & set PKG_VERSION=%pkg.version% & test-windows\%pkg.driver.win%
```
**Artifact paths**: `%pkg.output.win%\*.nupkg => %win.slot%`

**Agent requirements**: Windows agent with the MSVC toolset for `%win.profile%`.

> Windows leg **NOT yet legacy-byte-validated** — `_short_compiler` emits `v192/v193/v194`
> instead of `v142/v143` (deployer fix pending, see `TEAMCITY-configs.md` §Status).
> Green-once before wiring the Windows publish. (Confirm the `.bat` drivers read
> `PKG_VERSION` — the Windows mirror of the `PKG_VERSION` fallback may still be pending.)

---

## Template 3 — `_TPL Publish to Conan ProGet`

The `PUBLISH TO CONAN PROGET` config atop each `<PKG>_CONAN` subtree. Builds nothing —
collects the leaf `.nupkg` and pushes to the `conan` feed.

**Artifact dependencies** (per instance — leaf config IDs differ per package): from each
Linux/ARM/ARM64 (and Windows, once green) build config → `*.nupkg => nupkg/`.

**Build step** — *Command Line*:
```
API_KEY=%ProGet.ApiKey% PROGET_URL=%PROGET_URL% FEED=%FEED% NUPKG_DIR=nupkg \
    ./test-astra/tc_publish_conan.sh
```
`409 (already in feed)` counts as success — re-runnable, idempotent.

**Trigger** (optional): Finish Build trigger on the arch leaves so publish runs after a
green build set.

---

## Create a new package — checklist (variable-driven)

Example: publish `zlib 1.3.1` as a standalone package.

1. Ensure the driver exists: `test-astra/build_zlib_nodocker.sh` (+ Windows mirror). It must
   read `PKG_VERSION` (generic fallback), like gtest/fmt do.
2. Create subproject `ZLIB_CONAN`; inside it `Linux`, `Linux ARM`, `Windows` sub-projects.
3. Create the leaves *based on* the templates and set **only the human variables**:
   - Linux → T1: `pkg.name=zlib`, `pkg.version=1.3.1`, `pkg.arch=x86_64`.
   - Linux ARM → two T1 leaves: same, `pkg.arch=arm` / `arm64`.
   - Windows → T2: `pkg.name=zlib`, `pkg.version=1.3.1`, `win.profile=win-v143-x64`, `win.slot=win-x64`.
4. `PUBLISH TO CONAN PROGET` *based on* T3; wire artifact deps to the leaves.
5. Record the row in `TEAMCITY-configs.md`.

**New version of an existing package** (gtest 1.17.0 → 1.18.0): edit one field,
`pkg.version = 1.18.0`, on each leaf (or bump it once at the `<PKG>_CONAN` project level
and let leaves inherit). The version is readable at a glance — never buried in a filename.

---

## grpc-line exception (why version isn't a free variable there)

`build_1601_nodocker.sh` / `build_1781_nodocker.sh` pin a **7-package stack** (grpc +
protobuf + abseil + re2 + c-ares + openssl + zlib) via an internal `EXPORTS` map, and grpc
needs a per-version `grpc/target_info/grpc_<ver>.yml`. So a new grpc version is **not** a
`pkg.version` change — it's a new driver + new target-info YAML (a recipe task, not a TC
task). For the grpc leaves use these params instead:

| Param | Human | Example |
|---|---|---|
| `pkg.line` | ✅ | `1601` \| `1781` |
| `pkg.version` | ✅ display-only | `1.60.1` \| `1.78.1` |
| `pkg.arch` | ✅ | `x86_64` \| `arm` \| `arm64` |
| `pkg.driver` | derived | `build_%pkg.line%_nodocker.sh` |
| `pkg.output` | derived | `output-grpc-%pkg.line%-%pkg.arch%` |

Build step: `ARCH=%pkg.arch% ./test-astra/%pkg.driver%` (no `PKG_VERSION` — the driver
pins its own stack). `pkg.version` here is purely for a readable config name/label.

Where the `<PKG>_CONAN` subtree sits in the TC tree (own project vs alongside legacy
`GRPC`/`GR1xx`) and publish policy (overwrite vs `.1` suffix) — **lead decision**
(`TEAMCITY-grpc-tree.md`).
