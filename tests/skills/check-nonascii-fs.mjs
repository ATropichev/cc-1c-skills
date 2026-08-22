#!/usr/bin/env node
// Гард хелпера tests/common/fsutil.mjs: удаление и копирование обязаны работать, когда в пути
// есть не-ASCII символы. На Windows fs.rmSync/fs.cpSync в такой ситуации МОЛЧА не делают ничего
// (nodejs/node#61067) — снапшот-тесты этого не ловят, они видят лишь последствия: «фикстура не
// доехала», «эталон не обновился», утёкшие воркспейсы.
//
// Гард проверяет НАШ хелпер, а не платформу, поэтому зелёный и на исправной сборке Node —
// именно это защищает его от гниения. Состояние самой платформы печатается справочно.
//
// Ловушка при доработке: cpSync из не-ASCII ИСТОЧНИКА на сломанных сборках валит процесс
// нативно (0xC0000409) мимо try/catch. Пробовать платформу этим вариантом нельзя — только
// тихими (rmSync и cpSync в не-ASCII приёмник).
//
// Выход 1 при нарушении. Запуск: node tests/skills/check-nonascii-fs.mjs
import { cpSync, existsSync, mkdirSync, mkdtempSync, readFileSync, readdirSync,
         rmdirSync, rmSync, unlinkSync, writeFileSync } from 'node:fs';
import { createHash } from 'node:crypto';
import { fileURLToPath } from 'node:url';
import { dirname, join } from 'node:path';
import { tmpdir } from 'node:os';

const ROOT = join(dirname(fileURLToPath(import.meta.url)), '..', '..');
const IS_WIN = process.platform === 'win32';

// Ручной обход исполняется только на не-ASCII путях, а на macOS/Linux их не бывает по природе
// гарда. Шов включает обход на любой ОС — иначе половина кода была бы покрыта только на Windows.
process.env.CC1C_FSUTIL_FORCE_WALK = '1';
const { removePathSync, copyTreeSync } = await import('../common/fsutil.mjs');

let failures = 0;
const fail = (msg) => { console.log(`  x ${msg}`); failures++; };
const pass = (msg) => console.log(`  + ${msg}`);
const check = (cond, msg) => cond ? pass(msg) : fail(msg);

// Уборка сознательно НЕ через хелпер: он здесь подопытный, его отказ не должен маскироваться.
function nuke(p) {
  if (!existsSync(p)) return;
  for (const e of readdirSync(p, { withFileTypes: true })) {
    const c = join(p, e.name);
    if (e.isDirectory()) nuke(c); else { try { unlinkSync(c); } catch { rmdirSync(c); } }
  }
  rmdirSync(p);
}

const ROOTDIR = mkdtempSync(join(tmpdir(), 'nonascii-fs-'));
const CYR = join(ROOTDIR, 'Каталог Ы');
mkdirSync(CYR, { recursive: true });
const cwd0 = process.cwd();

// --- 1. Предикат -----------------------------------------------------------
console.log('\nПредикат pathIsUnsafe');
{
  delete process.env.CC1C_FSUTIL_FORCE_WALK;
  const mod = await import('../common/fsutil.mjs?noseam=1');
  process.chdir(CYR);
  // Главная ловушка: относительный ASCII-аргумент при не-ASCII cwd платформа роняет так же
  // молча, поэтому судить по строке аргумента нельзя — только по разрешённому пути.
  check(mod.pathIsUnsafe('жертва') === IS_WIN, 'не-ASCII в самом аргументе');
  check(mod.pathIsUnsafe('victim') === IS_WIN, 'относительный ASCII-аргумент при не-ASCII cwd');
  process.chdir(cwd0);
  check(mod.pathIsUnsafe(join(ROOTDIR, 'plain')) === false, 'полностью ASCII-путь — быстрый путь');
  process.env.CC1C_FSUTIL_FORCE_WALK = '1';
}

// --- 2. removePathSync -----------------------------------------------------
console.log('\nremovePathSync');
{
  removePathSync(join(CYR, 'нет-такого'));
  pass('отсутствующий путь — не ошибка (семантика force)');

  const f = join(CYR, 'Файл.txt');
  writeFileSync(f, 'x');
  removePathSync(f);
  check(!existsSync(f), 'одиночный файл');

  const tree = join(CYR, 'Дерево');
  mkdirSync(join(tree, 'Вложенный', 'Глубже'), { recursive: true });
  writeFileSync(join(tree, 'Вложенный', 'Данные.xml'), 'x');
  writeFileSync(join(tree, 'Вложенный', 'Глубже', 'plain.txt'), 'x');
  removePathSync(tree);
  check(!existsSync(tree), 'вложенное дерево с не-ASCII именами');

  const rel = join(CYR, 'Отн');
  mkdirSync(join(rel, 'victim'), { recursive: true });
  writeFileSync(join(rel, 'victim', 'f.txt'), 'x');
  process.chdir(rel);
  removePathSync('victim');
  process.chdir(cwd0);
  check(!existsSync(join(rel, 'victim')), 'относительный ASCII-аргумент при не-ASCII cwd');

  // Ретраи обязаны дожить до ручного обхода: если они теряются, под не-ASCII %TEMP%
  // воркспейсы утекают ровно так же, как без гарда вообще.
  if (IS_WIN) {
    const busy = join(CYR, 'Занятый');
    mkdirSync(busy, { recursive: true });
    process.chdir(busy);          // rmdir собственного cwd на Windows даёт EBUSY детерминированно
    const t0 = Date.now();
    let threw = false;
    try { removePathSync(busy, { maxRetries: 3, retryDelay: 40 }); } catch { threw = true; }
    const spent = Date.now() - t0;
    process.chdir(cwd0);
    check(threw, 'занятый каталог — отказ громкий, не тихий');
    check(spent >= 120, `ретраи дожили до ручного обхода (ждали >=120 мс, потрачено ${spent} мс)`);
    rmdirSync(busy);
  } else {
    console.log('  o ретраи: пропуск — детерминированный EBUSY есть только на Windows');
  }
}

