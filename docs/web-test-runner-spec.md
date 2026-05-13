# web-test runner: спецификация

Версия: 0.2
Дата: 2026-05-13 (последний sync)

## Обзор

Единый механизм регрессионного тестирования веб-клиента 1С.
Два сценария использования, один инструмент:

1. **Внутренний регресс** -- тестирование API browser.mjs для безопасного рефакторинга
2. **Пользовательский регресс** -- тестирование 1С-приложений (доработанных типовых или разработанных с нуля)

Принцип: если удобно для пользовательского регресса, подходит и для внутреннего.

Паттерны следуют конвенциям Playwright Test (обёртки шагов, хуки, утверждения).

---

## 1. Командная строка

```
node run.mjs test [url] <dir|file> [флаги]
```

| Флаг | По умолчанию | Описание |
|------|-------------|----------|
| `--tags=smoke,crud` | (все) | Фильтр тестов по тегам (пересечение) |
| `--grep=pattern` | (все) | Фильтр тестов по имени (регулярное выражение) |
| `--bail` | false | Остановиться при первом падении |
| `--retry=N` | 0 | Повторить упавшие тесты N раз |
| `--timeout=ms` | 30000 | Таймаут на тест (мс) |
| `--report=path` | (нет) | Записать JSON-отчёт в файл (или XML для `--format=junit`) |
| `--format=fmt` | json | Формат отчёта: `json` / `allure` / `junit` |
| `--report-dir=path` | dirname(report) / testDir | Каталог для скриншотов, видео, Allure-результатов |
| `--screenshot=strategy` | on-failure | `on-failure` / `every-step` / `off` |
| `--record` | false | Записывать видео для каждого теста (mp4 в `--report-dir`) |
| `-- <hookArgs...>` | -- | Всё после `--` пробрасывается в `_hooks.mjs` как `hookArgs` (см. §6.1) |

URL необязателен, если в каталоге тестов есть `webtest.config.mjs`. CLI URL переопределяет URL дефолтного контекста.

### Режим выполнения

In-process (не через HTTP). Раннер:
1. Загружает конфиг (если есть).
2. Обнаруживает файлы `*.test.mjs`, читает каждый, извлекает метаданные.
3. Фильтрует по `--tags`/`--grep`/`only`. Параметризованные тесты разворачиваются.
4. Запускает браузер и default-контекст (`chromium.launch()` или `launchPersistentContext`
   в зависимости от `isolation`).
5. Тесты выполняются последовательно **в алфавитном порядке имён файлов**
   (внутри файла — в порядке экспорта).
6. Для каждого теста: лениво создаёт нужные BrowserContext-ы (`ensureContext`),
   переключает активный, прогоняет хуки и тело, делает встроенный reset.
7. По завершении: финальный teardown контекстов с `beforeCloseContext`-хуками,
   `disconnect()`, `cleanup()`.

---

## 2. Формат тест-модуля

Каждый файл `*.test.mjs` -- ES-модуль.

### Экспорты

| Экспорт | Тип | Обязателен | По умолчанию | Описание |
|---------|-----|-----------|-------------|----------|
| `name` | `string` | да | -- | Читаемое имя теста |
| `default` | `async function(ctx)` | да | -- | Тело теста |
| `tags` | `string[]` | нет | `[]` | Теги для фильтрации |
| `timeout` | `number` | нет | 30000 | Таймаут теста (мс) |
| `skip` | `boolean \| string` | нет | false | Пропустить тест (строка = причина) |
| `only` | `boolean` | нет | false | Запустить только этот тест (отладка) |
| `context` | `string` | нет | defaultContext | Имя контекста из конфига |
| `contexts` | `string[]` | нет | -- | Мульти-пользовательский процессный тест |
| `params` | `object[]` | нет | -- | Параметризация (будущее) |
| `setup` | `async function(ctx)` | нет | -- | Подготовка перед тестом |
| `teardown` | `async function(ctx)` | нет | -- | Очистка после теста (выполняется всегда) |

### Пример: тест с одним контекстом

```js
export const name = 'CRUD справочника Контрагенты';
export const tags = ['smoke', 'crud', 'catalog'];
export const timeout = 45000;

export default async function({ navigateSection, openCommand, clickElement,
  fillFields, readTable, closeForm, getFormState, assert, step, log }) {

  await step('Открыть список', async () => {
    await navigateSection('Склад');
    await openCommand('Контрагенты');
  });

  await step('Создать элемент', async () => {
    await clickElement('Создать');
    await fillFields({ 'Наименование': 'Тест-' + Date.now() });
    await clickElement('Записать и закрыть');
  });

  await step('Проверить в списке', async () => {
    const table = await readTable();
    assert.tableHasRow(table, r => r['Наименование']?.startsWith('Тест-'));
    log('Элемент найден в списке');
  });
}
```

### Пример: мульти-контекстный процессный тест

Рекомендация: латинский ID контекста + кириллический `displayName` в
`webtest.config.mjs.contexts.<id>.displayName` (см. §7).

