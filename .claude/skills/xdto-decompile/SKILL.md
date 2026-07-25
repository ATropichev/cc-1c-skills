---
name: xdto-decompile
description: Выгрузка пакета XDTO 1С в XML-схему (XSD). Используй когда нужно прочитать или отредактировать существующий пакет XDTO, отдать схему контрагенту, перенести пакет между конфигурациями
argument-hint: <PackagePath> [-OutFile <файл.xsd>]
allowed-tools:
  - Bash
  - Read
  - Glob
---

# /xdto-decompile — Выгрузка пакета XDTO в XML-схему

Превращает `Ext/Package.bin` в обычную XML-схему. Заменяет чтение модели XDTO с её
инвертированной кратностью, фасетами-атрибутами и локальными объявлениями префиксов
`dNpM` на каждой ссылке.

## Параметры

| Параметр | Описание |
|----------|----------|
| `PackagePath` | Каталог пакета, путь к `Ext/Package.bin` или к `<Имя>.xml` объекта метаданных |
| `OutFile` | Записать схему в файл (UTF-8 BOM). Без него — вывод в stdout |

```powershell
powershell.exe -NoProfile -File "${CLAUDE_SKILL_DIR}/scripts/xdto-decompile.ps1" -PackagePath "<путь>"
```

Примеры:
```powershell
... -PackagePath C:\cfsrc\erp\XDTOPackages\ClientBankExchange
... -PackagePath C:\cfsrc\erp\XDTOPackages\ClientBankExchange -OutFile bank.xsd
```

## Round-trip

`/xdto-decompile` → правка XSD → `/xdto-compile -Force` возвращает исходный `Package.bin`
байт-в-байт. Инвариант проверен на 760 пакетах выгрузок Бухгалтерии и ERP.

Это основной способ править существующий пакет: точечных операций не требуется, схема
целиком читаема и редактируема.

Свойства объекта метаданных (`Name`, `Synonym`, `Comment`) выгружаются в
`xs:annotation/xs:appinfo`, поэтому при обратной сборке не теряются. `Namespace` не
дублируется — его несёт `targetNamespace`.

## Отличия от экспорта XML-схемы в Конфигураторе

Штатный экспорт Конфигуратора теряет данные: `nillable` у свойств-атрибутов
(спецификация XSD не допускает его у атрибутов), а для пакетов с
`elementFormQualified="false"` выдаёт невалидную схему — `form="qualified"` на
глобальных объявлениях.

Навык пишет валидную схему, а то, что XSD выразить не может, выносит в атрибуты
пространства имён модели XDTO:

```xml
<xs:attribute name="Представление" type="xs:string" xdto:nillable="true"/>
```

Такие атрибуты валидаторы игнорируют, а `/xdto-compile` читает обратно. Схему без
потерь можно отдавать контрагенту как есть.

## Верификация

```
/xdto-decompile <путь>                       — схема в stdout
/xdto-decompile <путь> -OutFile schema.xsd   — в файл
```
