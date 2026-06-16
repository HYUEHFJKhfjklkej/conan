# base-images/ — toolchain base image Dockerfiles

The base (toolchain) images the build mirror sits on top of. They live in
Bitbucket (`bitbucket.inc.elara.local`, branch `develop`) and are published to
ProGet at `proget.inc.elara.local/main/library/<name>:<tag>`. This directory
brings their Dockerfiles under version control alongside the recipes.

## Image chain

```
nuget:4.8.1                 Mono + NuGet CLI (packs .nupkg)        [not in repo]
  └── build-tools:0.1.0     + cmake, protoc, clang-tools, lcov…    build-tools/Dockerfile
        ├── gcc84-build-x86_64   + gcc84/gcc53, qt5, linuxdeployqt, pvs   gcc84-build-x86_64/Dockerfile
        ├── gcc75-build-arm      + linaro 7.5 armv7hf cross toolchain     gcc75-build-arm/Dockerfile     (SCAFFOLD)
        └── gcc75-build-arm64    + linaro 7.5 aarch64 cross toolchain     gcc75-build-arm64/Dockerfile   (SCAFFOLD)
```

These base images are the input to `../Dockerfile.grpc-tc-mirror` (passed as
`--build-arg BASE_IMAGE=…` / `X64_BASE_IMAGE=…`). See `../DOCKERFILES.md`.

## Provenance & status — READ THIS

| File | Source | Status |
|---|---|---|
| `gcc84-build-x86_64/Dockerfile` | Bitbucket photo 2026-05-04 (`photos/2026-05-04/INDEX.md`, `…_16-54-37.jpg`), fully legible | **Faithful transcription** |
| `build-tools/Dockerfile` | Bitbucket photo 2026-05-04 (`…_16-57-53.jpg`), blurred/color-fringed | **Transcription with `<< VERIFY >>` lines** (base tag + apt package names only partially legible) |
| `gcc75-build-arm/Dockerfile` | none — no photo/transcript exists | **SCAFFOLD** — `<< TODO >>` linaro install must be filled |
| `gcc75-build-arm64/Dockerfile` | none — no photo/transcript exists | **SCAFFOLD** — `<< TODO >>` linaro install must be filled |

The transcriptions reflect the Bitbucket state **as seen on 2026-05-04** — i.e.
*before* any rework. They are reference, not the authority: Bitbucket on
`develop` is the source of truth, and structural changes to the CI toolchain go
through the team lead.

## What's needed to finish

1. **Your reworked content.** If you changed any of these images, paste the diff
   (or the new Dockerfile) and it gets applied here verbatim.
2. **`build-tools` `<< VERIFY >>` lines** — confirm the base `name:tag` (photo
   showed an illegible `<base>:0.0.1`; chain notes suggest `nuget:4.8.1`) and the
   six `*-devel-elara` package names on the install line.
3. **Both `gcc75-*` `<< TODO >>` lines** — the real mechanism that installs the
   linaro 7.5-2019.12 cross toolchain into `/opt/linaro-arm-7.5.0/` and
   `/opt/linaro-arm64-7.5.0/` (custom `*-devel-elara` deb, or `ADD` of the
   linaro tarball). The scaffolds intentionally `RUN false` so they cannot be
   built unfilled.

## Building (once filled, on the dev-VM — closed network)

```bash
cd base-images
sudo docker build -t proget.inc.elara.local/main/library/build-tools:0.1.0        build-tools/
sudo docker build -t proget.inc.elara.local/main/library/gcc84-build-x86_64:0.1.0 gcc84-build-x86_64/
sudo docker build -t proget.inc.elara.local/main/library/gcc75-build-arm:0.1.0    gcc75-build-arm/
sudo docker build -t proget.inc.elara.local/main/library/gcc75-build-arm64:0.1.0  gcc75-build-arm64/
# then docker push each (same login/rights as the mirror images — see ../DOCKERFILES.md §3)
```