```js
export const name = 'Согласование приходной накладной';
export const contexts = ['clerk', 'manager'];
export const tags = ['process'];

export default async function({ clerk, manager, step }) {

  await step('Кладовщик создаёт накладную', async () => {
    await clerk.navigateSection('Склад');
    await clerk.openCommand('Приходные накладные');
    await clerk.clickElement('Создать');
    await clerk.fillFields({ 'Контрагент': 'ООО Поставщик' });
    await clerk.clickElement('Записать');
  });

  await step('Менеджер утверждает', async () => {
    await manager.navigateSection('Согласование');
    await manager.openCommand('На утверждении');
    await manager.clickElement('ООО Поставщик', { dblclick: true });
    await manager.clickElement('Утвердить');
  });

  await step('Освобождаем контекст clerk', async () => {
    await manager.closeContext('clerk');  // освободить лицензию 1С
  });
}
```

---

## 3. Объект контекста

Каждая тестовая функция получает объект контекста `ctx`:

### API браузера (все экспорты browser.mjs)

Все функции обёрнуты авто-обнаружением ошибок (как в `executeScript`):
- При модальной/всплывающей ошибке 1С: скриншот + `fetchErrorStack` + throw
- Обёрнутые ACTION_FNS: `clickElement`, `fillFields`, `fillField`, `selectValue`,
  `fillTableRow`, `deleteTableRow`, `openCommand`, `navigateSection`,
  `navigateLink`, `openFile`, `closeForm`, `filterList`, `unfilterList`

Полный список доступных функций:

**Навигация:** `navigateSection`, `openCommand`, `switchTab`, `navigateLink`, `openFile`
**Состояние:** `getFormState`, `getPageState`, `getSections`, `getCommands`
**Таблицы:** `readTable`, `readSpreadsheet`, `fillTableRow`, `deleteTableRow`
**Поля:** `fillFields`, `fillField`, `selectValue`
**Действия:** `clickElement`, `closeForm`, `filterList`, `unfilterList`
**Ошибки:** `dismissPendingErrors`, `fetchErrorStack`
**Контексты:** `createContext`, `setActiveContext`, `closeContext`, `listContexts`,
`hasContext`, `getActiveContext`
**Запись:** `startRecording`, `stopRecording`, `isRecording`, `addNarration`, `getCaptions`
**Презентация:** `showCaption`, `hideCaption`, `showTitleSlide`, `hideTitleSlide`,
`showImage`, `hideImage`, `highlight`, `unhighlight`, `setHighlight`, `isHighlightMode`
**Утилиты:** `screenshot`, `wait`, `getPage`, `getSession`

### Тестовые утилиты

- `step(name, fn)` -- обёртка шага (см. раздел 4)
- `assert.*` -- хелперы утверждений (см. раздел 5)
- `log(...args)` -- добавить в вывод теста

### Метаданные теста (`ctx.testInfo`)

Декларативная информация о текущем тесте. Раннер выставляет `ctx.testInfo`
перед каждой попыткой (до `beforeEach`), хук и тело теста могут читать.
Не предназначено для мутации.

```js
ctx.testInfo = {
  name,             // 'Навигация по разделам' (с подставленными params)
  file,             // '01-navigation.test.mjs' (basename)
  filePath,         // '01-navigation.test.mjs' (relative к testDir)
  tags,             // ['nav', 'smoke']
  timeout,          // 60000 (ms)
  attempt,          // 1..maxAttempts (1-based)
  maxAttempts,      // 1 + retry
  param,            // { ... } | undefined (для export const params)
  contexts: {       // объект, всегда 1+ ключей; зеркалит config.contexts
    a: { url, isolation, ...customFields },
    b: { ... },
  },
  primaryContext,   // 'a' — имя контекста, активного на входе в тест
                    // (= t.context для single, t.contexts[0] для multi)
}
```

Доступ к специфике контекста: `testInfo.contexts[testInfo.primaryContext].displayName`.
`primaryContext` — декларация теста, не зависит от runtime-состояния
`getActiveContext()` (которое может меняться внутри теста).

### Результат теста в afterEach (`ctx.testResult`)

Только в `afterEach`. До запуска теста — `null`. После — заполняется
раннером перед вызовом хука:

```js
ctx.testResult = {
  status,      // 'passed' | 'failed'
  duration,    // ms
  attempts,    // фактически выполнено попыток (1..maxAttempts)
  error,       // { message, step?, screenshot? } | null
  steps,       // массив step-результатов
}
```

### Мульти-контекст

При `export const contexts = ['a', 'b']`:
- `ctx.a` и `ctx.b` -- отдельные объекты контекста, каждый с полным API браузера
- `ctx.step` и `ctx.assert` остаются на верхнем уровне

---

## 4. step(name, fn) -- обёртка шага

```js
await step('Имя шага', async () => {
  // тело шага
});
```

