# Diagrams (Excalidraw)

Open with excalidraw.com (drag & drop the file), the VS Code "Excalidraw"
extension, or the Obsidian Excalidraw plugin.

| File | Topic |
|---|---|
| `doc-1-migration-playbook.excalidraw` | Migrating a library to Conan 2.x — 10 steps + the hard contracts |
| `doc-2-deployer-nupkg.excalidraw` | `legacy_nupkg.py`: Conan package → legacy `.nupkg` (name maps, filename scheme, internal layout) |
| `doc-3-arm-cross-build.excalidraw` | ARM cross-build pipeline (`Dockerfile.grpc-tc-mirror` multi-stage, profiles, linaro toolchain) |
| `doc-4-architecture.excalidraw` | Workspace map + build flow to downstream / ProGet |
| `proget-sources-flow.excalidraw` | Conan backup-sources → ProGet: how sources are fetched (HELP `[16]`/`[19]`) |
| `grpc-conan-pipeline.excalidraw` | grpc/1.60.1 build pipeline on TeamCity: Bitbucket VCS → TC → pull станок from ProGet → build → deployer → `.nupkg` → artifacts (HELP `[22]`/`[24]`) |
