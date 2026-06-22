# Новый пакет за 6 шагов (короткая версия)

Полная версия со всеми нюансами — `GUIDE-new-recipe-from-zero.md`.
Здесь — минимум, чтобы добавить новую third-party либу как Conan-рецепт и
получить legacy `.nupkg`.

**Идея:** рецепт = канонический `conanfile.py` из conan-center-index + 2 offline-правки.
Сборка идёт компилятором **gcc 8.4 внутри образа `grpc-tc-mirror`** (отсюда `gcc84` в
имени). Имя и структуру `.nupkg` делает `legacy_nupkg.py` сам — его не трогаем.

---

## Шаг 1 — каталог рецепта
Создай `<pkg>/` (имя = Conan-имя пакета):
```
<pkg>/
├── conanfile.py        # канонический из conan-center-index + 2 правки (шаг 3)
├── conandata.yml       # из conan-center-index, URL/sha256 НЕ менять
├── src/<file>.tar.gz   # offline-архив исходников (шаг 2)
├── patches/<version>/  # локальные патчи, если нужны (регистрируются в conandata.yml)
└── test_package/       # канонический conan-смоук
```
`conanfile.py` + `conandata.yml` + `test_package/` бери из
[conan-center-index](https://github.com/conan-io/conan-center-index/tree/master/recipes).

## Шаг 2 — исходники офлайн
На машине с интернетом скачай тарбол по URL из `conandata.yml`, положи в `<pkg>/src/`
**под тем же именем файла, что в URL**. В реальной сборке сети нет.

## Шаг 3 — две offline-правки в `conanfile.py`
Канонический рецепт качает исходники из сети — заставь брать локальный архив:

**(a)** объяви экспорт архива (рядом с другими атрибутами класса):
```python
exports_sources = "src/*.tar.gz"
```
**(b)** в `source()` — сначала локальный `src/`, потом fallback на `get()`:
```python
def source(self):
    local = os.path.join(self.export_sources_folder, "src", f"<name>-{self.version}.tar.gz")
    if os.path.exists(local):
        unzip(self, local, destination=self.source_folder, strip_root=True)
    else:
        get(self, **self.conan_data["sources"][self.version],
            destination=self.source_folder, strip_root=True)
```
`<name>-{version}` подгони под реальное имя тарбола в `src/`. **`conandata.yml` не трогаем.**

## Шаг 4 — legacy-имя/версия (только если отличаются)
Если CI-имя пакета ≠ Conan-имя, или legacy-версия другая — добавь в
`extensions/deployers/legacy_nupkg.py`:
- `LEGACY_NAME_MAP` — Conan-имя → CI-имя (`gtest→googletest`, `abseil→absl`, `c-ares→cares`)
- `LEGACY_VERSION_MAP` — Conan-версия → legacy-слот (напр. `abseil/20230802.1 → absl/0.2.0`)

Совпадают — ничего не добавляй.

## Шаг 5 — собрать в Docker (gcc84) + упаковать
Release **и** Debug (упаковщику нужны оба) + deployer:
```bash
mkdir -p output
sudo docker run --rm -v "$(pwd):/work/conan-recipes" grpc-tc-mirror bash -lc '
  set -e
  conan create <pkg>/ --version=<ver> -pr:h="$PROFILE" -pr:b="$PROFILE" -s build_type=Release --build=missing --no-remote
  conan create <pkg>/ --version=<ver> -pr:h="$PROFILE" -pr:b="$PROFILE" -s build_type=Debug   --build=missing --no-remote
  conan install --requires=<pkg>/<ver> -pr:h="$PROFILE" -pr:b="$PROFILE" --no-remote \
    --deployer=extensions/deployers/legacy_nupkg.py --deployer-folder=output/'
```
`-v $(pwd):…` монтирует текущий рецепт в образ; `$PROFILE` внутри = `lin-gcc84-x86_64`
(кавычки одинарные — `$PROFILE` раскрывается ВНУТРИ контейнера).

## Шаг 6 — проверить
```bash
ls -lh output/<legacy-name>.*.nupkg
unzip -l output/<legacy-name>.lin.gcc84.shared.x86_64.<ver>.nupkg | head
```
Ожидаемо: имя с **`gcc84`**, внутри `lib/native/.../*.a` + папка `include/`.
Если в имени `gcc8` (без «4») — собралось не в образе, это смоук, **не для поставки**.

---

## Три контракта (не нарушать)
1. **Имя/структуру `.nupkg`** руками не делать — это `legacy_nupkg.py`.
2. **Всё offline** — `conandata.yml` (URL/sha256) не трогать; локальные правки только через `patches/<version>/`.
3. **Боевой пакет — всегда gcc84/Docker.** Голая VM (`astra-gcc`) даёт `gcc8` = только смоук.

## Глубже
- Нюансы (ARM-кросс, компоненты, гранулярность abseil, grpc `target_info`) — `GUIDE-new-recipe-from-zero.md`.
- Сборка существующего рецепта в `.nupkg` — `HOWTO-create-package.md`.
- Диагностика — `HELP.txt`.
