# Пошаговая инструкция по развёртыванию

---

## ЭТАП 1: Поднять Conan Server

### Что это и зачем
Conan Server — это хранилище для собранных C++ пакетов. TeamCity будет
собирать пакеты и загружать сюда. Проекты-потребители будут скачивать
готовые пакеты отсюда, а не пересобирать каждый раз.

### Что нужно
- Любой Linux-сервер с Docker (один из ba-deb12-*, или отдельная машина)
- Docker и docker-compose установлены
- Сетевая доступность из TeamCity-агентов

### Пошагово

**1.1. Выбрать сервер**

Подойдёт любая машина Linux с Docker. Можно использовать:
- Один из существующих серверов
- Или поднять отдельную VM

Зайти на сервер по SSH:
```bash
ssh user@<IP_СЕРВЕРА>
```

**1.2. Проверить, что Docker установлен**
```bash
docker --version
docker-compose --version
```

Если не установлен:
```bash
# Debian 12
sudo apt update
sudo apt install -y docker.io docker-compose
sudo systemctl enable docker
sudo systemctl start docker
sudo usermod -aG docker $USER
# Перелогиниться, чтобы группа применилась
```

**1.3. Создать директорию для Conan Server**
```bash
sudo mkdir -p /opt/conan-server
cd /opt/conan-server
```

**1.4. Создать файл server.conf**
```bash
sudo nano /opt/conan-server/server.conf
```

Вставить содержимое (ЗАМЕНИТЬ пароли!):
```ini
[server]
jwt_secret=elara_conan_secret_2024_ЗАМЕНИТЬ_НА_СЛУЧАЙНУЮ_СТРОКУ
jwt_expire_minutes=120
host_name=0.0.0.0
port=9300
ssl_enabled=False
public_port=9300

[write_permissions]
*/*@*/*: builder

[read_permissions]
*/*@*/*: *

[users]
builder=Str0ngP@ssw0rd_ЗАМЕНИТЬ
reader=Re@derP@ss_ЗАМЕНИТЬ
```

Сохранить: `Ctrl+O`, `Enter`, `Ctrl+X`

**1.5. Создать файл docker-compose.yml**
```bash
sudo nano /opt/conan-server/docker-compose.yml
```

Вставить:
```yaml
version: '3.8'

services:
  conan-server:
    image: conanio/conan_server:latest
    container_name: conan-server
    ports:
      - "9300:9300"
    volumes:
      - conan-data:/root/.conan_server/data
      - ./server.conf:/root/.conan_server/server.conf:ro
    restart: unless-stopped

volumes:
  conan-data:
    driver: local
```

Сохранить: `Ctrl+O`, `Enter`, `Ctrl+X`

**1.6. Запустить**
```bash
cd /opt/conan-server
sudo docker-compose up -d
```

**1.7. Проверить, что работает**
```bash
# Статус контейнера
sudo docker ps | grep conan

# Должно быть:
# conan-server   ...   Up   0.0.0.0:9300->9300/tcp

# Проверить доступность
curl http://localhost:9300/v1/ping

# Должно ответить что-то (не ошибку)
```

**1.8. Проверить с другой машины**
```bash
# С любого TeamCity-агента или своей машины
curl http://<IP_СЕРВЕРА>:9300/v1/ping
```

Если не отвечает — проверить firewall:
```bash
# На сервере с Conan
sudo ufw allow 9300/tcp
# или
sudo iptables -A INPUT -p tcp --dport 9300 -j ACCEPT
```

**1.9. (Опционально) Настроить DNS**

Попросить админа добавить DNS-запись:
```
conan.elara.local → <IP_СЕРВЕРА>
```

Если нет возможности — просто использовать IP напрямую. Или добавить
в /etc/hosts на каждом агенте:
```bash
echo "<IP_СЕРВЕРА> conan.elara.local" | sudo tee -a /etc/hosts
```

### Проверка: этап 1 пройден, если
- [ ] `curl http://<IP>:9300/v1/ping` отвечает с любого агента
- [ ] Вы знаете IP адрес сервера и пароль builder

---

## ЭТАП 2: Создать репозиторий в Bitbucket

