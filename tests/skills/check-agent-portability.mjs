#!/usr/bin/env node
// Инвариант: исходники навыков не привязаны к конкретному AI-агенту. Единственная разрешённая
// форма упоминания — плейсхолдер `${CLAUDE_SKILL_DIR}/`, который scripts/switch.py разворачивает
// в префикс целевой платформы (.codex/skills, .cursor/skills и т.д.).
//
// Без этого навык уезжает на другую платформу с битым путём: `.claude/skills/meta-edit/...`,
// зашитый литералом в json-dsl.md, указывал в несуществующий каталог, а команда молча не
// находила скрипт. Прозаические «Claude описывает...» туда же — на Codex это дезинформация.
// Снапшот-тесты этого не видят: они сверяют вывод скриптов, а не переносимость текстов.
//
// Проверка: во всех текстовых файлах .claude/skills/** (кроме node_modules и __pycache__)
// после вырезания `${CLAUDE_SKILL_DIR}/` не должно остаться ни одного вхождения `claude`
// в любом регистре. Это ловит и литеральные пути, и прозу, и плейсхолдер без завершающего
// слеша — switch.py разворачивает только форму со слешем, остальные проедут насквозь.
// Выход 1 при нарушении. Запуск: node tests/skills/check-agent-portability.mjs
import { readFileSync, readdirSync } from 'node:fs';
import { fileURLToPath } from 'node:url';
import { dirname, join, relative, sep } from 'node:path';

const ROOT = join(dirname(fileURLToPath(import.meta.url)), '..', '..');
const SKILLS_DIR = join(ROOT, '.claude', 'skills');

// node_modules — сторонний код (playwright содержит ClaudeGenerator и `.claude/agents`),
// переписывать его нельзя и незачем: на переносимость навыка он не влияет.
const SKIP_DIRS = new Set(['node_modules', '__pycache__', '.git']);

// Разрешённая форма — ровно та, которую разворачивает rewrite_paths() в switch.py.
const ALLOWED = '${CLAUDE_SKILL_DIR}/';

function walk(dir, out = []) {
  for (const entry of readdirSync(dir, { withFileTypes: true }).sort((a, b) => a.name.localeCompare(b.name))) {
    const full = join(dir, entry.name);
    if (entry.isDirectory()) {
      if (!SKIP_DIRS.has(entry.name)) walk(full, out);
    } else if (entry.isFile()) {
      out.push(full);
    }
  }
  return out;
}

const files = walk(SKILLS_DIR);
if (files.length === 0) {
  console.error(`Не найдено ни одного файла в ${SKILLS_DIR} — гард потерял цель.`);
  process.exit(1);
}

const violations = [];
let scanned = 0;
let allowedHits = 0;

for (const file of files) {
  const buf = readFileSync(file);
  // Бинарники (иконки, .bin, .cf) пропускаем: NUL-байт — надёжный признак, ловить в них
  // подстроку бессмысленно.
  if (buf.includes(0)) continue;
  const text = buf.toString('utf8');
  scanned++;

  const before = text.split(ALLOWED).length - 1;
  allowedHits += before;
  const stripped = text.split(ALLOWED).join('');
  if (!/claude/i.test(stripped)) continue;

  const rel = relative(ROOT, file).split(sep).join('/');
  stripped.split('\n').forEach((line, i) => {
    if (!/claude/i.test(line)) return;
    // Номер строки считаем по очищенному тексту: вырезается подстрока, а не строка целиком,
    // поэтому нумерация совпадает с исходным файлом.
    violations.push(`${rel}:${i + 1}: ${line.trim()}`);
  });
}

if (violations.length) {
  console.error(`Нарушений: ${violations.length}\n`);
  for (const v of violations) console.error(`  ${v}`);
  console.error(`\nПуть к скрипту навыка пишется как ${ALLOWED}scripts/<имя>.<ext>;`);
  console.error('название агента в текстах навыка не упоминается.');
  process.exit(1);
}

console.log(`OK — ${scanned} текстовых файлов, ${allowedHits} вхождений ${ALLOWED}.`);
console.log('Привязки к конкретному AI-агенту в исходниках навыков нет.');
