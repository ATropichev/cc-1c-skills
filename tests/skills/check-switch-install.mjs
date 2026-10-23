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

function run(args, script = SWITCH) {
  const r = spawnSync(PY, [script, ...args], { encoding: 'utf8', env: { ...process.env, PYTHONIOENCODING: 'utf-8' } });
  if (r.status !== 0) console.log(`    [${args.join(' ')}] exit ${r.status}\n${r.stdout}${r.stderr}`);
  return r.status;
}

const put = (p, text = 'x\n') => { mkdirSync(dirname(p), { recursive: true }); writeFileSync(p, text); };
const readManifest = (dir) => JSON.parse(readFileSync(join(dir, MANIFEST), 'utf8'));
const gitignoreLines = (dir) => readFileSync(join(dir, '.gitignore'), 'utf8').split(/\r?\n/).filter(Boolean);
const work = mkdtempSync(join(tmpdir(), 'switch-129-'));

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
  check(run(['--undo', 'claude-code', '--project-dir', p5]) === 0, 'undo');
  check(ourSkills.every(s => existsSync(join(SRC_SKILLS, s, 'SKILL.md'))), 'источник .claude/skills цел');
  check(existsSync(join(t5, 'my-skill', 'SKILL.md')), 'my-skill на месте');
  check(ourSkills.every(s => !existsSync(join(t5, s))), 'ссылки сняты');

  // 6. Источник без своего git: архив, распакованный внутрь чужого git-проекта
  console.log('\n6. источник без git внутри чужого репозитория');
  const outer = join(work, 'outer');
  const src6 = join(outer, 'tools', 'cc');
  cpSync(join(ROOT, 'scripts', 'switch.py'), join(src6, 'scripts', 'switch.py'));
  cpSync(SRC_SKILLS, join(src6, '.claude', 'skills'), { recursive: true });
  const git = (...a) => spawnSync('git', ['-C', outer, ...a], { encoding: 'utf8' });
  if (git('init', '-q').status === 0) {
    put(join(outer, 'readme.txt'));
    git('add', 'readme.txt');
    git('-c', 'user.name=t', '-c', 'user.email=t@t', 'commit', '-q', '-m', 'init');
  }
  const p6 = join(work, 'p6');
  mkdirSync(p6);
  check(run(['cursor', '--project-dir', p6], join(src6, 'scripts', 'switch.py')) === 0, 'установка проходит');
  check(!('commit' in readManifest(join(p6, '.cursor', 'skills'))), 'в манифесте нет commit чужого репозитория');

  // 7. Испорченный манифест не дотягивается за пределы каталога
  console.log('\n7. испорченный манифест');
  const p7 = join(work, 'p7');
  const t7 = join(p7, '.cursor', 'skills');
  put(join(p7, '.cursor', 'victim', 'SKILL.md'));
  put(join(t7, MANIFEST), JSON.stringify({ skills: ['../victim', '..', '.', ourSkills[0]] }));
  check(run(['cursor', '--project-dir', p7]) === 0, 'установка');
  check(existsSync(join(p7, '.cursor', 'victim', 'SKILL.md')), 'victim цел');
  put(join(t7, MANIFEST), '{ not json');
  check(run(['cursor', '--project-dir', p7]) === 0, 'битый JSON — установка проходит');
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
