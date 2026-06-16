# Dockerfiles & publishing the build images to ProGet

This repo carries five Dockerfiles at the root. Only one —
`Dockerfile.grpc-tc-mirror` — is the production build image that gets published
to ProGet and consumed by TeamCity. The other four are local/online smoke
harnesses.

The build container **inherits** from the existing toolchain base images
(`gcc84-build-x86_64`, `gcc75-build-arm`, `gcc75-build-arm64`) and only adds
what Conan needs (Python + Conan + recipes). Those base images are infra-owned:
their Dockerfiles live in Bitbucket (`bitbucket.inc.elara.local`, branch
`develop`) and they are published to ProGet at `…/main/library/<name>:<tag>`.
We do **not** rebuild the toolchain here — `Dockerfile.grpc-tc-mirror` just does
`FROM <that base> + Conan`.

This document describes each Dockerfile and gives the full publish flow **two
ways**: by hand (so you understand every step) and via the
`test-astra/prebake_push.sh` driver (so you can do it in one command).

> Closed-network rule: every base image is pulled from ProGet
> (`proget.inc.elara.local`), never Docker Hub. ProGet is only reachable from
> the dev-VM, so all `docker build/push` here runs there, not on the Mac.

---

## 1. `Dockerfile.grpc-tc-mirror` — the production build mirror

Mirrors the TeamCity CI build environment so `conan create` produces `.nupkg`
artifacts byte-compatible with the legacy TC builds. One parameterized
Dockerfile covers all three architectures via `--build-arg`.

### Build args

| ARG | Default | Meaning |
|---|---|---|
| `X64_BASE_IMAGE` | `…/library/gcc84-build-x86_64:0.1.0` | x86_64 CI image donating `/usr/local/gcc-8.4` (Stage 1). |
| `BASE_IMAGE` | `gcc:8` (overridden in every real build) | Actual mirror base for Stage 2 (`gcc84-build-x86_64`, `gcc75-build-arm`, or `gcc75-build-arm64`). |

Both ARGs are declared **before the first `FROM`** so they are visible in every
`FROM` line (Docker scoping rule: an ARG between stages belongs to the
preceding stage only unless redeclared globally).

### Two stages

* **Stage 1 `x64_native_tc`** (`FROM ${X64_BASE_IMAGE}`) — copies
  `/usr/local/gcc-8.4` into a stable, symlink-dereferenced tree at
  `/opt/x64-native-gcc` (`cp -aL`) and creates unsuffixed aliases
  (`gcc → gcc-8.4`, `g++`, `cc`, `c++`, `cpp`, `gcc-ar/nm/ranlib`).
  *Why:* the arm/arm64 base images ship Debian Stretch system gcc 6.3, but
  abseil 20250127 needs gcc ≥ 7 for the build context (x86_64 protoc). The
  gcc-8.4 tree is carried over from the x86_64 image.

* **Stage 2** (`FROM ${BASE_IMAGE}`) — the actual mirror:
  * `COPY --from=x64_native_tc /opt/x64-native-gcc` — profile
    `lin-gcc84-x86_64` points `[buildenv]` CC/CXX and
    `tools.build:compiler_executables` here.
  * `COPY` of the recipe dirs (`zlib abseil c-ares re2 protobuf openssl grpc`),
    `profiles/`, `extensions/`, `test-astra/`, `packages-linux/`.
  * Unpacks standalone **CPython 3.11.10** from
    `packages-linux/cpython-3.11.10+…tar.gz` into `/opt/python` (Stretch's
    apt python3 maxes at 3.5; Conan 2 needs ≥ 3.7). Symlinked into
    `/usr/local/bin`.
  * `pip install --no-index --find-links=packages-linux conan` straight into
    `/opt/python` (no venv — `ensurepip` is broken in the standalone tarball
    and the container is isolation enough).

### ENV baked into the image

| ENV | Default | Meaning |
|---|---|---|
| `PROFILE` | `…/profiles/lin-gcc84-x86_64` | Host profile `run_test_grpc.sh` reads. ARM runs override it. |
| `CONAN_USER_TOOLCHAIN` | `""` | Empty for x86_64. ARM cross sets it to the linaro toolchain file; recipes read it in `generate()` (Conan 2.27.1 `[conf]`-propagation workaround). |
| `PROGET_SOURCES_URL` | `…/endpoints/conan-sources/content/` | Conan backup-sources base (HELP [16]). Set `-e PROGET_SOURCES_URL=""` to disable. |

