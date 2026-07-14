# Third-party → Conan: полный бэклог миграции

Цель: **все third-party пакеты SURA2 собираются через Conan, последних версий**,
с легаси-именами `.nupkg`. Источник списка — легаси-дерево SURA2 (транскрипции
скринов TeamCity от 2026-04-29, `photos/2026-04-29/INDEX.md` в workspace).

Конвейер готов: пакет = рецепт-зеркало conan-center + оффлайн-тарбол в `<pkg>/src/`
+ (при need) строка в `LEGACY_NAME_MAP`/`LEGACY_DEP_VERSION_MAP` deployer'а
+ **одна строка** `conanPackage(ConanPkg("<имя>", "<версия>", code = "XX"))` в
`conan-tc-sandbox/.teamcity/settings.kts` — вся матрица (i686/x86_64/arm/arm64 +
4 виндовых слота + publish) появляется сама. Методика добавления рецепта —
`test-astra/GUIDE-new-recipe-from-zero.md`.

## Волна 0 — ГОТОВО (IN-353/IN-658)

| Легаси | Conan | Статус |
|---|---|---|
| ZLIB | zlib | зелёный весь конвейер |
| GOOGLETEST | gtest | зелёный |
| ABSL | abseil | зелёный (absl @ 0.2.0 map) |
| CARES | c-ares | зелёный |
| RE2 | re2 | зелёный |
| PROTOBUF | protobuf | зелёный (в составе линий grpc) |
| OPENSSL | openssl | зелёный (Linux; win-x86 добит 2026-07-13) |
| GRPC | grpc (линии 1601/1781) | зелёный |
| FMT | fmt | зелёный (первый «новый» пакет конвейера) |
| ADDRESS_SORTING, UPB, UTF8_RANGE | — | **отдельно НЕ нужны**: это подкомпоненты grpc/protobuf-сборки; upb вшивается в libgrpc.a (upb-fold), остальное внутри пакетов линии |

## Волна 1 — простые, рецепт в conan-center есть, зависимостей нет/минимум

Порядок внутри волны произвольный, каждый ~0.5–1 день (рецепт+тарбол+смоук).

| Легаси | Conan-рецепт | Прим. |
|---|---|---|
| CJSON | cjson | |
| EXPAT | expat | |
| TINYXML2 | tinyxml2 | |
| SQLITE | sqlite3 | |
| JANSSON | jansson | |
| JSONCPP | jsoncpp | |
| JSON | nlohmann_json? | сверить: легаси JSON = nlohmann или внутренний врапер |
| LUA | lua | |
| LIBZIP | libzip | dep: zlib ✓ |
| PTHREADS4W | pthreads4w | Windows-only слоты |

## Волна 2 — зависят от волны 0/1, рецепты в CCI есть

| Легаси | Conan-рецепт | Deps |
|---|---|---|
| CURL | libcurl | openssl, zlib |
| LIBXML2 | libxml2 | zlib |
| MBEDTLS | mbedtls | — |
| SSH2 | libssh2 | openssl, zlib |
| ZMQ | zeromq | — (map zeromq→zmq) |
| MOSQUITTO | mosquitto | openssl |
| MODBUS | libmodbus | — |
| MONGOOSE | mongoose | openssl? |
| NANOPB | nanopb | protobuf(protoc) |
| NETSNMP | net-snmp | openssl |
| LIBPQ | libpq | openssl |
| XERCES_C | xerces-c | |
| DBUS | dbus | Linux-only слоты? сверить легаси-матрицу |
| QWT | qwt | **Qt** — сначала решить, откуда Qt (вне бэклога) |

## Волна 3 — рецепта в CCI нет / нишевые / вопросы к лиду

| Легаси | Что это | Путь |
|---|---|---|
| SNAP7 | Siemens S7 comm (OSS, sourceforge) | рецепт с нуля |
| SOEM | EtherCAT master (OSS) | рецепт с нуля / CCI-PR существует? |
| LIBMATIEC | IEC 61131-3 matiec (OSS, нишевый) | рецепт с нуля |
| IEC61850LIB | libiec61850 (MZ Automation) | лицензия GPL/коммерч. — с лидом |
| QXORM, QWINDOWKIT | Qt-экосистема | вместе с решением по Qt |
| OPCUASDK, UASERVERCPP, UA_ANSIC | OPC UA стеки | проприетарные/фонд — НЕ conan-center, отдельное решение |
| CODESYS2 | проприетарный | вне Conan-миграции? — лид |

## НЕ third-party (внутренние Elara — не мигрируются этим конвейером)

CS_*, PLC_*, SERVICE_*, PROFIBUS_*, COMMSERVER, DAEMON, LOGGER, EXCEPTIONS,
CONTAINERS, CROSSPLATFORM, ELECONT_PROTO, EL_CONF, XML_PARSER, SYSLIBGEN,
THREAD_SDK, SIGNAL_*, ETHERCAT/SNMP/MQTT/MODBUS-враперы (внутренние SDK поверх
one-of third-party), BOARD_TEST, DIAG_MONITOR, INELBUSHANDLER, LCD_DISPLAY,
LED_CONTROLLER, OMRON_FINS, SIEMENS_S7, API_GATEWAY, EVENT_BUS_ADAPTER, ...

## Правила, единые для всех волн

1. **«Последняя версия» ≠ везде.** Независимые пакеты (волна 1–2) — upstream latest.
   Связанные стеки пиннятся комплектом: grpc-линия тащит СВОИ protobuf/absl/re2/
   cares/zlib/openssl (`grpc/target_info/grpc_<ver>.yml`); nanopb — от protoc.
   Конфликт «latest sqlite» vs «sqlite, который ждёт потребитель» решает слот-
   версия в фиде + пин потребителя, не рецепт.
2. **Ground truth имени** — легаси `.nupkg` в ProGet/фото (`<pkg>.lin.gcc84.
   shared.<arch>...`): перед стартом пакета найти его легаси-артефакт и свериться
   (имя, версия-слот, состав) — как делали absl @ 0.2.0.
3. Оффлайн: тарбол в `<pkg>/src/`, никаких URL в рантайме.
4. Каждому пакету — двухбуквенный код в `ConanPkg(code=...)`, чтобы не задваивались
   (GT/FM/GR заняты; CJSON→CJ, EXPAT→EX, ...).
5. Публикация в общий фид `conan`; политика столкновений версий (409/суффикс) —
   решение лида (см. absl-коллизию линий grpc в memory).
