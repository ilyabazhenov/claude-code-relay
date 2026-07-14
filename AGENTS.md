# AGENTS.md — Relay

Инструкции для кодинг-агентов, работающих с этим репозиторием. Человекочитаемое
описание — в [README.md](README.md); здесь — то, что нужно агенту, чтобы менять код
не ломая архитектуру.

## Что это

**Relay** — нативное macOS-приложение (меню-бар), «диспетчерская» для сессий Claude
Code. Позволяет отвечать на запросы Клода (аппрувы опасных команд и текстовые
вопросы) прямо из нативного уведомления или из иконки в меню-баре, не открывая
терминал.

Поток данных:

```
Claude Code (внутри tmux)
   │  hooks: PreToolUse / Stop / Notification / SessionStart / SessionEnd
   ▼
hook-скрипты (bash+curl+python3)  ──POST──►  демон Relay (в .app, 127.0.0.1)
                                                │
                            ┌───────────────────┼─────────────────────┐
                            ▼                    ▼                     ▼
                      меню-бар (SwiftUI)   уведомления           tmux send-keys
                                            (Approve/Deny + поле)  (инъекция ответа)
```

## Стек и границы

- **Swift 6 + SwiftUI**, `MenuBarExtra`, таргет macOS 14+. Собирается как SwiftPM
  executable, затем скрипт заворачивает бинарь в `.app`-бандл.
- **Одна сторонняя зависимость — [Sparkle](https://sparkle-project.org)** (авто-апдейт,
  см. ниже). Всё остальное — только SDK: HTTP-сервер на `Network.framework` и т.д.
  Новые зависимости не добавляй без веской причины.
- **Хук-скрипты — только `bash`, `curl`, `python3`.** Не добавляй `jq` или
  brew-пакеты в хуки: они должны работать на чистой macOS.
- Строгая конкуренция Swift 6 включена. Классы, которые ловятся в `@Sendable`
  замыкания (напр. `HTTPServer`), помечены `@unchecked Sendable` и защищают своё
  состояние очередью/локом. Координаторы — `@MainActor`.

## Как собрать и прогнать

```bash
./scripts/build_app.sh debug      # сборка + бандл build/Relay.app (ad-hoc подпись)
./scripts/build_app.sh release
./scripts/make_dmg.sh             # release + build/Relay.dmg
./scripts/release.sh              # zip + EdDSA-подпись + regenerate appcast.xml
```

Тестового фреймворка нет — проверка через **фикстуры** (`fixtures/`) и HTTP-эндпоинты
демона (см. ниже). Реальная инъекция в tmux проверяется живой tmux-сессией.

## Карта модулей (`Sources/Relay/`)

