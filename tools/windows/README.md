# Windows build-tools (offline)

В этой папке хранятся ZIP-архивы Strawberry Perl + NASM, нужные для сборки `openssl` на Windows. Распакованные `strawberryperl/` и `nasm/` git-игнорятся.

## Что должно быть здесь

```
tools/windows/
├── README.md                                   ← этот файл
├── strawberryperl-5.32.1.1-portable.zip        ← Strawberry Perl Portable, ~150 MB
├── nasm-2.16.01-win64.zip                      ← NASM, ~1 MB
├── strawberryperl/                             ← (создаётся install_deps.bat)
│   └── perl/bin/perl.exe
└── nasm/                                        ← (создаётся install_deps.bat)
    └── nasm.exe
```

## Как заполнить

### Сценарий A — на машине с интернетом

```cmd
cd <repo-root>
test-windows\install_deps.bat
```

Скрипт сам скачает Strawberry Perl с https://strawberryperl.com и NASM с https://www.nasm.us, положит ZIP-ы сюда, и распакует.

### Сценарий B — оффлайн-машина

1. Скачайте на машине с интернетом:
   - https://strawberryperl.com/download/5.32.1.1/strawberry-perl-5.32.1.1-64bit-portable.zip → переименуйте в `strawberryperl-5.32.1.1-portable.zip`
   - https://www.nasm.us/pub/nasm/releasebuilds/2.16.01/win64/nasm-2.16.01-win64.zip
2. Положите оба файла в `tools/windows/` (через USB / shared folder / etc.).
3. На оффлайн-машине: `test-windows\install_deps.bat` — увидит готовые архивы, скачивание пропустит, распакует.

## Размер и git

- `nasm-*.zip` (~1 MB) — можно держать в обычном git.
- `strawberryperl-*-portable.zip` (~150 MB) — превышает лимит GitHub 100 MB на файл. Варианты:
  - **Не коммитить** — переносить вручную (USB) на каждый билд-агент.
  - **Git LFS** — если включён в репо: `git lfs track "tools/windows/strawberryperl-*.zip"`.
  - **Внутренний artifact storage** — выложить туда, ссылка в `install_deps.bat`.

В `.gitignore` сейчас исключены только распакованные папки (`strawberryperl/`, `nasm/`). Сами ZIP-архивы можно коммитить, если размер позволяет, или добавить отдельным правилом.

## Версии

Если поменяли версию — отредактируйте переменные `PERL_VER`/`NASM_VER` в `test-windows/install_deps.bat` и `[platform_tool_requires]` в `profiles/win-*`.