// --- 3. copyTreeSync -------------------------------------------------------
console.log('\ncopyTreeSync');
{
  const src = join(CYR, 'Источник');
  mkdirSync(join(src, 'Languages'), { recursive: true });
  writeFileSync(join(src, 'Languages', 'Русский.xml'), 'RU');
  writeFileSync(join(src, 'Configuration.xml'), 'CFG');

  const dst = join(CYR, 'Приёмник');
  copyTreeSync(src, dst);
  check(readFileSync(join(dst, 'Configuration.xml'), 'utf8') === 'CFG'
     && readFileSync(join(dst, 'Languages', 'Русский.xml'), 'utf8') === 'RU',
    'копия из не-ASCII источника в не-ASCII приёмник');

  // Семантика cpSync — force: true. Обход, который не перезатирает, ломает её незаметно.
  writeFileSync(join(dst, 'Configuration.xml'), 'СТАРОЕ');
  copyTreeSync(src, dst);
  check(readFileSync(join(dst, 'Configuration.xml'), 'utf8') === 'CFG',
    'существующий файл перезаписывается (как cpSync с force: true)');

  // Настоящая ошибка обязана долететь до вызывающего, а не раствориться в обходе.
  let threw = false;
  try { copyTreeSync(join(CYR, 'нет-источника'), join(CYR, 'куда')); } catch { threw = true; }
  check(threw, 'отсутствующий источник — ошибка не проглочена');
}

// --- 4. Анти-дрейф копий ---------------------------------------------------
console.log('\nКопии fsutil совпадают');
{
  const COPIES = [
    'tests/common/fsutil.mjs',
    '.claude/skills/web-test/scripts/engine/core/fsutil.mjs',
  ];
  const MARKER = '// ─── fsutil:begin';
  const hashes = COPIES.map((rel) => {
    const text = readFileSync(join(ROOT, rel), 'utf8');
    const at = text.indexOf(MARKER);
    if (at < 0) { fail(`${rel}: нет маркера «${MARKER}»`); return null; }
    return createHash('sha256').update(text.slice(at)).digest('hex');
  });
  if (hashes.every(Boolean)) {
    const same = new Set(hashes).size === 1;
    check(same, `тело ниже маркера идентично в ${COPIES.length} копиях (${hashes[0].slice(0, 12)})`);
    if (!same) COPIES.forEach((c, i) => console.log(`      ${hashes[i].slice(0, 12)}  ${c}`));
  }
}

// --- 5. Справка о самой платформе ------------------------------------------
// Только тихие варианты. cpSync из не-ASCII источника не трогаем — он валит процесс.
console.log('\nСостояние этой сборки Node (справочно, на вердикт не влияет)');
{
  const probe = join(CYR, 'Проба');
  mkdirSync(probe, { recursive: true });
  writeFileSync(join(probe, 'f.txt'), 'x');
  let rmBroken = false;
  let cpBroken = false;
  try { rmSync(join(probe, 'f.txt'), { force: true }); rmBroken = existsSync(join(probe, 'f.txt')); } catch {}
  const asciiSrc = join(ROOTDIR, 'ascii-src');
  mkdirSync(asciiSrc, { recursive: true });
  writeFileSync(join(asciiSrc, 'f.txt'), 'x');
  const cyrDst = join(CYR, 'Проба-приёмник');
  try { cpSync(asciiSrc, cyrDst, { recursive: true }); cpBroken = !existsSync(join(cyrDst, 'f.txt')); }
  catch { cpBroken = true; }
  const verdict = rmBroken || cpBroken
    ? `ЗАТРОНУТА (rmSync: ${rmBroken ? 'молчит' : 'ок'}, cpSync: ${cpBroken ? 'молчит' : 'ок'}) — гард здесь несёт нагрузку`
    : 'чистая — гард работает вхолостую, и это нормально';
  console.log(`  ${process.version} на ${process.platform}: ${verdict}`);
}

nuke(ROOTDIR);

console.log('');
if (failures) console.log(`${failures} НАРУШЕНИЙ: хелпер не держит не-ASCII пути.`);
else console.log('OK — fsutil держит не-ASCII пути, копии не разошлись');
process.exit(failures ? 1 : 0);
