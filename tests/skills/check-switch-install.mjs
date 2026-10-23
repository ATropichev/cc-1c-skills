#!/usr/bin/env node
// Гард scripts/switch.py (#129): установка, обновление и --undo трогают только навыки набора.
// Сторонние навыки в том же каталоге (свои навыки пользователя, системный .system у Codex)
// и пользовательский .gitignore должны пережить повторную установку и удаление.
// Признак «наше» — манифест .cc-1c-skills.json в целевом каталоге плюс состав текущей версии.
//
// Выход 1 при нарушении. Запуск: node tests/skills/check-switch-install.mjs
import { cpSync, existsSync, lstatSync, mkdirSync, mkdtempSync, readFileSync, readdirSync, rmdirSync,
         rmSync, unlinkSync, writeFileSync } from 'node:fs';
import { spawnSync } from 'node:child_process';
import { fileURLToPath } from 'node:url';
import { dirname, join } from 'node:path';
import { tmpdir } from 'node:os';

const ROOT = join(dirname(fileURLToPath(import.meta.url)), '..', '..');
const IS_WIN = process.platform === 'win32';
const PY = process.env.PYTHON || (IS_WIN ? 'python' : 'python3');
const SWITCH = join(ROOT, 'scripts', 'switch.py');
const SRC_SKILLS = join(ROOT, '.claude', 'skills');
const MANIFEST = '.cc-1c-skills.json';

let failures = 0;
const fail = (msg) => { console.log(`  x ${msg}`); failures++; };
const pass = (msg) => console.log(`  + ${msg}`);
const check = (cond, msg) => cond ? pass(msg) : fail(msg);

const ourSkills = readdirSync(SRC_SKILLS, { withFileTypes: true })
  .filter(e => e.isDirectory() && existsSync(join(SRC_SKILLS, e.name, 'SKILL.md')))
  .map(e => e.name).sort();

// cwd по умолчанию — песочница, а не репозиторий: путь вида «C:» на Windows указывает на текущий
// каталог, и сломанная защита манифеста снесла бы его
let SANDBOX;
function run(args, { script = SWITCH, cwd = SANDBOX, input, expectFail = false } = {}) {
  const r = spawnSync(PY, [script, ...args], { cwd, input, encoding: 'utf8',
    env: { ...process.env, PYTHONIOENCODING: 'utf-8' } });
  if ((r.status !== 0) !== expectFail) console.log(`    [${args.join(' ')}] exit ${r.status}\n${r.stdout}${r.stderr}`);
  run.last = r;
  return r.status;
}

const put = (p, text = 'x\n') => { mkdirSync(dirname(p), { recursive: true }); writeFileSync(p, text); };
const readManifest = (dir) => JSON.parse(readFileSync(join(dir, MANIFEST), 'utf8'));
const gitignoreLines = (dir) => readFileSync(join(dir, '.gitignore'), 'utf8').split(/\r?\n/).filter(Boolean);
const work = mkdtempSync(join(tmpdir(), 'switch-129-'));
SANDBOX = join(work, 'sandbox');
put(join(SANDBOX, 'canary'));