Поведение:
- Записывает метку `start` перед `fn()`
- Записывает метку `stop` после `fn()` (успех или ошибка)
- При ошибке: устанавливает `status: 'failed'`, прикрепляет сообщение, пробрасывает исключение
- При успехе: устанавливает `status: 'passed'`
- Если стратегия скриншотов `every-step`: делает скриншот после `fn()`
- Вложенные шаги поддерживаются (шаг внутри шага)
- Напрямую маппится на шаги Allure

Структура данных шага (для отчётов):

```js
{
  name: 'Имя шага',
  start: 1712345678000,  // мс от эпохи
  stop:  1712345679200,
  status: 'passed' | 'failed',
  error: 'сообщение' | undefined,
  screenshot: 'путь' | undefined,
  steps: []  // вложенные шаги
}
```

Реализация (~15 строк):

```js
async function step(name, fn) {
  const s = { name, start: Date.now(), status: 'passed', steps: [] };
  const parent = currentSteps;
  parent.push(s);
  const prev = currentSteps;
  currentSteps = s.steps;
  try {
    await fn();
  } catch (e) {
    s.status = 'failed';
    s.error = e.message;
    throw e;
  } finally {
    s.stop = Date.now();
    currentSteps = prev;
  }
}
```

---

## 5. Утверждения (assertions)

Простые хелперы утверждений. Без зависимостей. Бросают `AssertionError` со
свойствами `.actual`, `.expected`, `.message`.

### Общие

```js
assert.ok(value, msg)                    // истинность
assert.equal(actual, expected, msg)      // ===
assert.notEqual(actual, expected, msg)   // !==
assert.deepEqual(actual, expected, msg)  // сравнение через JSON
assert.includes(haystack, needle, msg)   // string/array .includes()
assert.match(string, regex, msg)         // проверка регулярным выражением
assert.throws(asyncFn, msg)             // ожидает исключение
```

### Специфичные для 1С

```js
assert.formHasField(state, fieldName, msg)
// проверяет наличие state.fields[fieldName]

assert.formTitle(state, expected, msg)
// проверяет state.title === expected (или includes)

assert.tableHasRow(table, predicate, msg)
// predicate: объект (частичное совпадение) или функция
// объект: assert.tableHasRow(table, { 'Наименование': 'Тест' })
// функция: assert.tableHasRow(table, r => r['Сумма'] > 100)

assert.tableRowCount(table, expected, msg)
// проверяет table.rows.length === expected

assert.noErrors(state, msg)
// проверяет !state.errors
```

---

## 6. Хуки

Все хуки определяются в `_hooks.mjs` в корне каталога тестов.

### Два уровня

**Инфраструктурный уровень** (без браузера):
- `prepare({ hookArgs, log, config })` -- до подключения (восстановление БД, публикация, загрузка данных)
- `cleanup({ hookArgs, log, config })` -- после отключения (удаление публикации, очистка)

Поля:
- `hookArgs: string[]` -- всё что в командной строке передано после разделителя `--`,
  без интерпретации со стороны раннера. Хук парсит сам (см. §6.1 ниже).
- `log: (...args) => void` -- функция логирования раннера (структурированный вывод
  с префиксом `[hooks]`). Использовать вместо `console.log` чтобы не ломать формат отчёта.
- `config: object` -- разобранный `webtest.config.mjs` (URL контекстов, isolation, etc.).

**Тестовый уровень** (с контекстом браузера):
- `beforeAll(ctx)` -- после подключения, перед первым тестом
- `afterAll(ctx)` -- после последнего теста, до отключения
- `beforeEach(ctx)` -- перед каждым тестом. На входе уже доступен `ctx.testInfo` (см. §3).
- `afterEach(ctx)` -- после каждого теста. Дополнительно доступен `ctx.testResult`
  с результатом завершившегося теста (status/duration/error/...).

**Контекстный уровень** (на каждый browser-контекст, lifecycle = создан → удалён):
- `afterOpenContext(ctx, name, spec)` -- сразу после успешного `createContext`.
  `spec` -- запись из `config.contexts[name]` со всеми custom-полями (`displayName`,
  `url`, `isolation`, ...). Полезно: инжект persistent overlay/badge,
  preload-навигация для контекста, регистрация телеметрии.
- `beforeCloseContext(ctx, name, spec)` -- перед `closeContext` (контекст ещё
  активен и работает). Полезно: финальный flush, сбор метрик, последний скриншот.
  Срабатывает как при явном `ctx.closeContext(name)` из теста, так и в
  финальном teardown раннера перед `disconnect`.

`closeContext(name)` валиден только когда `name !== getActiveContext()` -- иначе
бросает. В scoped API (`ctx.a.closeContext('b')`) это естественно: scoped-обёртка
сначала `setActiveContext('a')`, потом close `'b'` -- target всегда не активен.

### Порядок выполнения