The image also **bakes** `core.sources:download_urls` into
`/root/.conan2/global.conf` from `PROGET_SOURCES_URL`. This makes the image
self-sufficient for a plain `docker run` (no volume) and for a **fresh** named
cache volume (Docker seeds an empty volume from the image layer). A **reused**
`conan-cache-*` volume shadows that layer, so `test-astra/ensure_proget.sh`
(run by every build driver on start) still re-asserts the line — baked default
+ runtime re-assert.

### Output

`CMD` runs `test-astra/run_test_grpc.sh` → 7 `.nupkg` in `output/`:
`grpc, protobuf, abseil, openssl, re2, c-ares, zlib`. Published tags:

```
proget.inc.elara.local/main/library/grpc-tc-mirror-x86_64:0.1.0
proget.inc.elara.local/main/library/grpc-tc-mirror-arm:0.1.0
proget.inc.elara.local/main/library/grpc-tc-mirror-arm64:0.1.0
```

---

## 2. The four `*-test` Dockerfiles — local/online smoke only

`Dockerfile.astra-test`, `Dockerfile.gtest-test`, `Dockerfile.zlib-test`,
`Dockerfile.grpc-test` all `FROM gcc:12-bookworm` (Docker Hub) and run
`test-astra/setup.sh` (venv + offline Conan from `packages-linux/`), then a
single `run_*.sh`:

| Dockerfile | Builds | CMD |
|---|---|---|
| `Dockerfile.astra-test` | gtest (+ `example/`) | `run_test.sh` |
| `Dockerfile.gtest-test` | gtest | `run_gtest.sh` |
| `Dockerfile.zlib-test` | zlib | `run_zlib.sh` |
| `Dockerfile.grpc-test` | full grpc tree | `run_grpc.sh` |

**Keep, do not publish.** Their base is Docker Hub, so they are **not usable on
the closed network** and never go to ProGet. Their value is the opposite: they
are the *only* way to smoke a recipe on the Mac / any online host, because
`grpc-tc-mirror`'s base images live behind ProGet and can't be pulled there.
Treat them as throwaway dev harnesses. Example:

```bash
docker build -f Dockerfile.zlib-test -t zlib-test . && docker run --rm zlib-test
```

---

## 3. Publish the mirror images to ProGet — by hand

This is HELP `[10]`, condensed. Run on the dev-VM.

```bash
cd ~/conan-master            # repo root
export REGISTRY=proget.inc.elara.local/main
export MIRROR_VER=0.1.0
export X64_BASE_IMAGE_TAG=0.1.0
export ARM_BASE_IMAGE_TAG=0.1.0       # adjust per ProGet inventory
export ARM64_BASE_IMAGE_TAG=0.1.0     # adjust per ProGet inventory

# 0) login once (admin, or service account with Feed Administrator on `main`)
sudo docker login proget.inc.elara.local

# 1) build — one block per arch. x86_64 points BOTH build-args at gcc84
#    (Stage 1 donates gcc-8.4, Stage 2 uses it as the base).
sudo docker build \
    --build-arg X64_BASE_IMAGE=$REGISTRY/library/gcc84-build-x86_64:$X64_BASE_IMAGE_TAG \
    --build-arg BASE_IMAGE=$REGISTRY/library/gcc84-build-x86_64:$X64_BASE_IMAGE_TAG \
    -f Dockerfile.grpc-tc-mirror \
    -t $REGISTRY/library/grpc-tc-mirror-x86_64:$MIRROR_VER .

sudo docker build \
    --build-arg X64_BASE_IMAGE=$REGISTRY/library/gcc84-build-x86_64:$X64_BASE_IMAGE_TAG \
    --build-arg BASE_IMAGE=$REGISTRY/library/gcc75-build-arm:$ARM_BASE_IMAGE_TAG \
    -f Dockerfile.grpc-tc-mirror \
    -t $REGISTRY/library/grpc-tc-mirror-arm:$MIRROR_VER .

sudo docker build \
    --build-arg X64_BASE_IMAGE=$REGISTRY/library/gcc84-build-x86_64:$X64_BASE_IMAGE_TAG \
    --build-arg BASE_IMAGE=$REGISTRY/library/gcc75-build-arm64:$ARM64_BASE_IMAGE_TAG \
    -f Dockerfile.grpc-tc-mirror \
    -t $REGISTRY/library/grpc-tc-mirror-arm64:$MIRROR_VER .

# 2) smoke each image before push (python3, conan, gcc-8.4, baked global.conf)
for ARCH in x86_64 arm arm64; do
    sudo docker run --rm $REGISTRY/library/grpc-tc-mirror-$ARCH:$MIRROR_VER bash -c '
        /opt/python/bin/python3 --version
        conan --version
        /opt/x64-native-gcc/bin/gcc --version | head -1
        grep -F core.sources:download_urls /root/.conan2/global.conf'
done

# 3) push
for ARCH in x86_64 arm arm64; do
    sudo docker push $REGISTRY/library/grpc-tc-mirror-$ARCH:$MIRROR_VER
done

# 4) verify the round-trip from a clean daemon (simulates a fresh TC agent)
for ARCH in x86_64 arm arm64; do
    sudo docker image rm $REGISTRY/library/grpc-tc-mirror-$ARCH:$MIRROR_VER || true
    sudo docker pull $REGISTRY/library/grpc-tc-mirror-$ARCH:$MIRROR_VER
done

# 5) acceptance: 7 .nupkg end-to-end from the PUBLISHED tag
./test-astra/run_prebake.sh x86_64
./test-astra/run_prebake.sh arm
./test-astra/run_prebake.sh arm64
```

