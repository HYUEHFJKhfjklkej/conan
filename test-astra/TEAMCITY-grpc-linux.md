# TeamCity — grpc Conan builds, Linux (x86_64 + ARM + ARM64)

Spec for the three Linux build configurations that produce the legacy-compatible
`.nupkg` set for the grpc tree (grpc + protobuf + abseil + openssl + re2 + c-ares + zlib).
This is the **"scripts + spec" deliverable** — TeamCity here is configured by hand in
the UI (there is no `.teamcity/settings.kts` in the repo), so this document is the
source of truth that gets pasted into the build configs.

Operational runbook for the exact commands: **`HELP.txt [14]`** (+ `[13]` for the
Conan-version migration, `[9]` for ELF/byte-compat acceptance).

---

## Current state (2026-06-08)

`SANDBOX / GRPC_CONAN_ARM` already exists with two **green** configs:

| Config            | Build | Driver                              | Artefacts            | Conan |
|-------------------|-------|-------------------------------------|----------------------|-------|
| Build Conan ARM   | #1 ✅ | `test_arm_cross.sh build arm`       | `arm/*.nupkg` (7)    | 2.27.1 (old) |
| Build Conan ARM64 | #5 ✅ | `test_arm_cross.sh build arm64`     | `arm64/*.nupkg` (7)  | 2.27.1 (old) |

Both were built on **Conan 2.27.1** and must be re-run on **2.29.0** (see Migration).
This spec adds a third config and brings all three onto the new Conan:

| Config              | State | Driver                          | Artefacts             |
|---------------------|-------|---------------------------------|-----------------------|
| **Build Conan x86_64** | NEW   | `test_x86_64.sh build`          | `x86_64/*.nupkg` (7)  |
| Build Conan ARM     | migrate | `test_arm_cross.sh build arm`   | `arm/*.nupkg` (7)     |
| Build Conan ARM64   | migrate | `test_arm_cross.sh build arm64` | `arm64/*.nupkg` (7)   |

> **Lead decision (not set here):** final placement of these configs — keep in
> `SANDBOX/GRPC_CONAN_ARM` (rename → `GRPC_CONAN`, it is no longer ARM-only),
> replace the legacy `GR121/GR122` configs, run in parallel, or a dedicated
> section. And the **publish step** (push `.nupkg` to a ProGet NuGet feed,
> with/without the `LEGACY_NUPKG_VERSION_SUFFIX=.1` coexistence tag) is
> intentionally out of scope below until that is decided.

---

## Shared settings (all three configs)

- **VCS root:** `github.com:HYUEHFJKhfjklkej/conan.git`, branch **`develop`**
  (the existing ARM builds are tagged `develop`). Checkout dir = repo root;
  the drivers assume the repo at `conan-recipes/`.
- **Agent requirements:** `Linux` + Docker daemon reachable via `sudo docker`.
  Same agent pool as the existing ARM stages (the x86_64 build also runs inside
  Docker — never on a bare dev-VM; Astra's system gcc ≠ gcc 8.4).
- **Parameters:**
  - `env.REGISTRY = proget.inc.elara.local/main` (ProGet host + main feed; the
    drivers pull the gcc8.4 / linaro base images from `$REGISTRY/library/*`).
  - optional `env.BASE_IMAGE_TAG = 0.1.0` (base-image tag override).
- **Build step:** a single "Command Line" step running the driver (below).
  The drivers self-verify (7 `.nupkg`, name scheme, Conan-version guard) and
  exit non-zero on any failure — so the step's success == acceptance.
- **Failure conditions:** default + "build process exit code != 0".
- **Artefact storage note:** `grpc.*.nupkg` is large (~400 MB for arm64).
  Set a tight artefact retention / cleanup policy so the agent disk and the
  artefact store do not fill up.

---

## Config 1 — Build Conan x86_64 (NEW)

- **Build step (Command Line):**
  ```bash
  export REGISTRY=proget.inc.elara.local/main
  FRESH_CACHE=1 ./test-astra/test_x86_64.sh build
  ```
  `FRESH_CACHE=1` is only needed on the first run / after a Conan bump; it wipes
  the `conan-cache-x86_64` Docker volume so no stale packages are reused. Drop it
  for routine builds to keep the warm cache.
- **Artefact rule:** `output-x86_64/*.nupkg => x86_64`
  (mirrors the `arm/` and `arm64/` artefact folders of the existing configs).
- **What it produces:** `<pkg>.lin.gcc84.shared.x86_64.<ver>.nupkg` × 7 — note
  `gcc84` (native gcc 8.4) and **no** `-linaro` suffix (the driver fails the
  build if a `-linaro` artefact appears — that would mean a cross profile leaked).
- **Trigger:** VCS trigger on `develop` (same as ARM), or manual to start.

## Config 2/3 — Build Conan ARM / ARM64 (migrate to 2.29.0)

The driver and artefact rules are unchanged from today; the migration is purely
operational (new Conan + clean cache):

- **Build step (ARM):**
  ```bash
  export REGISTRY=proget.inc.elara.local/main
  sudo docker volume rm conan-cache-arm || true   # one-time on the 2.29.0 cut-over
  ./test-astra/test_arm_cross.sh build arm
  ```
  (ARM64: `conan-cache-arm64` + `test_arm_cross.sh build arm64`.)
- **Artefact rule:** `output-arm/*.nupkg => arm` (resp. `output-arm64 => arm64`).
- **Produces:** `<pkg>.lin.gcc75.shared.arm{,64}-linaro.<ver>.nupkg` × 7.

After the one-time cache wipe, remove the `docker volume rm` line so subsequent
builds reuse the warm 2.29.0 cache.

---

## Migration to Conan 2.29.0 — why and the one gotcha

The mirror image is rebuilt from `Dockerfile.grpc-tc-mirror` on every run, and
Conan is installed offline by glob (`pip --no-index --find-links=packages-linux
conan`). `packages-linux/` now holds only `conan-2.29.0.tar.gz`, so **any fresh
build already uses 2.29.0** — no Dockerfile edit needed.

The single non-obvious step: the per-arch Conan **cache volumes**
(`conan-cache-arm`, `conan-cache-arm64`, and the new `conan-cache-x86_64`) are
persistent and were populated by 2.27.1. If not purged, a "2.29.0" build will
silently reuse 2.27.1-compiled packages. The drivers expose `FRESH_CACHE=1`
(x86_64) / the explicit `docker volume rm` (ARM) for exactly this cut-over.

Acceptance before declaring a config green: byte-compat diff against a known-good
2.27.1 artefact set — `diff_two_dirs.sh output-2271-<arch>/ output-<arch>/` —
only timestamp/build-stamp noise allowed (`HELP.txt [13]` step 3, `[9]` ELF check).

---

## Not in this spec (open / blocked)

- **Publish step → ProGet NuGet feed** — needs the target feed + creds and the
  coexistence decision (overwrite legacy vs `LEGACY_NUPKG_VERSION_SUFFIX=.1`).
  Lead decision.
- **Final TC placement / rename** (`GRPC_CONAN_ARM` → `GRPC_CONAN`, replace
  `GR121/GR122`, parallel, or separate section). Lead decision.
- **Immutable images in ProGet** (`run_prebake.sh` + `HELP.txt [10]`) — an
  optional optimisation so TC pulls a pinned image instead of rebuilding the
  mirror at-call-time. The current at-call-time rebuild is what makes the ARM
  stages green today, so this is not a blocker.
- **Windows / i686** — separate spec (Windows never validated; i686 unconfirmed).