```
prepare()                          // без браузера (восстановление БД, публикация)
  browser.launch()                 // запуск процесса браузера
  createContext(default)           // первый контекст создан
    afterOpenContext(ctx, default) // hook: контекст готов
    beforeAll(ctx)                 // браузер готов, default-контекст создан
      [lazy ensureContext(name)]   // для multi-context тестов
        afterOpenContext(ctx, name)
      beforeEach(ctx)
        test.setup(ctx)            // подготовка теста
          test.default(ctx)        // тело теста (может вызвать ctx.closeContext)
            [при ctx.closeContext(x)]: beforeCloseContext(ctx, x) → close(x)
        test.teardown(ctx)         // очистка теста (всегда)
      afterEach(ctx)               // всегда
      [встроенный сброс]           // всегда (для каждого живого контекста теста)
      ...следующий тест...
    afterAll(ctx)
  [для каждого оставшегося контекста]: beforeCloseContext → closeContext
  browser.close()                  // финальный disconnect
cleanup()                          // без браузера (удаление публикации)
```

### Встроенный сброс состояния

После каждого теста (после `afterEach`) раннер гарантирует чистое состояние:

```js
await dismissPendingErrors();
while (есть открытые формы) {
  await closeForm({ save: false });
}
```

Это гарантирует, что каждый тест стартует с чистого рабочего стола,
независимо от того, как завершился предыдущий (падение, таймаут, ошибка утверждения).

### Пример _hooks.mjs

```js
import { execSync } from 'child_process';

export async function prepare({ hookArgs, log, config }) {
  // Простой парсер ad-hoc флагов: hookArgs приходит как есть, без интерпретации
  // раннером (см. §6.1 ниже).
  const force = hookArgs.includes('--rebuild-stand');
  log('preparing stand, force=', force);
  execSync('powershell.exe -File scripts/restore-db.ps1');
  execSync('powershell.exe -File scripts/publish.ps1');
}

export async function cleanup({ log }) {
  log('cleaning up stand');
  execSync('powershell.exe -File scripts/unpublish.ps1');
}

export async function beforeAll(ctx) {
  // По умолчанию 1С после входа уже показывает дефолтную секцию — навигация
  // в beforeAll обычно не нужна. Хук удобен для счётчиков, телеметрии,
  // общего setup'а который должен случиться один раз для всего прогона.
}

export async function afterEach(ctx) {
  // Доступен ctx.testResult — { status, duration, attempts, error, steps }.
  // Встроенный сброс состояния выполняется ПОСЛЕ afterEach автоматически.
}

export async function afterOpenContext(ctx, name, spec) {
  // Контекст name создан. spec — config.contexts[name]. Удобно для
  // persistent DOM-overlay'я с displayName (видно в видео какая вкладка к
  // какому пользователю относится).
}

export async function beforeCloseContext(ctx, name, spec) {
  // Контекст name вот-вот закроется. Срабатывает и при ctx.closeContext
  // из теста, и в финальном teardown раннера.
}
```

### 6.1. Проброс пользовательских флагов через `--`

Раннер не знает о пользовательских флагах хуков. Чтобы хуки получили ad-hoc
параметры без правки `webtest.config.mjs` или окружения, используется стандартная
shell-конвенция `--` (как у `npm`, `cargo`, `pytest`): всё что идёт после `--`
в CLI раннера передаётся в `prepare`/`cleanup` через поле `hookArgs: string[]`
без интерпретации.

```
node run.mjs test tests/web-test/ --bail -- --rebuild-stand --reload-data
                                  └─ runner ─┘ └──── hookArgs ────────────┘
```

В этом примере раннер получает `--bail`, а `hookArgs` хуков становится
`['--rebuild-stand', '--reload-data']`. Парсинг этого массива — ответственность
хуков.

Если разделитель `--` не указан, `hookArgs` — пустой массив. Это позволяет
раннеру и хукам эволюционировать независимо: новый builtin-флаг раннера
никогда не пересечётся с пользовательским.

---

## 7. Файл конфигурации

`webtest.config.mjs` в корне каталога тестов. Необязателен -- если отсутствует,
URL должен быть передан через CLI.

```js
export default {
  // Контексты: именованные URL для разных пользователей/ролей.
  // Рекомендация: латинский ID контекста (`clerk`, `manager`) + кириллический
  // `displayName` для UI/слайдов. Любые custom-поля пробрасываются как есть
  // и доступны хукам через `ctx.testInfo.contexts[name]` (см. §3).
  contexts: {
    clerk:   { url: 'http://localhost/app-clerk/ru_RU',   displayName: 'Кладовщик' },
    manager: { url: 'http://localhost/app-manager/ru_RU', displayName: 'Менеджер' },
    admin:   { url: 'http://localhost/app-admin/ru_RU',   displayName: 'Админ' },
  },
  defaultContext: 'clerk',

  // Значения по умолчанию (переопределяются флагами CLI)
  timeout: 30000,
  retries: 0,
  screenshot: 'on-failure',  // 'every-step' | 'off'
  record: false,
};
```

Кириллица в ID контекстов работает, но смешанный регистр затрудняет ergonomics
(`testInfo.contexts.кладовщик.displayName` vs `testInfo.contexts.clerk.displayName`).
Рекомендуем разделять технический ID и человекочитаемое имя.

**Упрощённая форма** (один контекст, без именованных):

```js
export default {
  url: 'http://localhost/app/ru_RU',
  timeout: 30000,
};
```

