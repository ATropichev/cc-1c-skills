---
name: cfe-validate
description: Валидация расширения конфигурации 1С (CFE). Используй после создания или модификации расширения для проверки корректности
argument-hint: <ExtensionPath> [-ConfigPath <cfg>] [-Detailed] [-MaxErrors 30]
allowed-tools:
  - Bash
  - Read
  - Glob
---

# /cfe-validate — валидация расширения конфигурации (CFE)

Проверяет структурную корректность расширения: XML-формат, свойства, состав, заимствованные объекты. Аналог `/cf-validate`, но для расширений.

## Параметры

| Параметр      | Обяз. | Умолч. | Описание                                        |
|---------------|:-----:|---------|-------------------------------------------------|
| ExtensionPath | да    | —       | Путь к каталогу или Configuration.xml расширения |
| ConfigPath    | нет   | —       | Конфигурация-источник: включает сверку путей заимствованных форм с реквизитами и табличными частями объектов основной конфигурации |
| Detailed      | нет   | —       | Подробный вывод (все проверки, включая успешные)  |
| MaxErrors     | нет   | 30      | Остановиться после N ошибок                      |
| OutFile       | нет   | —       | Записать результат в файл                        |

Без `-ConfigPath` проверка путей пропускается — об этом сказано в отчёте отдельной строкой. Путь к конфигурации ищи так же, как в `/cfe-borrow`: `.v8-project.json` → поле `configSrc` целевой базы.

## Команда

```powershell
powershell.exe -NoProfile -File "${CLAUDE_SKILL_DIR}/scripts/cfe-validate.ps1" -ExtensionPath "src"
powershell.exe -NoProfile -File "${CLAUDE_SKILL_DIR}/scripts/cfe-validate.ps1" -ExtensionPath "src/Configuration.xml"
powershell.exe -NoProfile -File "${CLAUDE_SKILL_DIR}/scripts/cfe-validate.ps1" -ExtensionPath "src" -ConfigPath "C:\cfsrc\erp"
```