### Что нужно
- Доступ к bitbucket.inc.elara.local с правами создания репозитория

### Пошагово

**2.1. Открыть Bitbucket в браузере**
```
http://bitbucket.inc.elara.local
```

**2.2. Создать репозиторий**

1. Нажать **"Создать"** (или **"Create repository"**) в верхнем меню
2. Заполнить:
   - **Проект**: выбрать существующий (Infrastructure / DEVOPS / или тот же, где SURA2)
   - **Имя репозитория**: `conan-recipes`
   - **Описание**: `IN-353: Conan рецепты для сборки third party пакетов без модификации`
   - **Default branch**: `master`
3. Нажать **"Создать репозиторий"**

**2.3. Скопировать URL репозитория**

После создания Bitbucket покажет URL. Скопировать SSH URL, он будет вида:
```
ssh://git@bitbucket.inc.elara.local:7999/<PROJECT_KEY>/conan-recipes.git
```
или
```
ssh://git@bitbucket.inc.elara.local/<PROJECT_KEY>/conan-recipes.git
```

Запомнить этот URL — он понадобится дальше.

**2.4. Залить код с вашей машины**

Открыть терминал на вашем компьютере (где мы создавали файлы):

```bash
cd /Users/zero/Documents/elara_work/conan-recipes

# Инициализировать git
git init

# Добавить все файлы
git add .

# Проверить, что добавилось
git status

# Должен показать:
#   new file: CONCEPT.md
#   new file: DEPLOY.md
#   new file: STEP_BY_STEP.md
#   new file: docker-compose.yml
#   new file: server.conf
#   new file: gtest/conanfile.py
#   new file: profiles/linux-gcc
#   new file: profiles/linux-gcc-debug
#   new file: profiles/windows-msvc
#   new file: profiles/windows-msvc-debug
#   new file: teamcity/build-recipe.sh
#   new file: teamcity/build-all.sh
#   new file: example/...

# Создать коммит
git commit -m "IN-353: Conan recipes for building third party packages without modification"

# Добавить remote (ВСТАВИТЬ ВАШ URL ИЗ ШАГА 2.3!)
git remote add origin ssh://git@bitbucket.inc.elara.local:7999/<PROJECT_KEY>/conan-recipes.git

# Залить
git push -u origin master
```

**2.5. Проверить в Bitbucket**

Обновить страницу репозитория в браузере — должны появиться все файлы.

### Проверка: этап 2 пройден, если
- [ ] Репозиторий создан в Bitbucket
- [ ] Все файлы видны в веб-интерфейсе
- [ ] Вы знаете SSH URL репозитория

---

## ЭТАП 3: Подготовить TeamCity-агент

### Что нужно
- SSH-доступ к агенту из SANDBOX pool (ba-deb-prb)
- Или к любому Linux-агенту для тестирования

### Пошагово

**3.1. Зайти на агент по SSH**
```bash
ssh user@ba-deb-prb
# или по IP, если DNS не настроен
ssh user@<IP_АГЕНТА>
```

**3.2. Проверить Python**
```bash
python3 --version
# Нужен Python 3.6+
# Если нет:
sudo apt update && sudo apt install -y python3 python3-pip
```

**3.3. Установить Conan**
```bash
pip3 install conan
```

Проверить:
```bash
conan --version
# Должно показать: Conan version 2.x.x
```

Если `conan` не найден после установки:
```bash
# Добавить в PATH
export PATH="$HOME/.local/bin:$PATH"
# И добавить в ~/.bashrc, чтобы сохранилось
echo 'export PATH="$HOME/.local/bin:$PATH"' >> ~/.bashrc
```

**3.4. Первичная настройка Conan**
```bash
conan profile detect
```

Проверить созданный профиль:
```bash
conan profile show
```

Должно показать что-то вроде:
```
[settings]
arch=x86_64
build_type=Release
compiler=gcc
compiler.cppstd=gnu17
compiler.libcxx=libstdc++11
compiler.version=12
os=Linux
```

**3.5. Проверить CMake и компилятор**
```bash
cmake --version
# Нужен >= 3.15

gcc --version
# Или g++ --version

# Если CMake нет:
sudo apt install -y cmake

# Если gcc нет:
sudo apt install -y build-essential
```