Флаги CLI всегда переопределяют значения конфига.

---

## 8. Контексты

### Механизм: Playwright BrowserContext

Один процесс браузера (`chromium.launch()`), несколько изолированных контекстов.
Каждый контекст -- отдельная сессия (куки, авторизация, состояние страницы).

```
browser (один процесс chromium)
  ├─ BrowserContext "кладовщик" → page → http://localhost/app-clerk/ru_RU
  ├─ BrowserContext "менеджер"  → page → http://localhost/app-mgr/ru_RU
  └─ BrowserContext "админ"    → page → http://localhost/app-admin/ru_RU
```

Преимущества:
- **Мгновенное переключение** между пользователями (смена активного `page`)
- **Состояние сохраняется** -- переключились на менеджера и обратно, у кладовщика
  все формы остались открытыми, ничего не потеряно
- **Нет переподключений** -- каждая сессия живёт независимо
- **Один процесс** -- экономия ресурсов по сравнению с несколькими браузерами
- **Стандартный паттерн** Playwright для мульти-пользовательских сценариев

### Одиночный контекст (по умолчанию)

Большинство тестов. Один BrowserContext, один пользователь.
Тест получает плоский контекст со всем API.

```js
export const context = 'кладовщик';  // необязательно, используется defaultContext
export default async function({ clickElement, fillFields, ... }) { }
```

### Порядок выполнения и переключение контекста

Раннер НЕ группирует тесты по контексту. Порядок выполнения — алфавитный
по именам файлов (плюс порядок экспорта внутри файла). Для каждого теста:
1. Через `ensureContext(name)` создаются BrowserContext-ы, упомянутые в
   `t.context` / `t.contexts` (если ещё не созданы).
2. `setActiveContext(testContextNames[0])` — активный контекст = первый
   объявленный (для single — `t.context || defaultContext`, для multi —
   `t.contexts[0]`).
3. После теста встроенный сброс пробегает по всем использованным контекстам.

Контексты живут между тестами: переключение через `setActiveContext` —
дешёвое, новый login не требуется. Закрываются явно (`closeContext`) или
финальным teardown'ом перед `disconnect()`.

### Мульти-контекст (процессные тесты)

```js
export const contexts = ['кладовщик', 'менеджер'];
export default async function({ кладовщик, менеджер, step, assert }) { }
```

Каждый именованный контекст -- полноценный объект API со своим `page`.
Тест оркестрирует переключение между пользователями.
Состояние каждого пользователя сохраняется между переключениями:

```js
await step('Кладовщик создаёт документ', async () => {
  await кладовщик.openCommand('Приходные накладные');
  await кладовщик.clickElement('Создать');
  await кладовщик.fillFields({ 'Контрагент': 'ООО Поставщик' });
  await кладовщик.clickElement('Записать');
  // кладовщик стоит на форме документа
});

await step('Менеджер утверждает', async () => {
  await менеджер.navigateSection('Согласование');
  await менеджер.clickElement('Утвердить');
});

await step('Кладовщик проверяет статус', async () => {
  // страница кладовщика ТА ЖЕ -- форма открыта, навигация не нужна
  const state = await кладовщик.getFormState();
  assert.equal(state.fields['Статус']?.value, 'Утверждён');
});
```

### Реализация в browser.mjs

`browser.mjs` хранит активный слот в module-level `page`/`browser`/`sessionPrefix`/`seanceId`,
зеркалит его из Map `contexts: Map<name, slot>`. Переключение между слотами:
`_saveActiveSlot()` сохраняет module-level → slot, `_activateSlot(name)`
загружает slot → module-level. Это держит API-функции (`clickElement`,
`fillFields` и т.д.) plain — они работают с текущим активным `page`,
не зная про множественность контекстов.

Публичный контекстный API:
- `createContext(name, url, { isolation, extensionPath })` — создаёт BrowserContext
  и navigate'ит на URL.
- `setActiveContext(name)` — переключает активный слот, при активной записи
  flush'ит хвост старой страницы и переподключает screencast к новой.
- `closeContext(name)` — logout + close (page для `tab`, BrowserContext для
  `window`), удаляет из реестра. Throw если `name === active`.
- `listContexts()` / `hasContext(name)` / `getActiveContext()` — read-only.

### Режимы изоляции

`isolation` (per-context или config-level):

| Режим | Реализация | Окна | Cookies | 1С-расширение |
|-------|-----------|------|---------|---------------|
| `'tab'` (default) | `launchPersistentContext` + `newPage()` per context | 1 окно, N вкладок | shared by path | загружается надёжно |
| `'window'` | `chromium.launch()` + `newContext()` per context | N окон | полная изоляция | может не загружаться |

Смешивать режимы в одном прогоне нельзя — `createContext` бросает явную ошибку.

---

## 9. Отчёты

### JSON (нативный, по умолчанию)

