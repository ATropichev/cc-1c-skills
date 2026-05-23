# Конфигурация проекта (.v8-project.json)

Файл `.v8-project.json` — локальный конфиг проекта для всех навыков Claude Code. Хранит пути к платформе 1С, список баз данных, структуру исходников и настройки инструментов (Apache, ffmpeg, TTS).

Размещается в корне проекта (рядом с `.git/`). Создаётся навыком `/db-list init`, `/db-list add` или вручную.

> **Безопасность**: `.v8-project.json` можно хранить локально и не коммитить. Если команде нужен повторяемый старт после clone, добавь в репозиторий `.v8-project.json.example` без секретов. Пароли баз данных, API-ключи TTS и локальные машинные пути лучше хранить в `.v8-project.local.json`, добавленном в `.gitignore`.

## Инициализация после clone

Если проект скачан из Git и `.v8-project.json` отсутствует, запусти
`/db-list init`.

Алгоритм инициализации:

1. Если в корне проекта есть `.v8-project.json.example`, он используется как
   основа локального `.v8-project.json`.
2. Если шаблона нет, Claude определяет структуру по типовым каталогам:
   `cfsrc`, `src`, `extensions`, `ext`, `reports`, `processing`,
   `processors`.
3. Claude определяет установленную платформу 1С или спрашивает путь к каталогу
   `bin`.
4. Claude спрашивает параметры базы: `id`, `name`, `type`, `path` или
   `server/ref`, `user`.
5. Пароль и машинные переопределения записываются в
   `.v8-project.local.json`, если пользователь хочет сохранить их локально.
6. `.v8-project.local.json` и `*.local.json` должны быть добавлены в
   `.gitignore`.

Так проект может не хранить рабочий `.v8-project.json` в репозитории, но всё
равно иметь версионируемый шаблон структуры для новых разработчиков.

## Шаблон `.v8-project.json.example`

Шаблон можно хранить в Git. В него кладут только общие сведения: структуру
исходников, пример базы, алиасы, привязки к веткам. Секреты и локальные пути
не указываются.

```json
{
  "configSrc": "cfsrc",
  "extensions": "extensions",
  "reports": "reports",
  "processing": "processing",
  "databases": [
    {
      "id": "dev",
      "name": "Разработка",
      "type": "server",
      "server": "localhost",
      "ref": "MyApp_Dev",
      "user": "",
      "aliases": ["dev", "разработка"],
      "branches": ["main", "develop", "feature/*"]
    }
  ],
  "default": "dev"
}
```

## Полная схема

```jsonc
{
  // === Платформа ===
  "v8path": "C:\\Program Files\\1cv8\\8.3.25.1257\\bin",

  // === Структура проекта ===
  "configSrc": "cfsrc",
  "extensions": "extensions",
  "reports": "reports",
  "processing": "processing",

  // === Базы данных ===
  "databases": [
    {
      "id": "dev",                          // уникальный идентификатор
      "name": "Разработка",                 // отображаемое имя
      "type": "file",                       // "file" или "server"
      "path": "C:\\Bases\\MyApp_Dev",       // каталог (для file)
      "user": "Admin",                      // пользователь 1С
      "password": "",                       // пароль
      "aliases": ["dev", "разработка"],     // альтернативные имена
      "branches": ["dev", "feature/*"],     // привязка к Git-веткам
      "configSrc": "cfsrc",                 // переопределение каталога конфигурации
      "webUrl": "http://localhost:8081/dev"  // URL веб-клиента (для /web-test)
    },
    {
      "id": "test",
      "name": "Тестовая",
      "type": "server",                     // серверная база
      "server": "srv01",                    // адрес сервера 1С
      "ref": "MyApp_Test",                  // имя базы на сервере
      "user": "Admin",
      "password": "",
      "aliases": ["test", "тест"]
    }
  ],
  "default": "dev",

  // === Инструменты ===
  "webPath": "C:\\tools\\apache24",                  // каталог Apache
  "ffmpegPath": "C:\\tools\\ffmpeg\\bin\\ffmpeg.exe", // путь к ffmpeg
  "tts": {                                            // настройки озвучки
    "provider": "edge",
    "voice": "ru-RU-DmitryNeural"
  }
}
```

## Локальные переопределения `.v8-project.local.json`

