# IN-658 — Documentation

Документация миграции 7 third-party C++ библиотек (zlib, openssl, abseil, c-ares, re2, protobuf, grpc) на Conan 2.x. Тикеты IN-353 (x86_64) и IN-658 (ARM cross + downstream-stabilization).

## Где что

| Документ | Аудитория | Язык |
|---|---|---|
| [STATUS.md](STATUS.md) | Лиду / в Jira IN-658 | Русский |
| [CONFLUENCE.md](CONFLUENCE.md) | Confluence overview | Русский |
| [DEVOPS-RUNBOOK.md](DEVOPS-RUNBOOK.md) | CI / DevOps | Русский |
| [DOWNSTREAM-MIGRATION.md](DOWNSTREAM-MIGRATION.md) | Команды el_conf / grpc_sdk / sura / прочие | Русский |
| [DEVELOPER.md](DEVELOPER.md) | Следующий разработчик conan-recipes | English |
| [MIGRATION-PLAYBOOK.md](MIGRATION-PLAYBOOK.md) | Полный playbook миграции: методология + lessons learned + улучшения + антипаттерны | Русский |
| [USAGE.md](USAGE.md) | Hands-on инструкция: как пользоваться Conan + нашими `.nupkg` (first steps, команды, workflow'ы, diagnostic checklist) | Русский |
| [CONANFILE-ANATOMY.md](CONANFILE-ANATOMY.md) | Deep-dive структуры 9 наших `<pkg>/conanfile.py` (lifecycle, offline-edits, patches, per-package) | Русский |

## Быстрый старт по ролям

- **Лид смотрит, готова ли IN-658 к закрытию x86_64-фазы:** → `STATUS.md`
- **DevOps хочет настроить TC-конфиг:** → `DEVOPS-RUNBOOK.md` § "TeamCity конфигурация"
- **Команда el_conf хочет понять что менять в своих CMakeLists.var:** → `DOWNSTREAM-MIGRATION.md`
- **Confluence-страница для команды/проекта:** → `CONFLUENCE.md`
- **Впервые ставлю Conan / хочу собрать одну библиотеку:** → `USAGE.md` (start here)
- **Я следующий разработчик и должен расширять рецепты:** → `DEVELOPER.md` (orientation) + `CONANFILE-ANATOMY.md` (структура рецептов) + `MIGRATION-PLAYBOOK.md` (полная методология + lessons learned + антипаттерны + чек-листы)
- **Хочу понять "как мигрировать новый пакет шаг за шагом":** → `MIGRATION-PLAYBOOK.md` Часть 1
- **Столкнулся с непонятным багом (linker, namespace, proto):** → `MIGRATION-PLAYBOOK.md` Часть 2 (21 описанный кейс) + `USAGE.md` § 11 (diagnostic checklist)
- **Что улучшить / антипаттерны / координация с лидом:** → `MIGRATION-PLAYBOOK.md` Часть 3
- **Хочу понять как именно структурирован отдельный `<pkg>/conanfile.py`:** → `CONANFILE-ANATOMY.md`

## Ключевые коммиты IN-658

`03a20c0` `3d9ae77` `615cf9f` `6674d29` `5df4aa6` `3b3485a` `457ad47` `7bb065d` `a611fc1`

Каждый разобран в `STATUS.md` таблицей "что/зачем".

## Связанные документы вне docs/IN-658/

- `../../README.md` — общий README проекта.
- `../../test-astra/HELP.txt` — пронумерованные диагностические блоки.
- `../../test-astra/TESTING_ARM.md` — runbook ARM.
- `../../test-astra/NEXT_STEPS.md` — исторический лог ARM-фазы.
- `../../CLAUDE.md` (local-only) — контекст для Claude Code.
