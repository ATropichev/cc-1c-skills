---
name: xdto-compile
description: Создание пакета XDTO 1С из XML-схемы (XSD). Используй когда нужно добавить пакет XDTO в конфигурацию — для обмена, интеграции, веб-сервиса, разбора внешнего XML-формата
argument-hint: -XsdPath <файл.xsd> -OutputDir <каталог-исходников> [-Name <имя>] [-Synonym <синоним>] [-Comment <текст>] [-Force]
allowed-tools:
  - Bash
  - Read
  - Glob
---

# /xdto-compile — Создание пакета XDTO из XML-схемы

Собирает пакет XDTO по XML-схеме: `XDTOPackages/<Имя>.xml`,
`XDTOPackages/<Имя>/Ext/Package.bin` и регистрацию в `Configuration.xml`.

Вход — обычная XSD. Отдельного формата описания нет: пиши схему так, как её пишут
везде, остальное навык сделает сам.

## Параметры

| Параметр | Описание |
|----------|----------|
| `XsdPath` | Путь к файлу XML-схемы |
| `Xsd` | Схема строкой, вместо `-XsdPath` |
| `OutputDir` | Каталог исходников конфигурации или расширения — там, где лежит `Configuration.xml` |
| `Name` | Имя объекта метаданных. По умолчанию — из `xs:appinfo`, иначе имя файла XSD |
| `Synonym` | Синоним: строка или хеш-таблица `@{ru='…'; en='…'}` |
| `Comment` | Комментарий |
| `Force` | Перезаписать существующий пакет |

```powershell
powershell.exe -NoProfile -File "${CLAUDE_SKILL_DIR}/scripts/xdto-compile.ps1" -XsdPath "<схема.xsd>" -OutputDir "<каталог-исходников>"
```

Примеры:
```powershell
... -XsdPath bank.xsd -OutputDir src -Name ОбменСБанком -Synonym "Обмен с банком"
... -XsdPath fss.xsd  -OutputDir src -Force
```

## Читай предупреждения

XSD выразительнее модели XDTO. Всё, что не переносится один в один, навык переносит
приближённо и **пишет об этом**:

```
Предупреждения (2) — конструкции XSD без точного соответствия в модели XDTO:
  ! Документ : вложенная xs:choice уплощена в последовательность — выбор одного из вариантов не сохранён
  ! Документ : кратность на вложенной частице (<xs:sequence minOccurs/maxOccurs>) не выражается в модели XDTO
```

Такое сообщение означает, что пакет собран, но схема упрощена. Если упрощение
недопустимо — меняй схему (например, разноси варианты `xs:choice` по разным типам),
а не игнорируй.

Что переносится приближённо: вложенные `xs:sequence`/`xs:choice` (уплощаются в плоский
список свойств), `xs:all` (становится последовательностью), кратность на частице,
`substitutionGroup`, `xs:key`/`keyref`/`unique`, `xs:redefine`.

`xs:group` и `xs:attributeGroup` раскрываются по ссылке — их содержимое попадает в тип.
`xs:include` игнорируется: зависимости в XDTO разрешаются только по namespace,
поэтому включаемую схему нужно собрать отдельным пакетом и заменить `include` на `import`.

## Зависимости между пакетами

`<xs:import namespace="…"/>` разрешается по namespace среди пакетов конфигурации
или расширения.
Если пакета с таким пространством имён нет, платформа при загрузке молча подменит тип
на `xs:anyType` — без ошибки. Собирай сначала зависимости, потом зависящий пакет,
и проверяй результат через `/xdto-validate`.

## Что XSD выразить не может

Две вещи модель XDTO умеет, а XML Schema — нет: `nillable` у атрибута и `qualified`
у отдельного свойства. Они пишутся атрибутами из пространства имён модели:

```xml
<xs:attribute name="Представление" type="xs:string"
              xmlns:xdto="http://v8.1c.ru/8.1/xdto" xdto:nillable="true"/>
```

Схема остаётся валидной — валидаторы такие атрибуты игнорируют. Полный список
и таблица соответствий XSD ↔ XDTO — в [xsd-reference.md](xsd-reference.md).

Свойства объекта метаданных можно задать прямо в схеме:

```xml
<xs:annotation>
    <xs:appinfo>
        <xdto:package xmlns:xdto="http://v8.1c.ru/8.1/xdto">
            <xdto:name>ОбменСБанком</xdto:name>
            <xdto:synonym lang="ru">Обмен с банком</xdto:synonym>
        </xdto:package>
    </xs:appinfo>
</xs:annotation>
```

## Типичный workflow

1. Получить XSD от контрагента (или выгрузить схему существующего пакета: `/xdto-decompile`)
2. `/xdto-compile -XsdPath <файл> -OutputDir <каталог-исходников>` — прочитать предупреждения
3. `/xdto-validate` — убедиться, что типы разрешились
4. `/db-load-xml` + `/db-update`

Правка существующего пакета: `/xdto-decompile` → правка XSD → `/xdto-compile -Force`.

## Верификация

```
/xdto-validate <каталог-исходников>/XDTOPackages/<Имя>
```
