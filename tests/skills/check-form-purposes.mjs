#!/usr/bin/env node
// Анти-дрейф таблицы назначений форм в form-add.
//
// Знание «какие формы бывают у вида объекта» раньше было размазано по четырём независимым
// спискам внутри form-add (supportedTypes, objectLikeTypes, processorLikeTypes, attrTypeMap) плюс
// switch по свойствам DefaultForm. Списки разошлись молча: DocumentJournal попал в поддерживаемые,
// но не в карту типов, и в форму уходило `cfg:.Журнал` — платформа такую выгрузку не принимает
// («Исключение XDTO при чтении файла»), а навык рапортовал успех.
//
// Эталон — таблицы «Свойства DefaultForm по типам объектов» и «Главный реквизит формы по
// назначению» из docs/1c-form-spec.md. Берём документацию, а не отдельный JSON: тогда спека и код
// не расходятся молча.
//
// Держит три инварианта:
//   1. Каждый вид из таблицы видов form-add объявлен в спецификации, и наоборот.
//   2. Свойство «основная форма» у назначения совпадает со спекой (журналу — DefaultForm, а не
//      DefaultListForm, которого у него нет).
//   3. Таблицы PS и PY совпадают между собой: вид, набор назначений, тип главного реквизита, слот.
//
// Запуск: node tests/skills/check-form-purposes.mjs [--list]
// Выход 1 при ERROR.
import { readFileSync, existsSync } from 'node:fs';
import { fileURLToPath } from 'node:url';
import { dirname, join } from 'node:path';

const ROOT = join(dirname(fileURLToPath(import.meta.url)), '..', '..');
const SKILLS = join(ROOT, '.claude', 'skills');
const SPEC = join(ROOT, 'docs', '1c-form-spec.md');

const errors = [];
const listMode = process.argv.includes('--list');

function read(path) {
  return existsSync(path) ? readFileSync(path, 'utf8') : null;
}

