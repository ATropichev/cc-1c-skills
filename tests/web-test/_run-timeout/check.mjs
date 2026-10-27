// web-test _run-timeout/check v1.0 — automated verdict for `run --timeout`
// Source: https://github.com/Nikolay-Shirokov/cc-1c-skills
//
// `run` bounds the script with --timeout and must then exit on its own: keep what the script
// logged, report timedOut, exit 2, and leave no Chromium behind — not even a renderer stuck in
// a JS loop, which survives every graceful close. A regressed `run` hangs forever, so the
// verdict comes from a parent process with its own deadline.
//
//   node tests/web-test/_run-timeout/check.mjs
//
// Exit codes: 0 — works; 1 — regressed; 2 — inconclusive (stand down).
// The orphan check snapshots Playwright's chrome.exe before/after (Windows only) — don't run
// other web-test sessions at the same time.
import { spawn, spawnSync } from 'child_process';
import { resolve, dirname } from 'path';
import { fileURLToPath } from 'url';

const __dirname = dirname(fileURLToPath(import.meta.url));
const REPO = resolve(__dirname, '../../..');
const RUNNER = resolve(REPO, '.claude/skills/web-test/scripts/run.mjs');
const URL = 'http://localhost:9191/webtest-runner/ru_RU';

// Generous: ~10s of script + up to ~20s of bounded teardown (screenshot, logout, kill).
const DEADLINE_MS = 90000;

async function standIsUp() {
  try {
    const res = await fetch(URL, { signal: AbortSignal.timeout(5000) });
    return res.ok;
  } catch { return false; }
}

function runCli(args, script, env = {}) {
  return new Promise((done) => {
    const t0 = Date.now();
    const child = spawn(process.execPath, [RUNNER, ...args], {
      cwd: REPO,
      stdio: ['pipe', 'pipe', 'pipe'],
      env: { ...process.env, ...env },
    });
    let out = '', err = '';
    child.stdout.on('data', d => { out += d; });
    child.stderr.on('data', d => { err += d; });
    const killer = setTimeout(() => {
      child.kill('SIGKILL');
      done({ out, err, code: null, timedOut: true, ms: Date.now() - t0 });
    }, DEADLINE_MS);
    child.on('close', (code) => {
      clearTimeout(killer);
      let json = null;
      try { json = JSON.parse(out); } catch {}
      done({ out, err, code, json, timedOut: false, ms: Date.now() - t0 });
    });
    child.stdin.end(script ?? '');
  });
}

function playwrightChromePids() {
  if (process.platform !== 'win32') return null;
  const r = spawnSync('powershell.exe', ['-NoProfile', '-Command',
    "Get-CimInstance Win32_Process -Filter \"Name='chrome.exe'\" | Where-Object { $_.CommandLine -match 'ms-playwright' } | ForEach-Object { $_.ProcessId }"],
    { encoding: 'utf8', windowsHide: true, timeout: 30000 });
  return new Set((r.stdout || '').split(/\s+/).filter(Boolean));
}

function leftovers(before) {
  const after = playwrightChromePids();
  if (!before || !after) return null;
  return [...after].filter(p => !before.has(p));
}

const checks = [];
const check = (name, ok, detail) => checks.push({ name, ok, detail });

// ── 1. invalid bounds: refused before any browser starts ──────────────────────
for (const bad of ['--timeout=Infinity', '--timeout=abc', '--timeout=0', '--timeout-min=1e9']) {
  const r = await runCli(['run', URL, '-', bad], 'console.log(1)');
  check(`${bad} отклонён до запуска браузера`,
    r.code === 1 && /Invalid/.test(r.err) && r.ms < 5000,
    `exit ${r.code}, ${r.ms}ms, stderr: ${r.err.trim().split('\n')[0] || '—'}`);
}

if (!await standIsUp()) {
  console.error(`INCONCLUSIVE: стенд не отвечает на ${URL}`);
  console.error('  Подними публикацию: прогони обычный набор tests/web-test/ — его хуки поднимут стенд.');
  process.exit(2);
}

// ── 2. pending promise: bound fires, log survives ─────────────────────────────
{
  const before = playwrightChromePids();
  const r = await runCli(['run', URL, '-', '--timeout=10000'],
    "console.log('before');\nawait getFormState();\nawait new Promise(() => {});\n");
  check('зависший сценарий: run завершился сам', !r.timedOut, r.timedOut ? `убит через ${DEADLINE_MS / 1000}s` : `${Math.round(r.ms / 1000)}s`);
  check('зависший сценарий: exit 2 и timedOut', r.code === 2 && r.json?.timedOut === true, `exit ${r.code}, timedOut=${r.json?.timedOut}`);
  check('зависший сценарий: вывод до зависания сохранён', /before/.test(r.json?.output || ''), `output=${JSON.stringify(r.json?.output)}`);
  const left = leftovers(before);
  if (left) check('зависший сценарий: процессов Chromium не осталось', left.length === 0, left.length ? `остались PID ${left.join(', ')}` : 'чисто');
}

// ── 3. wedged renderer: the case that orphans a spinning renderer ─────────────
{
  const before = playwrightChromePids();
  const r = await runCli(['run', URL, '-', '--timeout=8000'],
    "console.log('before');\nawait getPage().evaluate(() => { while (true) {} });\n");
  check('зависший рендерер: run завершился сам, exit 2', !r.timedOut && r.code === 2, r.timedOut ? 'убит внешним дедлайном' : `exit ${r.code}, ${Math.round(r.ms / 1000)}s`);
  const left = leftovers(before);
  if (left) check('зависший рендерер: процессов Chromium не осталось', left.length === 0, left.length ? `остались PID ${left.join(', ')}` : 'чисто');
}

// ── 4. normal script: unaffected ──────────────────────────────────────────────
{
  const r = await runCli(['run', URL, '-', '--timeout=60000'], "console.log('fine');\n");
  check('обычный сценарий: exit 0', r.code === 0 && r.json?.ok === true, `exit ${r.code}, output=${JSON.stringify(r.json?.output)}`);
}

console.log();
for (const c of checks) console.log(`  ${c.ok ? '✓' : '✗'} ${c.name}\n      ${c.detail}`);
const failed = checks.filter(c => !c.ok);
console.log();
if (failed.length) {
  console.log(`FAIL: ${failed.length}/${checks.length} проверок не прошло`);
  process.exit(1);
}
console.log(`OK: ${checks.length}/${checks.length} — run ограничен по времени, вывод сохраняется, процессы не утекают`);
process.exit(0);