try {
  // 1. Чужое переживает повторную установку
  console.log('\n1. повторная установка не трогает сторонние навыки');
  const p1 = join(work, 'p1');
  const t1 = join(p1, '.cursor', 'skills');
  put(join(t1, 'my-skill', 'SKILL.md'));
  put(join(t1, '.system', 'x'));
  put(join(t1, '.gitignore'), 'node_modules/\n');
  check(run(['cursor', '--project-dir', p1]) === 0, 'первая установка');
  check(run(['cursor', '--project-dir', p1]) === 0, 'повторная установка');
  check(existsSync(join(t1, 'my-skill', 'SKILL.md')), 'my-skill на месте');
  check(existsSync(join(t1, '.system', 'x')), '.system на месте');
  const m1 = readManifest(t1);
  check(JSON.stringify(m1.skills) === JSON.stringify(ourSkills), 'манифест: skills = состав .claude/skills');
  check(m1.platform === 'cursor' && m1.mode === 'copy' && m1.runtime === 'powershell', 'манифест: platform/mode/runtime');
  const head = spawnSync('git', ['-C', ROOT, 'rev-parse', 'HEAD'], { encoding: 'utf8' });
  if (head.status === 0) check(m1.commit === head.stdout.trim(), 'манифест: commit = HEAD исходного репо');
  const gi = gitignoreLines(t1);
  check(gi.filter(l => l === 'node_modules/').length === 1 && gi.filter(l => l === '__pycache__/').length === 1,
    '.gitignore дописан, строки без дублей');

  // 2. Устаревший навык из манифеста удаляется
  console.log('\n2. навык из манифеста, которого нет в новой версии, удаляется');
  put(join(t1, 'old-skill', 'SKILL.md'));
  writeFileSync(join(t1, MANIFEST), JSON.stringify({ ...m1, skills: [...m1.skills, 'old-skill'] }));
  check(run(['cursor', '--project-dir', p1]) === 0, 'обновление');
  check(!existsSync(join(t1, 'old-skill')), 'old-skill удалён');
  check(existsSync(join(t1, 'my-skill')), 'my-skill на месте');

  // 3. Установка без манифеста (до v1.8): удаляется только пересечение с текущим набором
  console.log('\n3. старая установка без манифеста');
  unlinkSync(join(t1, MANIFEST));
  put(join(t1, 'old-skill', 'SKILL.md'));
  const marker = join(t1, ourSkills[0], 'stale-marker');
  put(marker);
  check(run(['cursor', '--project-dir', p1]) === 0, 'обновление');
  check(existsSync(join(t1, 'old-skill')), 'old-skill не тронут (своим не числится)');
  check(!existsSync(marker), `${ourSkills[0]} переустановлен начисто`);
  check(existsSync(join(t1, MANIFEST)), 'манифест записан');
  rmSync(join(t1, 'old-skill'), { recursive: true });

  // 4. --undo
  console.log('\n4. --undo');
  check(run(['--undo', 'cursor', '--project-dir', p1]) === 0, 'undo рядом с чужими');
  check(ourSkills.every(s => !existsSync(join(t1, s))), 'навыки набора удалены');
  check(!existsSync(join(t1, MANIFEST)), 'манифест удалён');
  check(existsSync(join(t1, 'my-skill')) && existsSync(join(t1, '.system')), 'чужое на месте');
  check(existsSync(join(t1, '.gitignore')) && gitignoreLines(t1).includes('node_modules/'), '.gitignore пользователя на месте');
  const p4 = join(work, 'p4');
  mkdirSync(p4);
  check(run(['cursor', '--project-dir', p4]) === 0 && run(['--undo', 'cursor', '--project-dir', p4]) === 0, 'install + undo в чистом проекте');
  check(!existsSync(join(p4, '.cursor')), '.cursor/ удалён целиком');

  // 5. --link: ссылки снимаются как ссылки, источник цел
  console.log('\n5. --link');
  const p5 = join(work, 'p5');
  const t5 = join(p5, '.claude', 'skills');
  put(join(t5, 'my-skill', 'SKILL.md'));
  check(run(['claude-code', '--project-dir', p5, '--link']) === 0, 'установка ссылками');
  check(run(['claude-code', '--project-dir', p5, '--link']) === 0, 'повторная установка ссылками');
  check(readManifest(t5).mode === 'link' && !('runtime' in readManifest(t5)), 'манифест: mode=link без runtime');
  const srcInfo = readFileSync(join(SRC_SKILLS, 'cf-info', 'SKILL.md'), 'utf8');
  check(run(['--runtime', 'python', '--project-dir', p5], { expectFail: true }) !== 0, 'смена рантайма поверх ссылок — отказ');
  check(readFileSync(join(SRC_SKILLS, 'cf-info', 'SKILL.md'), 'utf8') === srcInfo, 'источник не переписан через ссылку');
  check(run(['--undo', 'claude-code', '--project-dir', p5]) === 0, 'undo');
  check(ourSkills.every(s => existsSync(join(SRC_SKILLS, s, 'SKILL.md'))), 'источник .claude/skills цел');
  check(existsSync(join(t5, 'my-skill', 'SKILL.md')), 'my-skill на месте');
  check(ourSkills.every(s => !existsSync(join(t5, s))), 'ссылки сняты');

  // 6. Источник без своего git: архив, распакованный внутрь чужого git-проекта
  console.log('\n6. источник без git внутри чужого репозитория');
  const outer = join(work, 'outer');
  const src6 = join(outer, 'tools', 'cc');
  cpSync(join(ROOT, 'scripts', 'switch.py'), join(src6, 'scripts', 'switch.py'));
  // node_modules (web-test) для сценария не нужны, а это основной объём
  cpSync(SRC_SKILLS, join(src6, '.claude', 'skills'), { recursive: true, filter: (p) => !/[\\/]node_modules$/.test(p) });
  // autocrlf/safecrlf из глобального конфига могут сорвать add, и у «чужого» репо не будет HEAD
  const git = (...a) => spawnSync('git', ['-c', 'core.autocrlf=false', '-c', 'core.safecrlf=false', '-C', outer, ...a], { encoding: 'utf8' });
  if (git('init', '-q').status === 0) {
    put(join(outer, 'readme.txt'));
    git('add', 'readme.txt');
    git('-c', 'user.name=t', '-c', 'user.email=t@t', 'commit', '-q', '-m', 'init');
    check(git('rev-parse', 'HEAD').status === 0, 'у чужого репозитория есть HEAD');
  }
  const p6 = join(work, 'p6');
  mkdirSync(p6);
  const script6 = join(src6, 'scripts', 'switch.py');
  check(run(['cursor', '--project-dir', p6], { script: script6 }) === 0, 'установка проходит');
  check(!('commit' in readManifest(join(p6, '.cursor', 'skills'))), 'в манифесте нет commit чужого репозитория');

  // 6a. В корне копии источника: рантайм на месте переключает .claude/skills, даже если рядом
  // уже стоит установка с манифестом (.cursor)
  console.log('\n6a. рантайм на месте в источнике при установленном .cursor');
  const srcMd = join(src6, '.claude', 'skills', 'cf-info', 'SKILL.md');
  check(readFileSync(srcMd, 'utf8').includes('powershell.exe'), 'исходник cf-info на PowerShell');
  check(run(['cursor', '--project-dir', src6], { script: script6 }) === 0, 'установка .cursor в источник');
  check(run(['--runtime', 'python', '--project-dir', src6], { script: script6 }) === 0, 'переключение на python');
  check(!readFileSync(srcMd, 'utf8').includes('powershell.exe'), 'переключён .claude/skills, а не .cursor');

  // 6b. Целевой каталог = исходные навыки: интерактивные «Удалить» и «Обновить» отказывают
  console.log('\n6b. интерактивный режим нацелен на сами исходники');
  const before6 = readdirSync(join(src6, '.claude', 'skills')).length;
  // Claude Code → «Установить в проект» → путь по умолчанию (cwd) → «Удалить»
  check(run([], { script: script6, cwd: src6, input: '1\n2\n\n2\n', expectFail: true }) !== 0, '«Удалить» — отказ');
  // ... → «Обновить» → рантайм PowerShell
  check(run([], { script: script6, cwd: src6, input: '1\n2\n\n1\n1\n', expectFail: true }) !== 0, '«Обновить» — отказ');
  check(readdirSync(join(src6, '.claude', 'skills')).length === before6, 'исходные навыки целы');

  // 7. Испорченный манифест не дотягивается за пределы каталога
  console.log('\n7. испорченный манифест');
  const p7 = join(work, 'p7');
  const t7 = join(p7, '.cursor', 'skills');
  put(join(p7, '.cursor', 'victim', 'SKILL.md'));
  put(join(t7, '.system', 'x'));
  put(join(t7, 'my-skill', 'SKILL.md'));
  put(join(t7, MANIFEST), JSON.stringify({ skills: ['../victim', '..', '.', 'C:', 'c:', '.system', 'my-skill.', 'nul', 'con.txt', ourSkills[0]] }));
  check(run(['cursor', '--project-dir', p7]) === 0, 'установка');
  check(existsSync(join(p7, '.cursor', 'victim', 'SKILL.md')), 'victim цел');
  check(existsSync(join(t7, '.system', 'x')), '.system из манифеста не удалён');
  check(existsSync(join(t7, 'my-skill', 'SKILL.md')), '«my-skill.» не дотянулся до my-skill');
  check(existsSync(join(SANDBOX, 'canary')), '«C:» не дотянулся до текущего каталога');
  put(join(t7, MANIFEST), '{ not json');
  check(run(['cursor', '--project-dir', p7]) === 0, 'битый JSON — установка проходит');

  // 8. Рантайм на месте в проекте с манифестом
  console.log('\n8. переключение рантайма в установленном проекте');
  const p8 = join(work, 'p8');
  const t8 = join(p8, '.cursor', 'skills');
  check(run(['cursor', '--project-dir', p8]) === 0, 'установка');
  const foreignMd = 'Run: powershell.exe -NoProfile -File scripts/x.ps1\n';
  put(join(t8, 'my-skill', 'SKILL.md'), foreignMd);
  writeFileSync(join(t8, MANIFEST), JSON.stringify({ ...readManifest(t8), commit: 'abc123' }));
  check(run(['--runtime', 'python', '--project-dir', p8]) === 0, 'переключение на python');
  check(readFileSync(join(t8, 'my-skill', 'SKILL.md'), 'utf8') === foreignMd, 'чужой SKILL.md не переписан');
  check(!readFileSync(join(t8, 'cf-info', 'SKILL.md'), 'utf8').includes('powershell.exe'), 'наш навык переключён');
  const m8 = readManifest(t8);
  check(m8.runtime === 'python' && m8.commit === 'abc123', 'манифест: runtime обновлён, commit сохранён');
  writeFileSync(join(t8, MANIFEST), '{ broken');
  check(run(['--runtime', 'powershell', '--project-dir', p8]) === 0, 'битый манифест — переключение проходит');
  check(readFileSync(join(t8, 'my-skill', 'SKILL.md'), 'utf8') === foreignMd, 'чужой SKILL.md не переписан и при битом манифесте');
  check((run.last.stderr.match(/не прочитан/g) || []).length === 1, 'предупреждение о манифесте — один раз');
  check(run(['cursor', '--project-dir', p8]) === 0, 'переустановка чинит манифест');

  // 8a. Свои навыки пользователя в .claude/skills, набор — в .cursor/skills
  console.log('\n8a. рантайм на месте: свои навыки в .claude, набор в .cursor');
  const userMd = join(p8, '.claude', 'skills', 'own', 'SKILL.md');
  put(userMd, foreignMd);
  check(run(['--runtime', 'python', '--project-dir', p8]) === 0, 'переключение на python');
  check(readFileSync(userMd, 'utf8') === foreignMd, '.claude/skills пользователя не тронут');
  check(!readFileSync(join(t8, 'cf-info', 'SKILL.md'), 'utf8').includes('powershell.exe'), '.cursor переключён');

  // 8b. То же, но установка до v1.8 — манифеста нет ни в одном каталоге
  console.log('\n8b. рантайм на месте: свои навыки в .claude, старая установка в .cursor');
  unlinkSync(join(t8, MANIFEST));
  check(run(['--runtime', 'powershell', '--project-dir', p8]) === 0, 'переключение на powershell');
  check(readFileSync(userMd, 'utf8') === foreignMd, '.claude/skills пользователя не тронут');
  check(readFileSync(join(t8, 'cf-info', 'SKILL.md'), 'utf8').includes('powershell.exe'), '.cursor переключён');
  check(run(['cursor', '--project-dir', p8]) === 0, 'переустановка возвращает манифест');
  rmSync(join(p8, '.claude'), { recursive: true });

  // 9. Интерактивное удаление в обычном проекте
  console.log('\n9. интерактивный режим: «Удалить»');
  // Cursor — 4-й в списке платформ → путь по умолчанию (cwd) → «Удалить»
  check(run([], { cwd: p8, input: '4\n\n2\n' }) === 0, 'удаление');
  check(ourSkills.every(s => !existsSync(join(t8, s))), 'навыки набора удалены');
  check(existsSync(join(t8, 'my-skill', 'SKILL.md')), 'my-skill на месте');

  // 10. .gitignore пользователя не в UTF-8 и файл на месте навыка
  console.log('\n10. .gitignore в cp1251, файл вместо каталога навыка');
  const p10 = join(work, 'p10');
  const t10 = join(p10, '.cursor', 'skills');
  const cp1251 = Buffer.concat([Buffer.from('node_modules/\n# '), Buffer.from([0xcf, 0xf0, 0xe8]), Buffer.from('\n')]);
  put(join(t10, '.gitignore'), cp1251);
  put(join(t10, ourSkills[0]), 'stray file\n');
  check(run(['cursor', '--project-dir', p10]) === 0, 'установка');
  const gi10 = readFileSync(join(t10, '.gitignore'));
  check(gi10.subarray(0, cp1251.length).equals(cp1251) && gi10.includes('__pycache__/'), '.gitignore: байты сохранены, строка дописана');
  check(existsSync(join(t10, ourSkills[0], 'SKILL.md')), `${ourSkills[0]} установлен на месте файла`);

  // 11. Каталог с именем нашего навыка, которого прошлая установка не ставила, — предупреждение
  console.log('\n11. перезапись чужого каталога с именем навыка');
  const m10 = readManifest(t10);
  writeFileSync(join(t10, MANIFEST), JSON.stringify({ ...m10, skills: m10.skills.filter(s => s !== ourSkills[1]) }));
  check(run(['cursor', '--project-dir', p10]) === 0, 'обновление');
  check(run.last.stderr.includes(`${ourSkills[1]} не из прошлой установки`), 'предупреждение с именем каталога');

  // 12. --undo из копии без .claude/skills: хватает манифеста
  console.log('\n12. --undo без исходных навыков');
  const nosrc = join(work, 'nosrc', 'scripts', 'switch.py');
  cpSync(SWITCH, nosrc);
  put(join(t10, 'my-skill', 'SKILL.md'));
  check(run(['--undo', 'cursor', '--project-dir', p10], { script: nosrc }) === 0, 'undo');
  check(ourSkills.every(s => !existsSync(join(t10, s))), 'навыки из манифеста удалены');
  check(existsSync(join(t10, 'my-skill', 'SKILL.md')), 'my-skill на месте');
} finally {
  // Ссылки из сценария 5 снимаем сами: уборка не должна пройти по ним в исходные навыки
  const t5 = join(work, 'p5', '.claude', 'skills');
  if (existsSync(t5)) {
    for (const e of readdirSync(t5)) {
      const p = join(t5, e);
      if (lstatSync(p).isSymbolicLink()) { try { unlinkSync(p); } catch { rmdirSync(p); } }
    }
  }
  rmSync(work, { recursive: true, force: true });
}

console.log(failures === 0 ? '\nOK' : `\n${failures} нарушений`);
process.exit(failures ? 1 : 0);