// ─── Эталон: таблица слотов из спецификации ─────────────────────────────────
// Строки вида: | DocumentJournal | DefaultForm |
function parseSpecSlots(text) {
  const map = new Map();
  const section = text.split(/^#### Свойства DefaultForm по типам объектов$/m)[1];
  if (!section) {
    errors.push('spec: не найдена таблица «Свойства DefaultForm по типам объектов»');
    return map;
  }
  const body = section.split(/^#### /m)[0];
  for (const line of body.split('\n')) {
    const m = /^\|\s*([A-Za-z*]+)\s*\|\s*([^|]+?)\s*\|/.exec(line);
    if (!m) continue;
    const kind = m[1];
    if (kind === 'Тип' || /^-+$/.test(kind)) continue;
    const slots = m[2].split(',').map(s => s.trim()).filter(s => /^Default\w+$/.test(s));
    map.set(kind, new Set(slots));
  }
  return map;
}

// ─── Таблица видов из скрипта навыка ────────────────────────────────────────
// Таблица плоская по устройству: одна строка на (вид, назначение). Разбор поэтому тривиален —
// если он вдруг усложняется, это признак, что таблицу в навыке перестали писать явно.
function parseSkillTable(text, port) {
  const isPs = port === 'ps';
  const table = new Map();
  const tableRe = isPs
    ? /^\$formKinds\s*=\s*@\{([\s\S]*?)^\}/m
    : /^    form_kinds\s*=\s*\{([\s\S]*?)^    \}/m;
  const tm = tableRe.exec(text);
  if (!tm) {
    errors.push(`${port}: не найдена таблица видов form-add`);
    return table;
  }
  const kindRe = isPs
    ? /^	"(\w+)" = @\{\n([\s\S]*?)^	\}/gm
    : /^        "(\w+)": \{\n([\s\S]*?)^        \},/gm;
  const ruleRe = isPs
    ? /"(\w+)"\s*=\s*@\{ MainAttr = (\$null|"[^"]*"); AttrName = (?:\$null|"[^"]*"); Slot = (\$null|"[^"]*")/g
    : /"(\w+)": \{"main_attr": (None|"[^"]*"), "attr_name": (?:None|"[^"]*"),\s*"slot": (None|"[^"]*")/g;

  for (const km of tm[1].matchAll(kindRe)) {
    const rules = new Map();
    ruleRe.lastIndex = 0;
    for (const rm of km[2].matchAll(ruleRe)) {
      const unq = (v) => (v === '$null' || v === 'None') ? null : v.slice(1, -1);
      rules.set(rm[1], { mainAttr: unq(rm[2]), slot: unq(rm[3]) });
    }
    if (rules.size === 0) errors.push(`${port}: у вида ${km[1]} не разобрано ни одного назначения`);
    table.set(km[1], rules);
  }
  return table;
}

// ─── Проверки ───────────────────────────────────────────────────────────────
const psText = read(join(SKILLS, 'form-add', 'scripts', 'form-add.ps1'));
const pyText = read(join(SKILLS, 'form-add', 'scripts', 'form-add.py'));
const specText = read(SPEC);
if (!psText || !pyText || !specText) {
  console.error('[ERROR] не найдены исходники form-add или спецификация');
  process.exit(1);
}

const specSlots = parseSpecSlots(specText);
const psTable = parseSkillTable(psText, 'ps');
const pyTable = parseSkillTable(pyText, 'py');

// 1. Состав видов: код ↔ спека. Виды без собственных форм в таблице не участвуют.
const noOwnForms = new Set(['Constant', 'CommonForm']);
for (const kind of psTable.keys()) {
  if (!specSlots.has(kind)) errors.push(`spec: вид ${kind} есть в form-add, но не описан в 1c-form-spec.md`);
}
for (const kind of specSlots.keys()) {
  if (noOwnForms.has(kind) || kind.includes('*')) continue;
  if (!psTable.has(kind)) errors.push(`form-add: вид ${kind} описан в спецификации, но не поддержан`);
}

// 2. Слоты: каждый непустой слот назначения обязан быть у вида в спеке.
for (const [kind, rules] of psTable) {
  const allowed = specSlots.get(kind);
  if (!allowed) continue;
  for (const [purpose, rule] of rules) {
    if (!rule.slot) continue;
    if (!allowed.has(rule.slot)) {
      errors.push(`form-add: ${kind}/${purpose} пишет ${rule.slot}, которого у вида нет по спецификации `
        + `(есть: ${[...allowed].join(', ') || 'нет'})`);
    }
  }
}

// 3. Паритет портов.
for (const kind of new Set([...psTable.keys(), ...pyTable.keys()])) {
  const a = psTable.get(kind);
  const b = pyTable.get(kind);
  if (!a || !b) { errors.push(`паритет: вид ${kind} есть только в ${a ? 'PS' : 'PY'}`); continue; }
  const purposes = new Set([...a.keys(), ...b.keys()]);
  for (const p of purposes) {
    const ra = a.get(p);
    const rb = b.get(p);
    if (!ra || !rb) { errors.push(`паритет: ${kind}/${p} есть только в ${ra ? 'PS' : 'PY'}`); continue; }
    if ((ra.slot || null) !== (rb.slot || null)) {
      errors.push(`паритет: ${kind}/${p} слот PS=${ra.slot} PY=${rb.slot}`);
    }
    const norm = (v) => (v || '').replace(/\{0\}|\{1\}/g, '');
    if (norm(ra.mainAttr) !== norm(rb.mainAttr)) {
      errors.push(`паритет: ${kind}/${p} главный реквизит PS=${ra.mainAttr} PY=${rb.mainAttr}`);
    }
  }
}

if (listMode) {
  console.log('Таблица назначений form-add (PS):');
  for (const kind of [...psTable.keys()].sort()) {
    const rules = psTable.get(kind);
    const parts = [...rules.entries()].sort().map(([p, r]) => `${p}→${r.slot || '—'}`);
    console.log(`  ${kind.padEnd(28)} ${parts.join(', ')}`);
  }
  console.log('');
}

if (errors.length) {
  for (const e of errors) console.error(`[ERROR] ${e}`);
  console.error(`\ncheck-form-purposes: ${errors.length} расхождений`);
  process.exit(1);
}
console.log(`check-form-purposes: OK (${psTable.size} видов, спека и оба порта сходятся)`);