```json
{
  "runner": "web-test",
  "url": "http://localhost/app/ru_RU",
  "startedAt": "2026-04-05T10:00:00.000Z",
  "finishedAt": "2026-04-05T10:05:30.000Z",
  "duration": 330.0,
  "summary": {
    "total": 25,
    "passed": 23,
    "failed": 1,
    "skipped": 1
  },
  "tests": [
    {
      "name": "CRUD справочника Контрагенты",
      "file": "02-catalog-crud.test.mjs",
      "tags": ["smoke", "crud"],
      "contexts": ["clerk"],
      "status": "passed",
      "duration": 12.3,
      "attempts": 1,
      "steps": [
        {
          "name": "Открыть список",
          "start": 1712345678000,
          "stop": 1712345679200,
          "status": "passed",
          "steps": []
        }
      ],
      "output": "Элемент найден в списке",
      "error": null,
      "screenshot": null
    },
    {
      "name": "Обязательное поле",
      "file": "10-validation.test.mjs",
      "tags": ["validation"],
      "contexts": ["clerk"],
      "status": "failed",
      "duration": 8.1,
      "attempts": 2,
      "steps": [
        {
          "name": "Сохранить пустую форму",
          "start": 1712345700000,
          "stop": 1712345708100,
          "status": "failed",
          "error": "Ожидалось модальное окно ошибки, но форма сохранилась"
        }
      ],
      "output": "",
      "error": {
        "message": "Ожидалось модальное окно ошибки, но форма сохранилась",
        "step": "Сохранить пустую форму",
        "screenshot": "error-shot-10.png"
      },
      "screenshot": "error-shot-10.png"
    }
  ]
}
```

### Allure (`--format=allure --report-dir=allure-results/`)

Отдельные JSON-файлы для каждого теста в каталоге `allure-results/`:

```json
{
  "uuid": "сгенерированный-uuid",
  "name": "CRUD справочника",
  "fullName": "02-catalog-crud.test.mjs",
  "status": "passed",
  "stage": "finished",
  "start": 1712345678000,
  "stop": 1712345690300,
  "labels": [
    { "name": "tag", "value": "smoke" },
    { "name": "tag", "value": "crud" }
  ],
  "steps": [
    {
      "name": "Открыть список",
      "status": "passed",
      "start": 1712345678000,
      "stop": 1712345679200,
      "steps": []
    }
  ],
  "attachments": [
    {
      "name": "Скриншот при падении",
      "source": "uuid-attachment.png",
      "type": "image/png"
    }
  ]
}
```

Скриншоты/видео копируются в `allure-results/` с уникальными именами.

### JUnit XML (`--format=junit`)

```xml
<?xml version="1.0" encoding="UTF-8"?>
<testsuites name="web-test" tests="25" failures="1" skipped="1" time="330.0">
  <testsuite name="tests/web-test" tests="25" failures="1" skipped="1">
    <testcase name="CRUD справочника" classname="02-catalog-crud.test.mjs" time="12.3"/>
    <testcase name="Обязательное поле" classname="10-validation.test.mjs" time="8.1">
      <failure message="Ожидалось модальное окно ошибки, но форма сохранилась">
        Стек вызовов...
      </failure>
      <system-out>Скриншот: error-shot-10.png</system-out>
    </testcase>
  </testsuite>
</testsuites>
```

---

## 10. Консольный вывод

```
web-test -- http://localhost/app/ru_RU
Запуск 25 тестов из tests/web-test/

  ✓ Навигация по разделам (2.1s)
  ✓ CRUD справочника Контрагенты (12.3s)
    ├ Открыть список (1.2s)
    ├ Создать элемент (8.0s)
    └ Проверить в списке (3.1s)
  ✗ Обязательное поле (8.1s)
    ├ Открыть форму (2.0s)
    └ ✗ Сохранить пустую форму (6.1s)
      Ожидалось модальное окно ошибки, но форма сохранилась
      скриншот: error-shot-10.png
  ○ Составной тип (skip: не реализовано)

23 passed, 1 failed, 1 skipped (2m 0.5s)
```

Для passed-тестов выводится одна строка `✓ name (duration)`. Шаги печатаются
только для упавших — после строки `✗`, с отступом, плюс сообщение ошибки и
путь к скриншоту. Полная картина по шагам — в JSON-отчёте (`--report=...`).

---

## 11. Скриншоты и видео

### Стратегия скриншотов

| Стратегия | Поведение |
|-----------|----------|
| `on-failure` (по умолчанию) | Скриншот при падении теста, прикрепляется к ошибке |
| `every-step` | Скриншот в конце каждого `step()`, плюс при падении |
| `off` | Без автоматических скриншотов |

Скриншоты сохраняются в каталог отчёта по шаблону `{индекс-теста}-{имя-шага}.png`.

### Видеозапись

При включённом `--record`:
- `startRecording()` перед каждым тестом
- `stopRecording()` после каждого теста
- Видео сохраняется как `{индекс-теста}-{имя-теста}.mp4`
- Прикрепляется к отчёту (Allure: вложение видео)

---

## 12. Сброс состояния

Встроенный механизм, выполняется после `afterEach` (и `teardown`) каждого теста:

