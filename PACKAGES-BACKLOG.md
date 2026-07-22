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

Версии проверены 2026-07-14 (CCI latest / upstream latest). Правило: берём
CCI-версию (рецепт проверен сообществом); если апстрим ушёл дальше — фиксируем
в примечании, догоняем добавлением версии в conandata после смоука.

| Легаси | Conan-рецепт | Версия к миграции | Прим. |
|---|---|---|---|
| CJSON | cjson | **1.7.19** | ГОТОВО 2026-07-14 (легаси был 1.7.15) |
| EXPAT | expat | 2.8.2 | = upstream |
| TINYXML2 | tinyxml2 | 11.0.0 | = upstream |
| SQLITE | sqlite3 | 3.53.3 | |
| JANSSON | jansson | 2.14 | upstream уже 2.15.1 — CCI отстаёт, стартуем с 2.14 |
| JSONCPP | jsoncpp | 1.9.6 | upstream 1.9.8 — CCI отстаёт |
| JSON | nlohmann_json | 3.12.0 | сверить: легаси JSON = nlohmann или внутренний врапер |
| LUA | lua | 5.5.0 | легаси был 5.4.2 (мажор-бамп 5.4→5.5! потребители — сверить API) |
| LIBZIP | libzip | 1.11.4 | dep: zlib ✓ |
| PTHREADS4W | pthreads4w | 3.0.0 | Windows-only слоты; легаси 3.1.0?! — сверить форк |

## Волна 2 — ГОТОВО (Mac-смоук зелёный, 2026-07-15), кроме qwt/mongoose/nanopb

| Легаси | Conan-рецепт | Версия к миграции | Deps / прим. |
|---|---|---|---|
| CURL | libcurl | 8.21.0 (= upstream) | openssl, zlib; LEGACY_NAME_MAP libcurl->curl |
| LIBXML2 | libxml2 | 2.13.8 | zlib |
| MBEDTLS | mbedtls | 3.6.6 | upstream 4.2.0 — мажор, потребители наверняка на 3.x |
| SSH2 | libssh2 | 1.11.1 (= upstream) | openssl, zlib |
| ZMQ | zeromq | 4.3.5 (= upstream) | map zeromq->zmq |
| MOSQUITTO | mosquitto | upstream 2.1.2; легаси 2.0.19 | openssl; CCI-версию уточнить |
| MODBUS | libmodbus | 3.1.12 | upstream 3.2.0 — CCI отстаёт |
| MONGOOSE | mongoose | upstream 7.22 | CCI-версию уточнить |
| NANOPB | nanopb | upstream 0.4.9.1 | protoc |
| NETSNMP | net-snmp | 5.9.4 | openssl; upstream 5.10 в pre |
| LIBPQ | libpq | 16.14 | openssl |
| XERCES_C | xerces-c | 3.3.0 (= upstream) | легаси был 3.2.3 |
| DBUS | dbus | 1.15.8 | → волна 3 (meson-тулчейн для оффлайна) |
| QWT | qwt | 6.2.0 (легаси-пин el_conf; НЕ 6.3.0) | ГОТОВ, TC зелёный 2026-07-22 (HELP [32]); Qt НЕ пакетируется — образ станка/Qt агента (QT5_ROOT_DIR), сборка CMake-графтом (qmake запрещён: commercial licheck); Linux x86_64 + win; ground-truth легаси — pending |

## Волна 3 — частично ГОТОВО (2026-07-16): libiec61850/mongoose/nanopb/soem

| Легаси | Что это | Версия | Путь |
|---|---|---|---|
| MONGOOSE | mongoose 7.x | нет в CCI | рецепт с нуля (1 .c/.h, несложно) |
| NANOPB | nanopb 0.4.9.1 | нет в CCI (config.yml 404) | рецепт с нуля |
| DBUS | dbus 1.15.8 | meson | ГОТОВ 2026-07-21, TC зелёный (после пина компилятора в i686-профиле, 5fc4976); HELP [29]; ground-truth сверка легаси-пакета — pending |
| SNAP7 | Siemens S7 comm (OSS) | 1.4.2 (sf) | ГОТОВ 2026-07-21, TC зелёный (HELP [30]); sf-архив .7z переупакован в src/; ground-truth легаси — pending |
| SOEM | EtherCAT master | upstream v2.0.0 | CCI soem есть? уточнить; рецепт мал |
| LIBMATIEC | IEC 61131-3 matiec | 0.1.20260512 (= beremiz/matiec@7949c0b) | ГОТОВ 2026-07-21, TC зелёный (HELP [31]); tool-пакет iec2c/iec2iec, flex/bison предзапечены; win OFF (решение 2026-07-21); ground-truth легаси — pending |
| IEC61850LIB | libiec61850 | 1.6.1 (CCI = upstream) | лицензия GPL/коммерч. — с лидом |
| QXORM, QWINDOWKIT | Qt-экосистема | qxorm 1.5.1, qwindowkit 1.5.0 (upstream latest; легаси-пинов нет) | ГОТОВЫ 2026-07-22 (Mac-смоук + deployer, HELP [33]/[34]); Qt по qwt-схеме; qxorm: лицензия GPL3/коммерч — подтвердить у лида; ground-truth легаси — pending |
| OPCUASDK, UASERVERCPP, UA_ANSIC | OPC UA стеки | — | проприетарные — отдельное решение |
| CODESYS2 | проприетарный | — | вне Conan-миграции? — лид |

