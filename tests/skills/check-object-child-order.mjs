#!/usr/bin/env node
// Анти-дрейф канона групп в <ChildObjects> ОБЪЕКТА (issue #123).
//
// Порядок групп детей у объекта зависит от вида (у документа Form стоит до TabularSection, у
// справочника — после) и равен xs:sequence <Вид>ChildObjects из MDClasses XSD — это сверено
// раундтрипом через базу. Навыки, вставляющие в ChildObjects объекта, берут место из одной таблицы
// (object_child_order / Get-ObjectChildOrder); совпадение её копий между навыками держит
// check-inline-drift. Здесь — то, чего тот гард не видит:
//   1. Таблица эталона (meta-edit) одинакова в py- и ps1-порте.
//   2. Таблица = таблица «Порядок групп в ChildObjects объекта» из docs/1c-config-objects-spec.md.
//   3. Если XSD скачаны (.v8-xsd/ в .gitignore, ставит v8-xsd-fetch) — спека = xs:sequence
//      последней версии формата. Нет схем — шаг пропускается с сообщением.
//
// Запуск: node tests/skills/check-object-child-order.mjs
// Выход 1 при ERROR.
import { readFileSync, existsSync, readdirSync } from 'node:fs';
import { fileURLToPath } from 'node:url';
import { dirname, join } from 'node:path';

const ROOT = join(dirname(fileURLToPath(import.meta.url)), '..', '..');
const AUTH = join(ROOT, '.claude', 'skills', 'meta-edit', 'scripts', 'meta-edit');
const SPEC = join(ROOT, 'docs', '1c-config-objects-spec.md');
const XSD_DIR = join(ROOT, '.v8-xsd');

const errors = [];
const read = p => readFileSync(p, 'utf8').replace(/^﻿/, '');
const fmt = m => [...m.entries()].map(([k, v]) => `${k}: ${v.join(' ')}`);

function compare(aName, a, bName, b) {
  for (const [k, v] of a) {
    if (!b.has(k)) errors.push(`${k}: есть в ${aName}, нет в ${bName}`);
    else if (b.get(k).join(' ') !== v.join(' '))
      errors.push(`${k}: ${aName} «${v.join(' ')}» ≠ ${bName} «${b.get(k).join(' ')}»`);
  }
  for (const k of b.keys()) if (!a.has(k)) errors.push(`${k}: есть в ${bName}, нет в ${aName}`);
}

// Тело функции эталона: от объявления до первой строки с закрытием на нулевом отступе
function fnBody(text, startRx) {
  const m = startRx.exec(text);
  if (!m) return null;
  const rest = text.slice(m.index);
  const end = rest.search(/\n(?=\S)/);
  return end < 0 ? rest : rest.slice(0, end);
}

function parseTable(body, pairRx) {
  const map = new Map();
  for (const m of body.matchAll(pairRx)) map.set(m[1], [...m[2].matchAll(/"(\w+)"/g)].map(x => x[1]));
  return map;
}

const pyBody = fnBody(read(AUTH + '.py'), /^def object_child_order\(\):/m);
const psBody = fnBody(read(AUTH + '.ps1'), /^function Get-ObjectChildOrder \{/m);
if (!pyBody || !psBody) {
  console.error('[ERROR] эталон не найден: object_child_order / Get-ObjectChildOrder в meta-edit (реестр протух)');
  process.exit(1);
}
const py = parseTable(pyBody, /"(\w+)":\s*\[([^\]]*)\]/g);
const ps = parseTable(psBody, /"(\w+)"\s*=\s*@\(([^)]*)\)/g);

// Спека: строки таблицы вида | `Kind` ... | `A B C` ... |
const specText = read(SPEC);
const sec = specText.indexOf('#### Порядок групп в ChildObjects объекта');
const spec = new Map();
if (sec >= 0) {
  const tail = specText.slice(sec).split('\n').slice(1);
  for (const line of tail) {
    if (/^#{2,4} /.test(line)) break;
    const m = /^\|\s*`(\w+)`[^|]*\|\s*`([\w ]+)`/.exec(line);
    if (m) spec.set(m[1], m[2].trim().split(/\s+/));
  }
}
if (spec.size < 20) {
  console.error(`[ERROR] таблица «Порядок групп в ChildObjects объекта» в спеке не найдена или неполна (${spec.size} строк)`);
  process.exit(1);
}

compare('meta-edit.py', py, 'meta-edit.ps1', ps);
compare('meta-edit.py', py, 'спека', spec);

// XSD: последняя версия формата из .v8-xsd/<ver>/
let xsdNote = 'XSD не скачаны (.v8-xsd/) — сверка со схемой пропущена';
if (existsSync(XSD_DIR)) {
  const vers = readdirSync(XSD_DIR).filter(d => /^\d+\.\d+$/.test(d) && existsSync(join(XSD_DIR, d, 'v8.1c.ru-8.3-MDClasses.xsd')))
    .sort((a, b) => a.split('.').map(Number).reduce((s, x, i) => s || x - b.split('.').map(Number)[i], 0));
  if (vers.length) {
    const ver = vers[vers.length - 1];
    const xsd = read(join(XSD_DIR, ver, 'v8.1c.ru-8.3-MDClasses.xsd'));
    const xmap = new Map();
    for (const m of xsd.matchAll(/<xs:complexType name="(\w+)ChildObjects">([\s\S]*?)<\/xs:complexType>/g))
      xmap.set(m[1], [...m[2].matchAll(/<xs:element name="(\w+)"/g)].map(x => x[1]));
    for (const [k, v] of spec) {
      if (!xmap.has(k)) errors.push(`${k}: нет типа ${k}ChildObjects в XSD ${ver}`);
      else if (xmap.get(k).join(' ') !== v.join(' '))
        errors.push(`${k}: спека «${v.join(' ')}» ≠ XSD ${ver} «${xmap.get(k).join(' ')}»`);
    }
    xsdNote = `XSD ${ver}: ${spec.size} видов сверены`;
  }
}

if (process.argv.includes('--list')) for (const l of fmt(py)) console.log('  ' + l);
for (const e of errors) console.error(`[ERROR] ${e}`);
console.log(`[${errors.length ? 'FAIL' : 'OK'}] канон групп ChildObjects объекта: ${py.size} видов; ${xsdNote}`);
process.exit(errors.length ? 1 : 0);
