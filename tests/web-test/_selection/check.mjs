// web-test _selection/check v1.1 — a run with nothing to execute must not look green
// Source: https://github.com/Nikolay-Shirokov/cc-1c-skills
//
// Filters that match no test, or a selection where every test is skipped, must end with exit 5
// and never import `_hooks.mjs` (prepare() rebuilds the stand). The refusal happens before the
// browser starts, so this check needs neither a stand nor Chromium.
//
//   node tests/web-test/_selection/check.mjs
//
// Exit codes: 0 — all scenarios hold; 1 — regressed.
import { spawnSync } from 'child_process';
import { existsSync, mkdirSync, readFileSync } from 'fs';
import { resolve, dirname } from 'path';
import { fileURLToPath } from 'url';
import { tmpdir } from 'os';
// fs.rmSync is never called directly: on Windows it silently does nothing on non-ASCII paths.
import { removePathSync } from '../../common/fsutil.mjs';

const __dirname = dirname(fileURLToPath(import.meta.url));
const REPO = resolve(__dirname, '../../..');
const RUNNER = resolve(REPO, '.claude/skills/web-test/scripts/run.mjs');
const workDir = resolve(tmpdir(), 'webtest-selection-check-' + process.pid);
const MARKER = resolve(workDir, 'hooks-imported');

function run(suite, args) {
  removePathSync(MARKER);
  const r = spawnSync(process.execPath, [RUNNER, 'test', resolve(__dirname, suite), '--screenshot=off', ...args], {
    cwd: REPO, encoding: 'utf8', timeout: 60000,
    env: { ...process.env, WEBTEST_SELECTION_MARKER: MARKER },
  });
  return { code: r.status, stdout: r.stdout || '', stderr: r.stderr || '', hooked: existsSync(MARKER) };
}

const parse = (s) => { try { return JSON.parse(s); } catch { return null; } };
const readText = (p) => { try { return readFileSync(p, 'utf8'); } catch { return ''; } };

const scenarios = [
  { name: '--grep мимо', suite: 'basic', args: ['--grep=missing'], text: /matched none of 2 discovered tests/ },
  { name: '--tags мимо', suite: 'basic', args: ['--tags=missing'], text: /--tags=missing matched none/ },
  { name: 'выборка целиком skipped', suite: 'basic', args: ['--grep=skipped'], text: /all 1 selected tests are skipped[\s\S]*skip: reason x/ },
  { name: 'only на skipped-тесте', suite: 'only', args: [], text: /all 1 selected tests are skipped/ },
  { name: 'пустая выборка, --report=-', suite: 'basic', args: ['--grep=missing', '--report=-'],
    report: (j) => j?.state === 'empty' && j.summary.total === 0 },
  { name: 'всё skipped, --report=-', suite: 'basic', args: ['--grep=skipped', '--report=-'],
    report: (j) => j?.state === 'empty' && j.summary.skipped === 1 && j.tests[0]?.status === 'skipped' },
  { name: 'params: плейсхолдеры в имени — и кириллические, и латинские ключи', suite: 'params', args: ['--report=-'],
    report: (j) => JSON.stringify(j?.tests?.map((t) => t.name)) ===
      JSON.stringify(['Параметр кириллица / latin', 'Параметр граница_1 / edge']) },
  { name: 'пустая выборка, JUnit в файл', suite: 'basic', args: ['--grep=missing', '--format=junit', `--report=${resolve(workDir, 'r.xml')}`],
    file: () => /<testsuites [^>]*tests="0"/.test(readText(resolve(workDir, 'r.xml'))) },
];

mkdirSync(workDir, { recursive: true });
let failed = 0;
for (const s of scenarios) {
  const r = run(s.suite, s.args);
  const human = s.report ? r.stderr : r.stdout;
  const checks = [
    [r.code === 5, `exit code ${r.code} (ожидался 5)`],
    [!r.hooked, '_hooks.mjs импортирован'],
    ...(s.text ? [[s.text.test(human), `в выводе нет ${s.text}`]] : []),
    ...(s.report ? [[s.report(parse(r.stdout)), 'машинный отчёт в stdout не тот']] : []),
    ...(s.file ? [[s.file(), 'файл отчёта не записан или не тот']] : []),
  ];
  const bad = checks.filter(([ok]) => !ok).map(([, why]) => why);
  console.log(`  ${bad.length ? '✗' : '✓'} ${s.name}${bad.length ? `\n      ${bad.join('; ')}` : ''}`);
  if (bad.length) {
    failed++;
    console.log(`      ─── stdout ───\n${r.stdout.trim()}\n      ─── stderr ───\n${r.stderr.trim()}`);
  }
}
try { removePathSync(workDir); } catch {}

console.log();
if (failed) {
  console.log(`FAIL: ${failed}/${scenarios.length} сценариев — пустой прогон снова выглядит зелёным или трогает хуки`);
  process.exit(1);
}
console.log(`OK: ${scenarios.length}/${scenarios.length} — пустая и полностью skipped выборка: exit 5, хуки не загружаются`);
process.exit(0);
