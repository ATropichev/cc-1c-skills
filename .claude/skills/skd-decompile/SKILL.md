---
name: skd-decompile
description: Декомпиляция схемы компоновки данных 1С (СКД) в JSON-черновик в формате skd-compile. Используй когда нужно создать новый отчёт по образцу существующего или провести структурный рефакторинг. Для точечных правок используй skd-edit
argument-hint: <TemplatePath> [-OutputPath <out.json>]
disable-model-invocation: true
allowed-tools:
  - Bash
  - Read
  - Write
  - Glob
---

# /skd-decompile — извлечение JSON-черновика из Template.xml СКД

Читает существующий `Template.xml` (DataCompositionSchema) и эмитит JSON в формате, который принимает `/skd-compile`. Получившийся JSON — **черновик**: гарантируется только структурная эквивалентность, не байтовая.

## Когда использовать

- **Scaffold нового отчёта по образцу.** Взять существующий СКД, получить JSON, поправить параметры/поля/шаблоны, скомпилировать в новый отчёт.
- **Глобальный рефакторинг.** Когда правка структурная (переписать вариант, перерисовать шаблон), а не точечная.

## Когда **не** использовать

- **Точечные правки готового отчёта** — добавить поле, фильтр, итог, переименовать. Для этого есть `/skd-edit`: точечно, без полной реконструкции, без риска потерь.
- **Анализ схемы** — для обзора используй `/skd-info` (overview/query/fields/variant/templates).

## Параметры и команда

| Параметр | Описание |
|----------|----------|
| `TemplatePath` | Путь к Template.xml (обязательный) |
| `OutputPath` | Путь к выходному JSON. Если не задан — JSON в stdout |

```powershell
# В файл (рядом, если есть warnings, кладётся <basename>.warnings.md)
powershell.exe -NoProfile -File "${CLAUDE_SKILL_DIR}/scripts/skd-decompile.ps1" -TemplatePath "<Template.xml>" -OutputPath "<out.json>"

# В stdout
powershell.exe -NoProfile -File "${CLAUDE_SKILL_DIR}/scripts/skd-decompile.ps1" -TemplatePath "<Template.xml>"
```

## Гарантии и ограничения

- **JSON всегда валиден** — компилируется через `skd-compile` без синтаксических ошибок.
- **Покрытие — DSL `skd-compile`.** Конструкции XML вне DSL отмечаются sentinel-объектом `{"__unsupported__": {...}}` и описаны в `<basename>.warnings.md` рядом с JSON. `skd-compile` фейлится при наличии sentinel — это специально, чтобы пользователь сначала разобрался с непокрытым.
- **Не байтовая эквивалентность.** После round-trip XML структурно эквивалентен оригиналу, но порядок атрибутов/секций может отличаться.
- **Стиль ячейки** определяется по совпадению с одним из built-in (`header`/`data`/`subheader`/`total`) или user-стилей из `presets/skills/skd/skd-styles.json`. Точечный custom appearance не сворачивается → sentinel.

## Не поддерживается (fail-fast)

- Picture cells в шаблонах (`<dcsat:Picture>`).
- Параметры типа ХранилищеЗначения.
- Sibling templates / templateCondition (вариативные шаблоны).
- Не-СКД корневые XML (например, spreadsheet `<document>` — для них есть `/mxl-decompile`).

При обнаружении — скрипт пишет в stderr понятное сообщение и завершается с ненулевым кодом.

## Верификация

```
/skd-compile -DefinitionFile <out.json> -OutputPath <new-Template.xml>   — обратная компиляция
/skd-validate <new-Template.xml>                                          — валидация результата
/skd-info <new-Template.xml>                                              — визуальный осмотр
```