```js
async function resetState(ctx) {
  // 1. Убрать все ожидающие диалоги ошибок/всплывающие уведомления
  try { await ctx.dismissPendingErrors(); } catch {}

  // 2. Закрыть все открытые формы до рабочего стола
  for (let i = 0; i < 10; i++) {
    const state = await ctx.getFormState();
    if (!state.form) break;
    try { await ctx.closeForm({ save: false }); } catch { break; }
  }
}
```

Гарантирует, что каждый тест стартует с чистого рабочего стола,
независимо от того, как завершился предыдущий (падение, таймаут, ошибка утверждения).

---

## 13. Параметризация

```js
export const name = 'Заполнение поля {type}';
export const params = [
  { type: 'String', field: 'Наименование', value: 'Тест' },
  { type: 'Number', field: 'Цена', value: '100.50' },
  { type: 'Date', field: 'ДатаПоступления', value: '01.01.2024' },
  { type: 'Boolean', field: 'Активен', value: true },
];

export default async function({ fillFields, getFormState, assert }, { type, field, value }) {
  await fillFields({ [field]: value });
  const state = await getFormState();
  assert.equal(state.fields[field]?.value, String(value));
}
```

Параметры разворачиваются в отдельные тесты на этапе discovery. Имя
формируется подстановкой через шаблон `{key}` в `mod.name`; если шаблона
нет — суффикс `[index]`. Тест получает `param` вторым аргументом
(`default(ctx, param)`). В отчётах каждый набор — отдельная запись со
своим `name` и `param` в testInfo. `ctx.testInfo.param` доступен в теле
теста и хуках.

---

## 14. buildContext()

Общая фабрика контекста, используется и `executeScript()` (для `exec`/`run`/`start`),
и `cmdTest()` (для `test`).

**Что делает:**
- Собирает все экспорты `browser.*` в плоский объект.
- Оборачивает ACTION_FNS авто-обнаружением 1С-ошибок: после каждого вызова
  проверяет `state.errors.modal`/`balloon`, делает скриншот ДО того, как
  `fetchErrorStack` закроет модалку, вызывает `fetchErrorStack` для modal-ошибок,
  бросает исключение со структурированным `err.onecError = { step, args, errors, formState, stack, screenshot }`.
- Подмешивает заглушки `noRecord` (для функций записи/озвучки в exec-режиме).

**Сигнатура:** `function buildContext({ noRecord = false } = {}) -> object`

**Scoped-вариант** (`buildScopedContext(name)`): тот же `buildContext()`,
но каждый вызов функции префиксится `await browser.setActiveContext(name)`.
Используется для мульти-контекстных тестов (`ctx.a`/`ctx.b`).

---

## 15. Синтетическая тестовая конфигурация

### Текущие объекты base-config

| Объект | Поля | Форма |
|--------|------|-------|
| Справочник Контрагенты | ИНН (String 12), Телефон (String 20) | ФормаЭлемента: 3 поля ввода |
| Справочник Номенклатура | Артикул (String 25), ЕдиницаИзмерения (String 10) | -- |
| Перечисление ВидыНоменклатуры | Товар, Услуга, Работа | -- |
| Документ ПриходнаяНакладная | Контрагент (String); ТЧ Товары (4 колонки) | ФормаДокумента |
| РН ОстаткиТоваров | Изм: Номенклатура; Рес: Количество, Сумма | -- |
| РС КурсыВалют | Изм: Валюта; Рес: Курс, Кратность | -- |
| Константа ОсновнаяВалюта | String 10 | -- |
| Отчёт ОстаткиТоваров | Схема СКД | -- |
| Подсистема Склад | все объекты | -- |
| Роль Кладовщик | права Read/View | -- |

### Что нужно добавить

| Изменение | Зачем (какой API тестируем) |
|-----------|---------------------------|
| Номенклатура: +Цена (Number 15.2) | fillFields -- число |
| Номенклатура: +Активен (Boolean) | fillFields -- флажок |
| Номенклатура: +ВидНоменклатуры (EnumRef) | fillFields -- ссылка на перечисление |
| Номенклатура: +ДатаПоступления (Date) | fillFields -- дата |
| Номенклатура: +Комментарий (String неограниченная) | fillFields -- многострочный текст |
| Номенклатура: FillChecking на Наименование | Тест ошибки валидации |
| Номенклатура: hierarchical=true | clickElement expand/collapse |
| Номенклатура: Форма с 2 вкладками (Основное / Дополнительно) | switchTab |
| ПриходнаяНакладная.Контрагент -> CatalogRef.Контрагенты | selectValue (ссылочное поле) |
| +Подсистема Администрирование (КурсыВалют, ОсновнаяВалюта) | navigateSection между разделами |
| Роль: полные права (не только Read/View) | CRUD без ограничений |

### Способ сборки

Интеграционный тест `build-webtest-config.test.mjs` собирает конфигурацию через
пайплайн навыков (cf-init -> meta-compile -> form-compile -> ...).
Результат кэшируется в `.cache/webtest-config/`.
Первый запуск требует: загрузку в 1С (`db-load-xml`) + веб-публикацию (`web-publish`).