**3.6. Добавить Conan Server как remote**
```bash
# ЗАМЕНИТЬ <IP_СЕРВЕРА> на реальный IP из Этапа 1!
conan remote add elara http://<IP_СЕРВЕРА>:9300

# Или если настроен DNS:
conan remote add elara http://conan.elara.local:9300
```

Проверить:
```bash
conan remote list

# Должен показать:
# conancenter: https://center.conan.io [Verify SSL: True, Enabled: True]
# elara: http://<IP>:9300 [Verify SSL: True, Enabled: True]
```

**3.7. Авторизоваться**
```bash
# ЗАМЕНИТЬ пароль на тот, что задали в server.conf (пользователь builder)!
conan remote login elara builder -p "Str0ngP@ssw0rd_ЗАМЕНИТЬ"
```

Должно ответить:
```
Changed user of remote 'elara' from 'None' (anonymous) to 'builder'
```

**3.8. Проверить связь с Conan Server**
```bash
conan search --remote=elara "*"
# Пока пустой — это нормально, пакетов ещё нет
# Главное — нет ошибок подключения
```

### Проверка: этап 3 пройден, если
- [ ] `conan --version` показывает 2.x
- [ ] `cmake --version` >= 3.15
- [ ] `gcc --version` работает
- [ ] `conan remote list` показывает elara
- [ ] `conan search --remote=elara "*"` не выдаёт ошибку подключения

---

## ЭТАП 4: Тестовая сборка gtest (вручную на агенте)

### Зачем
Прежде чем настраивать TeamCity — убедиться, что всё работает вручную
на агенте. Если здесь что-то сломается — проще отладить.

### Пошагово

**4.1. Склонировать репо (на том же агенте ba-deb-prb)**
```bash
cd ~
git clone ssh://git@bitbucket.inc.elara.local:7999/<PROJECT_KEY>/conan-recipes.git
cd conan-recipes
```

Проверить, что файлы на месте:
```bash
ls -la
# Должно показать: gtest/  profiles/  teamcity/  example/  ...

ls gtest/
# Должно показать: conanfile.py
```

**4.2. Собрать gtest из рецепта**
```bash
conan create gtest/ --profile=profiles/linux-gcc --build=missing
```

Что произойдёт:
1. Conan скачает исходники gtest 1.14.0 с GitHub
2. Сконфигурирует CMake (без модификации исходников!)
3. Соберёт
4. Упакует в локальный кэш Conan

Сборка займёт 1-2 минуты. В конце должно быть:
```
gtest/1.14.0: Package ... created
```

**ЕСЛИ ОШИБКА "нет доступа к GitHub":**

Значит агент не имеет выхода в интернет. Тогда нужно скачать исходники
вручную и положить рядом. Измените `gtest/conanfile.py` — замените метод source():

```python
def source(self):
    # Вариант: взять из локального пути или внутреннего сервера
    get(self, "http://<ваш_внутренний_сервер>/mirrors/googletest-1.14.0.tar.gz",
        strip_root=True)
```

Или скачать архив заранее и поместить в нужное место.

**4.3. Проверить, что пакет в локальном кэше**
```bash
conan list "gtest/1.14.0:*"
```

Должно показать пакет с хэшем.

**4.4. Загрузить в Conan Server**
```bash
conan upload "gtest/1.14.0" --remote=elara --confirm
```

Должно показать:
```
Uploading gtest/1.14.0 to remote 'elara'
```

**4.5. Проверить, что пакет в Conan Server**
```bash
conan search "gtest/1.14.0" --remote=elara
```

Должен найти пакет.

**4.6. Собрать пример-потребитель**
```bash
cd ~/conan-recipes/example

# Установить зависимости
conan install . --output-folder=build --build=missing --profile=../profiles/linux-gcc

# Собрать
cmake -B build -DCMAKE_TOOLCHAIN_FILE=build/conan_toolchain.cmake -DCMAKE_BUILD_TYPE=Release
cmake --build build

# Запустить тесты
cd build && ctest --output-on-failure
```