| Модуль | Ответственность |
| --- | --- |
| `Server/HTTPServer.swift` | Loopback HTTP/1.1 сервер на `Network.framework`, async-хендлеры (нужны для блокирующего long-poll аппрувов). |
| `Server/Daemon.swift` | `@MainActor` владелец конфига + сервера. **Роутинг всех эндпоинтов здесь.** Проверка секрета. Проброс конфига в координаторы. Приём usage-обновлений на `POST /usage`. |
| `SessionStore/RateLimitStore.swift` | `@MainActor` хранилище снимка лимитов (5h / 7d): проценты + время сброса. Данные приходят из статуслайна через `POST /usage`; снимок **персистится** в `~/.claude/relay/usage.json` и восстанавливается при старте. Окно, чей `reset` уже прошёл, считается устаревшим и не показывается. |
| `Config/Config.swift` | Модель конфига + `ConfigStore` (чтение/запись `~/.claude/relay/config.json`, генерация порта и секрета). |
| `SessionStore/` | `Session` + `SessionState` (машина состояний), `SessionStore` (реестр в памяти), `HookEvent` (парсинг payload'а `/event`), `PendingApproval`. |
| `Approvals/` | `ApprovalCoordinator` (паркует хук на continuation до решения/таймаута), `DangerRules` (матч опасных команд). |
| `Notifications/NotificationManager.swift` | Обёртка `UNUserNotificationCenter`: категории, экшены (Approve/Deny/быстрые ответы/текстовое поле), делегат. |
| `Tmux/` | `TmuxInjector` (`tmux send-keys`), `ReplyCoordinator` (инъекция ответа + блокировки), `TranscriptReader` (fallback-парсинг вопроса), `TerminalFocuser` (фокус панели/терминала). |
| `Hooks/` | `HookScripts` (шаблоны хук-скриптов — **единый источник истины**), `HooksInstaller` (безопасный merge в `~/.claude/settings.json`). |
| `MenuUI/` | `MenuContentView` (список сессий, карточки, «Проверить обновления…»), `SettingsView` (окно настроек, секция «Обновления»). |
| `Support/Log.swift` | Логи в unified log + `~/.claude/relay/relay.log`. |
| `Support/UpdateController.swift` | Обёртка `SPUStandardUpdaterController`. Владелец — `AppDelegate`. Настройки Sparkle — в `Info.plist`, автопроверка хранится в `UserDefaults` самим Sparkle (в `config.json` **не дублируем**). |
| `main.swift` / `CLI.swift` | Точка входа; CLI `--install-hooks` / `--uninstall-hooks` до старта GUI. |

## Авто-апдейт (Sparkle)

- Обновления через **Sparkle**: демон Sparkle раз в сутки тянет подписанный
  `appcast.xml` (`SUFeedURL` в `Info.plist`) и показывает штатный алерт. Режим
  **notify, не silent** — `SUAutomaticallyUpdate=false`, ничего не ставится без клика.
- **ad-hoc + EdDSA.** Приложение не нотаризовано, поэтому единственный якорь доверия —
  EdDSA-подпись апдейта, сверяемая с `SUPublicEDKey`. Приватный ключ — в login-keychain
  релизной машины (`generate_keys`), публичный — в `Info.plist`. **Не коммить приватный
  ключ.**
- **Встраивание фреймворка.** Бандл собирается вручную, без Xcode-фазы Embed Frameworks:
  `build_app.sh` копирует `Sparkle.framework` в `Contents/Frameworks` и подписывает
  ad-hoc **строго изнутри наружу** (XPC-сервисы → `Updater.app`/`Autoupdate` → фреймворк →
  приложение). Executable несёт rpath `@executable_path/../Frameworks` (в `Package.swift`).
  Если тронешь порядок подписи или rpath — приложение упадёт на старте или Sparkle-хелперы
  не пройдут собственную проверку. Проверяй `codesign --verify --deep --strict`.
- **Версии.** `CFBundleShortVersionString` ← `./VERSION`; `CFBundleVersion` ← число
  коммитов git (монотонно, растёт с каждым коммитом) — по нему Sparkle сравнивает релизы.
- **Релиз:** bump `./VERSION` → commit → `scripts/release.sh` (собирает, зипует, подписывает,
  генерит `appcast.xml`; **ничего не публикует** — печатает шаги для `gh release` и коммита
  аппкаста).
- Только **arm64** (SwiftPM-бинарь под Apple Silicon) — для Intel нужен universal-бинарь.

## Машина состояний сессии

```
working ──Stop──────────▶ waitingText
working ──PreToolUse────▶ waitingApproval
waiting_* ──ответ дан──▶ working
любое ──SessionEnd─────▶ ended
```

**Инвариант:** инъекция текста через tmux разрешена только в состоянии `waiting_*`.
Инъекция в `working`-сессию сломает её — эта проверка в `ReplyCoordinator.submit`,
не удаляй её.

## HTTP-эндпоинты (все, кроме `/health`, требуют заголовок `X-Relay-Secret`)

| Эндпоинт | Назначение |
| --- | --- |
| `GET /health` | Проверка живости → `ok` (без секрета). |
| `POST /event` | Жизненный цикл (SessionStart/End, Stop, Notification). |
| `POST /approve` | Блокирующий аппрув PreToolUse; возвращает готовый JSON для хука. |
| `POST /reply` | Инъекция текстового ответа в ждущую сессию. |
| `GET /sessions`, `GET /pending`, `POST /resolve` | Отладочные (снимок реестра, список аппрувов, ручное разрешение). |
| `POST /usage` | Приём usage-обновления от статуслайн-скрипта: `{five_hour_percent, five_hour_reset_epoch, seven_day_percent, seven_day_reset_epoch}` (все поля опциональны, окна мёржатся). |
| `GET /usage` | Отладочный: последний снимок 5h/weekly-использования (проценты + время сброса). |

## Схема хуков Claude Code (сверено с офиц. документацией)

Механика хуков меняется. Актуальная модель, на которой построен Relay, — в разделе
README «Claude Code hook integration». Ключевое:

- Конфиг в `~/.claude/settings.json` → `hooks` → по событию и `matcher`, элементы
  `{ "type":"command", "command", "timeout" }`.
- stdin общий: `session_id`, `transcript_path`, `cwd`, `hook_event_name`. Плюс:
  PreToolUse → `tool_name`, `tool_input`; Stop → `last_assistant_message`;
  Notification → `message`; SessionStart → `source`; SessionEnd → `reason`.
- Внутри tmux хук наследует `TMUX_PANE` — по нему привязываем сессию к панели.
- Вывод PreToolUse: `{"hookSpecificOutput":{"hookEventName":"PreToolUse",
  "permissionDecision":"allow"|"deny"|"ask", "permissionDecisionReason":"…"}}`.
- Коды возврата: `0` — stdout применяется; `2` — жёсткий блок (stderr → Клоду);
  **любой другой код / пустой вывод — не блокирует** (это путь **fail-open**).

**Если правишь интеграцию хуков — сначала сверься с актуальной документацией**
(она эволюционирует), потом меняй `HookScripts.swift` и `HooksInstaller.swift`.

## Правила, которые нельзя нарушать

1. **Fail-open.** Если демон недоступен или аппрув истёк по таймауту — хук печатает
   пусто и выходит `0`. Relay никогда не должен «окирпичить» Claude Code.
2. **Loopback-only + секрет.** Сервер слушает только `127.0.0.1`. Каждый запрос,
   кроме `/health`, проверяет `X-Relay-Secret`. Не добавляй эндпоинтов без проверки.
3. **Установщик не затирает пользовательские хуки.** `HooksInstaller` делает
   бэкап и мёржит только свои записи (опознаёт их по пути `~/.claude/relay/`).
   Деинсталл удаляет только своё.
4. **Таймаут аппрува < curl `--max-time` в хуке** — решение о таймауте принимает
   демон (сейчас 270с против 300с в curl), не curl.
5. **Хук-скрипты дублируются** в `HookScripts.swift` (истина, ставится в
   `~/.claude/relay/`) и `hooks/` (справочные копии). Меняешь один — синхронизируй.
   Сюда же входит `statusline.sh`.
6. **tmux-инъекция только в `waiting_*`** (см. инвариант выше).
7. **Лимиты берутся из статуслайна Claude Code, не из прокси.** Инсталлер ставит
   `statusLine`-команду в `~/.claude/settings.json` (мёрж с бэкапом, **не** затирает
   пользовательский статуслайн — если он уже свой, Relay его не трогает и usage не
   течёт). Скрипт читает JSON статуслайна (`rate_limits.five_hour` / `.seven_day` —
   только у Claude.ai Pro/Max после первого ответа API), шлёт числа на `POST /usage`
   и печатает компактную строку. Никакого перехвата трафика/кредов. Схема полей
   статуслайна — офиц. документация Claude Code (`used_percentage`, `resets_at`).
8. **Снимок лимитов персистится.** `RateLimitStore` пишет `~/.claude/relay/usage.json`
   при каждом апдейте и грузит его при старте, чтобы менюбар не пустел между сессиями.
   Окна мёржатся (Claude Code может слать 5h и 7d независимо); окно с прошедшим `reset`
   не показывается как устаревшее.

## Быстрая проверка (без реальной долгой сессии)

```bash
./scripts/build_app.sh debug && open build/Relay.app
build/Relay.app/Contents/MacOS/Relay --install-hooks
PORT=$(python3 -c "import json,os;print(json.load(open(os.path.expanduser('~/.claude/relay/config.json')))['port'])")
SECRET=$(python3 -c "import json,os;print(json.load(open(os.path.expanduser('~/.claude/relay/config.json')))['secret'])")

fixtures/emit.sh session_start_alpha.json %1
fixtures/emit.sh stop_alpha.json %1
curl -s -H "X-Relay-Secret: $SECRET" http://127.0.0.1:$PORT/sessions | python3 -m json.tool

# по завершении — убрать тестовые хуки:
build/Relay.app/Contents/MacOS/Relay --uninstall-hooks
```

`fixtures/emit.sh <fixture.json> [TMUX_PANE]` подаёт JSON на нужный установленный
хук-скрипт (`event.sh` или `pretooluse.sh`) — так тестируется весь путь до демона.

## Требования окружения

- macOS 14+, Swift 6 / Xcode CLT.
- **tmux** (`brew install tmux`) — для инъекции ответов и обёртки `cc`.
- Разрешение на уведомления для Relay (иначе экшены аппрувов/ответов не работают).