## Волна 4 — найдено сверкой ПОЛНОГО дерева SURA2 (2026-07-22)

Бэклог был неполным: сверка всех фото-окон COMPONENTS/CMAKE (A-Z покрыт
перекрытиями, ABSL — первая строка, ZMQ — последняя) нашла пропущенные строки:

| Легаси | Что это | Путь |
|---|---|---|
| GFLAGS | Google gflags (third-party, есть в CCI) | ГОТОВ 2026-07-22 (2.3.0, Mac-смоук + deployer, HELP [35]) |
| GLOG | Google glog (third-party, есть в CCI) | ГОТОВ 2026-07-22 (0.7.1, deps gflags; with_unwind=False, HELP [35]) |
| IEC104 / IEC60870 / IEC61850 | IEC-блок РАЗРЕШЁН кадром 2026-07-22 (photos/2026-07-22): 4 строки IEC104/IEC60870/IEC61850/IEC61850LIB. Гипотеза: IEC60870 = lib60870 (MZ Automation, third-party, GPL/коммерч), IEC104 и IEC61850 — внутренние враперы (паттерн SNMP/NETSNMP) | раскрыть IEC104+IEC60870 в TC (номера билдов = версии) или Bitbucket i-диапазон; lib60870-лицензия — с лидом |
| OPC_UA | строка дерева; вероятно семья OPCUASDK/UASERVERCPP/UA_ANSIC (уже в бэклоге, проприетарные) | подтвердить принадлежность |

Остальные ~30 несовпадений диффа — внутренние Elara (CONFIG_XSD, GSD_PARSER,
LIB_LOADER, PROCESS_LAUNCHER, QT_GUI_SDK/QT_NETWORK_SDK/QT_SAMPLE/QTGTEST_MAIN,
IPC_FACTORIES_*, BUSLINK_ETHERCAT, SYSTEM_MONITOR, ELIGATED, ENUM_HELPERS,
FILE_FINDER, DUMMY_PROTOCOL, CHANNEL_TESTS, PLATFORM_CONFIG, GENBLCFG-IM1200,
продукты и DOTNET/NODEJS-ветки) — не мигрируются.

**Дыры покрытия фото (что дострелять при случае):**
- ~~COMPONENTS/EXTERNAL~~ РАЗРЕШЁН кадром 2026-07-22: единственный проект —
  **ELMATIEC** (EM900 PACKAGE / EM910 RELEASE, билды **#0.5.0**). Значит
  легаси-версия matiec = 0.5.0 (своя нумерация); наш matiec/0.1.20260512 при
  подтверждении пина потребителей маппится в deployer LEGACY_VERSION_MAP
  (прецедент absl 0.2.0). NB: в дереве и LIBMATIEC (CMAKE), и ELMATIEC
  (EXTERNAL). Остальные не раскрыты: DOTNETCORE(V3)/IMAGES/NODEJS/DOCUMENTATIONS.
- **SURA1 — отдельный top-level проект** (ARCSTATION/SURASCADA/PPUMETR4...);
  его COMPONENTS не раскрыт. Входит ли SURA1 в скоуп миграции — вопрос лиду.
- IEC-блок (3 строки между IEC104 и INELBUSHANDLER) — нет ни одного чёткого кадра.
- Bitbucket Repositories сфоткан только a..e; f..z не captured.
- Разбивка конфигов (Windows/Linux/ARM) снята только для CURL/GOOGLETEST/GRPC/EL_CONF.

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

6. **Сверка форка с upstream (обязательный шаг).** Каждый легаси third-party живёт
   отдельным Bitbucket-репо SURA2 (форк + nuget-обвязка) и может нести локальные
   патчи (прецедент: protobuf-форк расщеплял libprotoc -> libprotolib). Перед
   миграцией пакета: открыть его Bitbucket-репо, проверить коммиты поверх
   апстрим-исходников; патчи либо устарели (уже в новой версии), либо переносятся
   в <pkg>/patches/ через conandata.