Должно показать:
```
[==========] Running 6 tests from 2 test suites.
...
[  PASSED  ] 6 tests.
```

### Проверка: этап 4 пройден, если
- [ ] `conan create gtest/` завершилось без ошибок
- [ ] `conan upload` загрузил пакет в Conan Server
- [ ] Пример-потребитель собрался
- [ ] Тесты прошли (6 tests PASSED)

---

## ЭТАП 5: Настроить TeamCity

### Что нужно
- Доступ к TeamCity с правами администратора проекта
- Этапы 1-4 пройдены успешно

### Пошагово

**5.1. Открыть TeamCity**
```
http://teamcity.inc.elara.local
```

**5.2. Создать подпроект**

1. Перейти в **SURA2 → COMPONENTS** (или куда хотите поместить)
2. Нажать **"Edit Project Settings"** (справа вверху, или через Administration)
3. В левом меню нажать **"Subprojects"**
4. Нажать **"Create subproject"**
5. Заполнить:
   - **Name**: `CONAN`
   - **Project ID**: `CONAN` (или автоматически)
   - **Description**: `IN-353: Conan packages for third party libraries`
6. Нажать **"Create"**

**5.3. Создать VCS Root**

1. Внутри проекта CONAN → левое меню → **"VCS Roots"**
2. Нажать **"Create VCS root"**
3. Заполнить:
   - **Type**: Git
   - **VCS root name**: `conan-recipes`
   - **Fetch URL**: `ssh://git@bitbucket.inc.elara.local:7999/<PROJECT_KEY>/conan-recipes.git`
     (тот URL из Этапа 2!)
   - **Default branch**: `refs/heads/master`
   - **Authentication method**: `Uploaded Key` или `Default Private Key`
     (использовать тот же SSH-ключ, что и для других VCS Roots)
4. Нажать **"Test Connection"** — должно показать "Connection successful"
5. Нажать **"Create"**

**5.4. Создать Build Configuration: CN100 BUILD gtest Linux**

1. В проекте CONAN → **"Create build configuration"**
2. Заполнить:
   - **Name**: `CN100 BUILD gtest Linux`
   - **Build configuration ID**: `CN100`
3. Нажать **"Create"**

**5.5. Привязать VCS Root**

1. В новой конфигурации → левое меню → **"Version Control Settings"**
2. Нажать **"Attach VCS root"**
3. Выбрать `conan-recipes` (созданный в 5.3)
4. **Checkout rules**: оставить пустым
5. Нажать **"Attach"**

**5.6. Добавить Parameters**

1. Левое меню → **"Parameters"**
2. Нажать **"Add new parameter"** для каждого:

| Name | Kind | Value |
|------|------|-------|
| `package.name` | Configuration parameter | `gtest` |
| `package.version` | Configuration parameter | `1.14.0` |
| `conan.profile` | Configuration parameter | `profiles/linux-gcc` |
| `conan.remote` | Configuration parameter | `elara` |
| `env.CONAN_PASSWORD` | Environment variable | `<пароль builder>` |

Для CONAN_PASSWORD:
- Нажать **"Edit"** рядом с Spec
- Поставить галку **"Display: Hidden"** и **"Type: Password"**

**5.7. Добавить Build Step**

1. Левое меню → **"Build Steps"**
2. Нажать **"Add build step"**
3. **Runner type**: `Command Line`
4. **Step name**: `Build and upload Conan package`
5. **Run**: `Custom script`
6. **Custom script**:

```bash
#!/bin/bash
set -euo pipefail

echo "##teamcity[progressMessage 'Building %package.name% %package.version%']"

# Авторизоваться в Conan remote
conan remote login %conan.remote% builder -p "$CONAN_PASSWORD"

# Собрать пакет из оригинальных исходников (без модификации!)
conan create %package.name%/ --profile=%conan.profile% --build=missing

# Загрузить в Conan Server
conan upload "%package.name%/%package.version%" --remote=%conan.remote% --confirm

echo "##teamcity[buildStatus text='%package.name% %package.version% uploaded']"
```

7. Нажать **"Save"**

**5.8. Настроить Agent Requirements**