### Versioning rule

Never overwrite a tag. On any change to `Dockerfile.grpc-tc-mirror`, the linaro
toolchain, or the Conan pin, bump `MIRROR_VER` (`0.2.0`, `0.3.0`, …) so TC runs
that pinned an older tag stay reproducible. Prune old tags later via ProGet
Settings → Retention once a new one is proven.

---

## 4. Publish via the driver — `test-astra/prebake_push.sh`

Same flow as §3, automated. Build → smoke → push → verify-pull for one or all
arches. Run on the dev-VM after `docker login`.

```bash
sudo docker login proget.inc.elara.local

./test-astra/prebake_push.sh                  # all three arches, push + verify
./test-astra/prebake_push.sh x86_64           # one arch
./test-astra/prebake_push.sh arm arm64        # a subset

PUSH=0      ./test-astra/prebake_push.sh x86_64   # build + smoke only (no push)
E2E=1       ./test-astra/prebake_push.sh arm64    # + full 7-nupkg acceptance
DRY_RUN=1   ./test-astra/prebake_push.sh          # print every docker cmd, run nothing
```

Env knobs: `REGISTRY` (default `proget.inc.elara.local/main`), `MIRROR_VER`
(`0.1.0`), `X64_BASE_IMAGE_TAG` / `ARM_BASE_IMAGE_TAG` / `ARM64_BASE_IMAGE_TAG`
(`0.1.0`), `PUSH` (`1`), `VERIFY_PULL` (`1`), `E2E` (`0`), `NO_CACHE` (`0`),
`DRY_RUN` (`0`).

`DRY_RUN=1` runs anywhere (no Docker daemon needed) — use it on the Mac to
preview the exact `docker build/push` commands before running for real on the
dev-VM.

### Producer vs consumer

* `prebake_push.sh` is the **producer** — builds and publishes the tags.
* `run_prebake.sh` is the **consumer/acceptance** — fresh-pulls a *published*
  tag and rebuilds the 7 `.nupkg` end-to-end. `prebake_push.sh E2E=1` chains it.

---

## 5. Troubleshooting

| Symptom | Cause / fix |
|---|---|
| `denied: requested access to the resource is denied` on push | Not logged in, or no push rights. `docker login`, or get Feed Administrator on `main`. |
| Stage 2 fails on `COPY --from=x64_native_tc /opt/x64-native-gcc` | x86_64 base tag mismatch. Pull the real `gcc84-build-x86_64:<tag>` and pass `X64_BASE_IMAGE_TAG=<tag>`. |
| `docker pull` fails on x509 | self-signed TLS — HELP `[X]`. |
| smoke: `no linaro cross-gcc in image` (arm/arm64) | wrong/short base image, or Stage 2 didn't get the toolchain — check `BASE_IMAGE` arch. |
| e2e: 0 `.nupkg`, transient deps recompiled with `/usr/bin/cc` | `CONAN_USER_TOOLCHAIN` not set in the run (ARM only). Not an image bug. |
| grpc compile dies `No space left on device` writing `/tmp/cc*.s` | overlay2 layer full — `run_prebake.sh` has the disk pre-flight + named-volume fix; use it, don't bare `docker run`. |
