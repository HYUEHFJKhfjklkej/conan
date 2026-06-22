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
| `grpc-conan-pipeline.excalidraw` | grpc/1.60.1 build pipeline on TeamCity (high-level flow), HELP `[22]`/`[24]` |
| `teamcity-conan-architecture.excalidraw` | **Current** TC setup: TeamCity runs the step inside the станок via "Run step within Docker container" (image in build params, Pull explicitly); `build_1601_nodocker.sh` does the conan part. HELP `[25]` |
| `conan-migration-checklist.excalidraw` | Что нужно для миграции на Conan — простым языком: код в репо / инфраструктура / проверка+правила, со статусами |
| `conan-new-package.excalidraw` | Новый пакет: 7 шагов создать+подключить + особенности сборки (что помнить) — простым языком |