1. Левое меню → **"Agent Requirements"**
2. Нажать **"Add requirement"**
3. Заполнить:
   - **Parameter name**: `teamcity.agent.jvm.os.name`
   - **Condition**: `contains`
   - **Value**: `Linux`
4. Нажать **"Save"**

Опционально — ограничить пулом SANDBOX для тестирования:
- **Parameter name**: `system.agent.pool`
- **Condition**: `equals`
- **Value**: `SANDBOX`

**5.9. (Опционально) Добавить Trigger**

1. Левое меню → **"Triggers"**
2. Нажать **"Add new trigger"**
3. Выбрать **"VCS Trigger"**
4. **Branch filter**: оставить по умолчанию
5. Нажать **"Save"**

Теперь сборка будет запускаться автоматически при push в master.

**5.10. Запустить тестовую сборку**

1. Нажать кнопку **"Run..."** в правом верхнем углу
2. Можно оставить параметры по умолчанию
3. Нажать **"Run Build"**
4. Перейти во вкладку **"Build Log"** чтобы следить за выполнением

### Проверка: этап 5 пройден, если
- [ ] Сборка завершилась с зелёным статусом "Success"
- [ ] В Build Log видно "uploaded"
- [ ] На агенте: `conan search "gtest/1.14.0" --remote=elara` находит пакет

---

## ЭТАП 6: Добавить Windows сборку (после успеха Linux)

### Пошагово

**6.1. Подготовить Windows-агент**

Зайти на Windows-агент (например, ba-win-01) через RDP или SSH.

В PowerShell (от администратора):
```powershell
pip install conan
conan profile detect
conan remote add elara http://<IP_CONAN_SERVER>:9300
conan remote login elara builder -p "<пароль>"
```

**6.2. Создать Build Configuration в TeamCity**

1. В проекте CONAN → **"Create build configuration"**
2. **Name**: `CN101 BUILD gtest Windows`
3. Привязать тот же VCS Root `conan-recipes`
4. Parameters — те же, но:
   - `conan.profile` = `profiles/windows-msvc`
5. Build Step:

```bat
conan remote login %conan.remote% builder -p "%CONAN_PASSWORD%"
conan create %package.name%/ --profile=%conan.profile% --build=missing
conan upload "%package.name%/%package.version%" --remote=%conan.remote% --confirm
```

6. Agent Requirement: `teamcity.agent.jvm.os.name` contains `Windows`

---

## ЭТАП 7: Добавить новый пакет (по аналогии)

Когда gtest работает — добавление нового пакета (например, curl):

**7.1. Создать рецепт**
```bash
mkdir conan-recipes/curl
# Написать conanfile.py по аналогии с gtest
```

**7.2. Залить в Bitbucket**
```bash
git add curl/
git commit -m "IN-353: Add curl conan recipe"
git push
```

**7.3. В TeamCity**
- Создать CN200 BUILD curl Linux (копировать CN100, поменять package.name=curl)
- Run

---

## Решение проблем

### "conan: command not found" на агенте
```bash
export PATH="$HOME/.local/bin:$PATH"
# Добавить в ~/.bashrc
```

### "Connection refused" при обращении к Conan Server
```bash
# На сервере проверить, что контейнер запущен
sudo docker ps | grep conan

# Если не запущен
cd /opt/conan-server && sudo docker-compose up -d

# Проверить firewall
sudo ufw status
sudo iptables -L -n | grep 9300
```

### "ERROR: gtest/1.14.0: Error in source()" — нет доступа к GitHub
Агент не имеет выхода в интернет. Решения:
1. Открыть доступ к github.com
2. Или скачать архив вручную на машину с интернетом и
   выложить на внутренний HTTP-сервер
3. Или поменять URL в conanfile.py на внутренний mirror

### "Authentication required" при upload
```bash
conan remote login elara builder -p "<пароль>"
```

### Сборка падает на cmake
```bash
# Проверить, что cmake и gcc установлены
cmake --version
gcc --version

# Если нет
sudo apt install -y cmake build-essential
```

### TeamCity: "No compatible agents"
Проверить Agent Requirements в Build Configuration.
Убедиться, что хотя бы один агент удовлетворяет условиям.