Файл `.v8-project.local.json` размещается рядом с `.v8-project.json` и
применяется поверх него. Он нужен для значений, которые отличаются у каждого
разработчика или не должны попадать в git: пароли, локальные пользователи,
пути к платформе, Apache, ffmpeg, API-ключи TTS.

Минимальный пример:

```json
{
  "databases": {
    "dev": {
      "user": "Admin",
      "password": "secret"
    }
  }
}
```

Полный пример:

```json
{
  "v8path": "C:\\Program Files\\1cv8\\8.3.27.2130\\bin",
  "webPath": "C:\\tools\\apache24",
  "ffmpegPath": "C:\\tools\\ffmpeg\\bin\\ffmpeg.exe",
  "tts": {
    "provider": "openai",
    "apiKey": "secret"
  },
  "databases": {
    "dev": {
      "user": "Admin",
      "password": "secret",
      "webUrl": "http://localhost:8081/dev"
    }
  }
}
```

Правила применения local-файла:

- корневые поля local-файла переопределяют одноимённые поля
  `.v8-project.json`;
- `databases` может быть объектом `{ "id": { ...overrides } }` или массивом;
- записи баз сопоставляются по `id`;
- local-файл не должен создавать новую базу без основной записи в
  `.v8-project.json`;
- при выводе конфигурации пароль не показывается целиком.

Рекомендуемый `.gitignore`:

```gitignore
.v8-project.local.json
*.local.json
```

## Корневые поля

| Поле | Тип | Обяз. | По умолчанию | Описание | Кто заполняет |
|------|-----|:-----:|-------------|----------|---------------|
| `v8path` | string | нет | автоопределение | Путь к каталогу `bin` платформы 1С | `/db-list init` или руками |
| `databases` | array | да | — | Список баз данных | `/db-list add` |
| `default` | string | нет | — | `id` базы по умолчанию | `/db-list` |
| `configSrc` | string | нет | — | Каталог XML-выгрузки конфигурации по умолчанию | `/db-list init` или руками |
| `extensions` | string | нет | — | Каталог исходников расширений | `/db-list init` или руками |
| `reports` | string | нет | — | Каталог исходников внешних отчётов | `/db-list init` или руками |
| `processing` | string | нет | — | Каталог исходников внешних обработок | `/db-list init` или руками |
| `webPath` | string | нет | `tools/apache24` | Каталог Apache HTTP Server | Руками |
| `ffmpegPath` | string | нет | `tools/ffmpeg/bin/ffmpeg.exe` | Путь к ffmpeg | Руками |
| `tts` | object | нет | Edge TTS, DmitryNeural | Настройки озвучки видео | Руками |

## Базы данных (`databases[]`)

| Поле | Тип | Обяз. | Описание | Кто заполняет |
|------|-----|:-----:|----------|---------------|
| `id` | string | да | Уникальный идентификатор | `/db-list add` |
| `name` | string | да | Отображаемое имя | `/db-list add` |
| `type` | `"file"` / `"server"` | да | Тип подключения | `/db-list add` |
| `path` | string | для file | Каталог файловой базы | `/db-list add` |
| `server` | string | для server | Адрес сервера 1С | `/db-list add` |
| `ref` | string | для server | Имя базы на сервере | `/db-list add` |
| `user` | string | нет | Пользователь 1С | `/db-list add` или руками |
| `password` | string | нет | Пароль; для секретов предпочитай `.v8-project.local.json` | `.v8-project.local.json` |
| `aliases` | string[] | нет | Альтернативные имена для обращения к базе | `/db-list add` или руками |
| `branches` | string[] | нет | Git-ветки или glob-паттерны (`release/*`, `feature/*`) | Руками |
| `configSrc` | string | нет | Каталог XML-выгрузки конфигурации для конкретной базы; если не задан, используется корневой `configSrc` | Руками |
| `webUrl` | string | нет | URL веб-клиента для `/web-test` | Руками |

### Разрешение базы

Все навыки `/db-*`, `/epf-build`, `/epf-dump`, `/erf-build`, `/erf-dump`, `/web-publish` используют единый алгоритм. Сначала читается `.v8-project.json`, затем поверх него применяется `.v8-project.local.json`, если он существует:

