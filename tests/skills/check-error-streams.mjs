#!/usr/bin/env node
// Инвариант: сообщения об ошибках уходят в ОДИН И ТОТ ЖЕ поток в обоих портах навыка.
//
// Соответствие задано в docs/python-porting-guide.md: `Write-Host` → `print`,
// `Write-Error` → `print(..., file=sys.stderr)`. Тринадцать навыков группы db-*/epf-*/web-*
// его нарушали: PS писал ошибки через Write-Host (stdout), а py-порт — в stderr. Счётчики
// совпадали один в один (14↔14, 19↔19, 13↔13) — то есть сообщения были те же, разъехался
// только поток.
//
// Почему это не косметика: харнесс не чередует потоки, а группирует — сначала весь stderr,
// потом весь stdout. Из-за этого в py-порте вердикт «Error dumping configuration (code: 1)»
// печатался ПЕРЕД строками, которые его объясняют, а причина из лога платформы оказывалась
// в самом низу. Причинный порядок вывода переворачивался, и порт для macOS читался хуже
// того, что работает на Windows.
//
// Почему не ловилось тестами: текст ошибки сверяют только кейсы со строковым `expectError`,
// а он смотрит в stderr — поэтому такие кейсы есть лишь у семейства, где потоки сходятся.
// В db-* их ноль, и дыра пряталась за собственным следствием.
//
// Запуск: node tests/skills/check-error-streams.mjs
import { readFileSync, readdirSync, existsSync } from 'node:fs';
import { fileURLToPath } from 'node:url';
import { dirname, join } from 'node:path';

const ROOT = join(dirname(fileURLToPath(import.meta.url)), '..', '..');
const SKILLS = join(ROOT, '.claude', 'skills');

const errors = [];
let checked = 0;

for (const skill of readdirSync(SKILLS)) {
  const dir = join(SKILLS, skill, 'scripts');
  if (!existsSync(dir)) continue;
  for (const file of readdirSync(dir)) {
    if (!file.endsWith('.ps1')) continue;
    const base = file.slice(0, -4);
    const pyPath = join(dir, base + '.py');
    if (!existsSync(pyPath)) continue;

    // Форм записи в stderr по две с каждой стороны, и считать надо обе: PS пишет через
    // Write-Error и через [Console]::Error.WriteLine, py — через file=sys.stderr и
    // sys.stderr.write. Комментарии выбрасываем: в meta-remove.ps1 слово Write-Error стоит
    // в пояснении «почему НЕ Write-Error», и по одной форме гард давал ложную тревогу.
    const strip = (text, marker) => text.split('\n')
      .filter(l => !l.trimStart().startsWith(marker)).join('\n');
    const ps = strip(readFileSync(join(dir, file), 'utf8').replace(/^﻿/, ''), '#');
    const py = strip(readFileSync(pyPath, 'utf8'), '#');
    const psErr = (ps.match(/Write-Error|Console\]::Error\.Write/g) || []).length;
    const pyErr = (py.match(/file=sys\.stderr|sys\.stderr\.write/g) || []).length;
    checked++;

    if (psErr === 0 && pyErr > 0) {
      errors.push(`${skill}/${base}: PS не использует Write-Error, а py пишет в stderr `
        + `(${pyErr} мест). Ошибки должны идти в тот же поток, что и в PS — убрать file=sys.stderr.`);
    }
    if (psErr > 0 && pyErr === 0) {
      errors.push(`${skill}/${base}: PS использует Write-Error (${psErr} мест), а py пишет всё `
        + `в stdout. Ошибки должны идти в тот же поток — добавить file=sys.stderr.`);
    }
  }
}

console.log(`Проверено пар портов: ${checked}`);
if (errors.length === 0) {
  console.log('OK — потоки сообщений об ошибках совпадают в обоих портах.');
  process.exit(0);
}
console.log(`\n${errors.length} РАСХОЖДЕНИЙ:`);
for (const e of errors) console.log(`  [ERROR] ${e}`);
console.log('\nСоответствие потоков: docs/python-porting-guide.md, таблица маппинга PS → Python.');
process.exit(1);