---

## 16. Каталог тест-кейсов

Расположение: `tests/web-test/`. По состоянию на 2026-05-13: 19 файлов.

| # | Файл | Теги | Покрытие |
|---|------|------|----------|
| 00 | hooks.test.mjs | hooks, smoke | индикатор порядка beforeAll/beforeEach/afterEach + testInfo + afterOpenContext |
| 01 | navigation.test.mjs | nav, smoke | navigateSection, getPageState, navigateLink, switchTab, errors |
| 02 | crud.test.mjs | crud, smoke | openCommand, fillFields, clickElement, closeForm, save-confirm flow |
| 03 | fillfields.test.mjs | fields | text/checkbox/date/dropdown/reference/radio/clear + composite + direct-edit-form |
| 04 | selectvalue.test.mjs | fields, select | dropdown / форма выбора / auto-history / clear |
| 05 | table.test.mjs | table, smoke | fillTableRow/deleteTableRow/tab-loop/checkbox/clear |
| 06 | document.test.mjs | doc, smoke | создание+проведение документа |
| 07 | tabs.test.mjs | tabs | switchTab + errors |
| 08 | hierarchy.test.mjs | hierarchy | groups expand + tree-grid view-mode switch |
| 09 | filter.test.mjs | filter | simple-search/advanced-column/exact/date/reference/unfilter-all/unfilter-specific |
| 10 | validation.test.mjs | validation | сообщения + exception modal (fetchErrorStack Path 1) |
| 11 | report.test.mjs | report | DCS form + быстрый фильтр + readSpreadsheet + drill-down |
| 12 | formstate.test.mjs | state | fields/buttons/tables/openForms/subordinate-nav/platformDialogs |
| 13 | misc.test.mjs | misc | openFile EPF + security confirm |
| 14 | errors-stack.test.mjs | errors | fetchErrorStack Path 1 + dismiss-modal + dismiss-platform |
| 14 | multi-context-routing.test.mjs | multi-context | single test → non-default context |
| 15 | multi-context-handover.test.mjs | multi-context | ctx.a creates → ctx.b sees → closeContext(b) + edge throw |
| 15 | recording.test.mjs | record | startRecording/stopRecording/captions/narration/overlays |
| 16 | tree-form.test.mjs | tree, table | FormDataTree edit (ДеревоНоменклатуры) |

Полный регресс — **19/19** (~9 минут на warm-стенде).

---

## 17. Дорожная карта реализации

| # | Задача | Результат | Статус |
|---|--------|-----------|--------|
| 1 | Архитектурная спецификация | `docs/web-test-runner-spec.md` (этот файл) | done 2026-04-05 |
| 2 | Рефакторинг buildContext() | run.mjs: извлечение из executeScript | done 2026-04-05 |
| 3 | Ядро cmdTest() | run.mjs: обнаружение, импорт, выполнение, JSON-отчёт | done 2026-04-05 |
| 4 | Утверждения + обёртка step() | run.mjs: assert.*, step(name, fn) | done 2026-04-05 |
| 5 | Хуки (prepare/cleanup + before/after) | run.mjs: поддержка `_hooks.mjs` | done 2026-04-05 |
| 6 | Файл конфигурации + BrowserContext-ы | webtest.config.mjs, мульти-контекст | done 2026-05-10 (T4 + T4.5/4.6) |
| 7 | Форматы отчётов (Allure, JUnit) | --format=allure/junit | done 2026-05-03 (T2/T3) |
| 8 | Синтетическая конфигурация | `build-webtest-config.test.mjs` | done 2026-04-05 + M1 расширения 2026-05-01 |
| 9 | Smoke-тесты P0 (~18 кейсов) | `tests/web-test/01-12*.test.mjs` | done 2026-05-04 (M2) |
| 10 | Регресс P1 (~15 кейсов) | расширение 02/03/04/05/09/12 | done 2026-05-10 (M3) |
| 11 | M4: расширенный регресс P2 | validation/errors/recording/hierarchy/openFile | done 2026-05-11 |
| 12 | M5-pre: расширение синтетики | tree-form, composite, textEdit, history, unfilter | done 2026-05-12 |
| 13 | M6: автономный стенд через `_hooks.mjs` | prepare(): config-rebuild/data-reload/EPF + smart Apache | done 2026-05-12 (MVP) |
| 14 | M7.1/M7.2: ctx.testInfo + custom-поля контекстов | спека §3 + run.mjs | done 2026-05-13 |
| 15 | M7.3: Headless-режим | `--headless` CLI + config | deferred (1С-specific блокеры в headless) |
| 16 | M7.4: 4 testlevel-хука + индикатор | `_hooks.mjs` v0.3 + 00-hooks.test.mjs | done 2026-05-13 |
| 17 | M7.5: title slide bonus | `beforeEach` под isRecording() | done 2026-05-13 |
| 18 | M8: per-context lifecycle | closeContext + afterOpenContext/beforeCloseContext | done 2026-05-13 |