1. Если пользователь указал **параметры подключения** (путь, сервер) — используются напрямую
2. Если указал **базу по имени** — поиск: `id` → `aliases` (с учётом морфологии) → `name` (нечёткое)
3. Если **не указал** — сопоставление текущей ветки Git с `branches` (точно или по glob-паттерну)
4. Fallback на `default`
5. Если не найдено — Claude спросит пользователя
6. Если база не зарегистрирована — Claude предложит `/db-list add`

## Настройки инструментов

### `webPath` — Apache HTTP Server

Путь к каталогу Apache. Используется навыками `/web-publish`, `/web-info`, `/web-stop`, `/web-unpublish`.

Если не задан — ищется в `tools/apache24` от корня проекта. При первом вызове `/web-publish` Apache скачивается автоматически.

Подробнее — в [гайде по веб-публикации](web-guide.md).

### `ffmpegPath` — ffmpeg

Путь к исполняемому файлу ffmpeg. Используется навыком `/web-test` для записи видео.

Если не задан — ищется по порядку:
1. `tools/ffmpeg/bin/ffmpeg.exe` (от корня проекта)
2. `ffmpeg` в системном PATH

Подробнее — в [гайде по записи видео](web-test-recording-guide.md).

### `tts` — озвучка видеоинструкций

| Поле | Тип | По умолчанию | Описание |
|------|-----|-------------|----------|
| `provider` | string | `"edge"` | Провайдер: `"edge"`, `"elevenlabs"`, `"openai"` |
| `voice` | string | `"ru-RU-DmitryNeural"` | Голос (имя или ID в зависимости от провайдера) |
| `apiKey` | string | — | API-ключ (для elevenlabs, openai) |
| `apiUrl` | string | — | URL сервиса (для openai-совместимых) |
| `model` | string | — | Модель (для openai) |

Подробнее о выборе провайдера и голосов — в [гайде по записи видео](web-test-recording-guide.md#доступные-голоса-и-провайдеры).

### `webUrl` — URL веб-клиента (per-database)

URL для открытия базы в браузере через `/web-test`. Задаётся в записи конкретной базы.

Если не задан — `/web-test` берёт URL из активной веб-публикации (`/web-publish`).

Полезно, если веб-клиент доступен по нестандартному адресу (другой порт, внешний сервер, reverse proxy).

## Минимальный пример

```json
{
  "v8path": "C:\\Program Files\\1cv8\\8.3.25.1257\\bin",
  "configSrc": "cfsrc",
  "databases": [
    {
      "id": "dev",
      "name": "Разработка",
      "type": "file",
      "path": "C:\\Bases\\MyApp"
    }
  ]
}
```

## Полный пример

```json
{
  "v8path": "C:\\Program Files\\1cv8\\8.3.25.1257\\bin",
  "configSrc": "cfsrc",
  "extensions": "extensions",
  "reports": "reports",
  "processing": "processing",
  "databases": [
    {
      "id": "dev",
      "name": "Разработка",
      "type": "file",
      "path": "C:\\Bases\\MyApp_Dev",
      "user": "Admin",
      "password": "",
      "aliases": ["dev", "разработка"],
      "branches": ["dev", "develop", "feature/*"],
      "configSrc": "C:\\WS\\myapp\\cfsrc",
      "webUrl": "http://localhost:8081/dev"
    },
    {
      "id": "prod",
      "name": "Рабочая",
      "type": "server",
      "server": "srv01",
      "ref": "MyApp_Prod",
      "user": "Admin",
      "password": "",
      "aliases": ["prod", "рабочая", "боевая"],
      "branches": ["main", "release/*"]
    }
  ],
  "default": "dev",
  "webPath": "C:\\tools\\apache24",
  "ffmpegPath": "C:\\tools\\ffmpeg\\bin\\ffmpeg.exe",
  "tts": {
    "provider": "edge",
    "voice": "ru-RU-DmitryNeural"
  }
}
```

## Связанные навыки

- [Базы данных](db-guide.md) — `/db-list`, `/db-create`, `/db-load-xml`, `/db-dump-xml` и другие
- [Веб-публикация](web-guide.md) — `/web-publish`, `/web-info`, `/web-stop`
- [Тестирование в браузере](web-test-guide.md) — `/web-test`
- [Запись видеоинструкций](web-test-recording-guide.md) — запись видео, субтитры, озвучка
