# TeamCity — grpc Conan builds, Windows (MSVC)

Sibling of `test-astra/TEAMCITY-grpc-linux.md`, for the Windows MSVC stages.
Operational runbook: **`test-astra/HELP.txt [15]`**.

> **STATUS: NOT YET VALIDATED.** The Windows path has never built the grpc tree
> green end-to-end. The driver/spec below are ready to run on a Windows agent,
> but the first run is bring-up, not a rubber-stamp. Validation requires a
> Windows agent with MSVC + offline Conan — it could not be done from the Mac.

---

## Key difference from Linux: no Docker

Windows MSVC builds run **directly on the agent** (there is no container).
So unlike the Linux stages (which `docker build` + `docker run` a mirror image),
the Windows stage just needs the agent itself provisioned: MSVC toolset + Conan
2.29.0 installed offline via `test-windows\setup.bat`.

## Configs

| Config              | Profile          | Driver command                                  | Artefacts        |
|---------------------|------------------|-------------------------------------------------|------------------|
| Build Conan Win x64 | `win-v143-x64`   | `set PROFILE_NAME=win-v143-x64 & test_win.bat build` | `output\*.nupkg` |
| Build Conan Win x86 | `win-v142-x86`   | `set PROFILE_NAME=win-v142-x86 & test_win.bat build` | `output\*.nupkg` |

Produces `<pkg>.win.v1xx.shared.{x64,x86}.<ver>.nupkg` × 7
(`_short_compiler`: msvc 193→`v143`, 192→`v142`; `_arch_short` Windows: x86_64→`x64`).

## Build step

`test-windows\test_win.bat`:
1. Guards the Conan version (`EXPECT_CONAN`, default `2.29.0`) — fails loudly if
   the agent still has 2.27.1.
2. Sets `CI=1` and calls `run_test_grpc.bat` (the `CI` flag skips its interactive
   `pause`, which would otherwise hang the TC build forever).
3. Verifies the 7 `.nupkg` are present; non-zero exit on any miss.

## Shared settings

- **VCS root / branch / params:** same as Linux (`develop`).
- **Agent requirements:** `Windows` + the matching MSVC toolset (v143 = VS2022,
  v142 = VS2019).
- **Artefact rule:** `output\*.nupkg => win-x64` (resp. `win-x86`). Unlike Linux,
  the native build writes to `output\` (not `output-<arch>\`); keep the x64 and
  x86 configs on separate agents/checkout dirs or clean `output\` between them.

## Conan version — already on 2.29.0

`packages\` (the Windows offline wheel/sdist cache used by `setup.bat`) now ships
**`conan-2.29.0.tar.gz`** (was 2.27.1). The existing cp314-win dep wheels already
cover it: 2.29.0's runtime deps are identical to 2.27.1 except `patch-ng<1.20`,
satisfied by the present `patch-ng-1.18.1`. `setup.bat` installs with `--upgrade`,
so a pre-existing 2.27.1 on the agent is replaced. Just run:
```
cd <repo>\conan-recipes
test-windows\setup.bat
```
Offline dep resolution on Windows cp314 was reasoned out, not executed from macOS
— the first agent run is the final confirmation (the `test_win.bat` version guard
fails loudly if the agent is somehow still on 2.27.1).

## Out of scope (same as Linux)

Publish step to the ProGet NuGet feed and final TC placement/rename are lead
decisions (see `test-astra/TEAMCITY-grpc-linux.md`).
