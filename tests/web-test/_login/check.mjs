// web-test _login/check v1.1 — login as a given user: what is sent, how a refusal reads
// Source: https://github.com/Nikolay-Shirokov/cc-1c-skills
//
// `run <url> - --user= --password=` posts the credentials to <url>/e1cib/start. A fake 1C answers
// with the refusals measured on 8.3.20–8.5.1 (402, 412 as HTML, 403, 400 with reason 9); each must
// end with a non-zero exit, a message naming the cause, and the password nowhere in the output.
// Launch parameters of the URL must reach e1cib/start; login fields the CLI or the runner would drop
// silently (empty --user=, top-level user next to contexts, password without user) are refused.
// A successful login needs a real 1C and is checked live, not here. Needs Chromium, not a stand.
//
//   node tests/web-test/_login/check.mjs
//
// Exit codes: 0 — all scenarios hold; 1 — regressed.
import { spawn } from 'child_process';
import { createServer } from 'http';
import { resolve, dirname } from 'path';
import { fileURLToPath } from 'url';

const __dirname = dirname(fileURLToPath(import.meta.url));
const REPO = resolve(__dirname, '../../..');
const RUNNER = resolve(REPO, '.claude/skills/web-test/scripts/run.mjs');

const USER = 'Тестов Т.';
const SECRET = 'p@ss;1 &=x Ё%';

const json = (status, reason, descr) => ({
  status, type: 'application/json; charset=utf-8',
  body: JSON.stringify({ '#exception': '{http://v8.1c.ru/8.2/virtual-resource-system}Exception',
    exception: { clsid: '580392e6-ba49-4280-ac67-fcd6f2180121', reason, descr: `${descr}\nОшибка при выполнении запроса POST к ресурсу /e1cib/start:` } }),
});
const answers = {
  p402: json(402, 402, 'Неправильное имя пользователя или пароль'),
  p412: { status: 412, type: 'text/html; charset=utf-8',
    body: '<html>\n<head><meta http-equiv="Content-Type" content="text/html; charset=utf-8"></head>\n<body>\n' +
      '<div id="exc" style="display:none">{"exception":{"clsid":"580392e6-ba49-4280-ac67-fcd6f2180121","reason":"412",' +
      '"descr":"Нет прав на запуск требуемого вида клиента","category":"0000000000000000000"}}</div>\n</body></html>' },
  p403: { status: 403, type: 'text/plain', body: '' },
  pq: json(402, 402, 'Неправильное имя пользователя или пароль'),
  p400: { status: 400, type: 'application/json; charset=utf-8',
    body: JSON.stringify({ exception: { clsid: '60c686dc-798f-4d17-aadb-a90156a16eb8', reason: 9, descr: 'Не обнаружено свободной лицензии!' } }) },
};

const received = {};
const server = createServer((req, res) => {
  const m = req.url.match(/^\/(\w+)(?:\/[\w-]+)?\/e1cib\/start(\?[^#]*)?$/);
  let body = '';
  req.on('data', c => { body += c; });
  req.on('end', () => {
    if (!m || !answers[m[1]] || req.method !== 'POST') { res.writeHead(404); res.end(); return; }
    received[m[1]] = { type: req.headers['content-type'] || '', form: new URLSearchParams(body), query: m[2] || '' };
    const a = answers[m[1]];
    res.writeHead(a.status, { 'Content-Type': a.type });
    res.end(a.body);
  });
});
await new Promise(r => server.listen(0, '127.0.0.1', r));
const base = `http://127.0.0.1:${server.address().port}`;

function run(args, cmd = 'run') {
  return new Promise(done => {
    const child = spawn(process.execPath, [RUNNER, cmd, ...args], { cwd: REPO });
    let out = '';
    child.stdout.on('data', d => { out += d; });
    child.stderr.on('data', d => { out += d; });
    const timer = setTimeout(() => child.kill(), 90000);
    child.on('close', code => { clearTimeout(timer); done({ code, out }); });
    child.stdin.end('return 1;');
  });
}

const sentRight = (pub) => {
  const r = received[pub];
  return !!r && /application\/x-www-form-urlencoded/.test(r.type) && r.form.get('Usr') === USER &&
    r.form.get('Pwd') === SECRET && r.form.get('AuthFailHandling') === 'error';
};

const scenarios = [
  { name: '402 — неверное имя или пароль', pub: 'p402', text: /rejected the credentials of user "Тестов Т\."[^\n]*Неправильное имя пользователя или пароль/ },
  { name: '412 — нет права на веб-клиент (тело HTML)', pub: 'p412', text: /User "Тестов Т\." may not run the web client: "Нет прав на запуск требуемого вида клиента"/ },
  { name: '403 — нет лицензии', pub: 'p403', text: /no free licence \(HTTP 403\)/ },
  { name: '400 reason 9 — нет лицензии', pub: 'p400', text: /no free licence \(HTTP 400\): "Не обнаружено свободной лицензии!"/ },
  { name: '--password= без --user=', args: [`${base}/p402`, '-', `--password=${SECRET}`], text: /--password= requires --user=/, nothingSent: 'p402' },
  { name: 'пустой --user=', args: [`${base}/p402`, '-', '--user=', `--password=${SECRET}`], text: /--user= is empty/, nothingSent: 'p402' },
  { name: 'параметры запуска из URL доходят до e1cib/start', pub: 'pq', url: `${base}/pq/ru_RU/?C=hello&L=en`,
    text: /rejected the credentials/, query: '?C=hello&L=en' },
  { name: 'конфиг: user на верхнем уровне при contexts', cmd: 'test', args: [resolve(__dirname, 'suites/top-user'), '--screenshot=off'],
    text: /top-level user\/password apply only without "contexts"/ },
  { name: 'конфиг: password без user у контекста', cmd: 'test', args: [resolve(__dirname, 'suites/ctx-password'), '--screenshot=off'],
    text: /context "a": password without user/ },
];

let failed = 0;
for (const s of scenarios) {
  delete received[s.pub ?? s.nothingSent];
  const r = await run(s.args ?? [s.url ?? `${base}/${s.pub}`, '-', `--user=${USER}`, `--password=${SECRET}`], s.cmd);
  const checks = [
    [r.code !== 0 && r.code !== null, `exit code ${r.code} (ожидался ненулевой)`],
    [s.text.test(r.out), `в выводе нет ${s.text}`],
    [!r.out.includes(SECRET), 'пароль попал в вывод'],
    ...(s.pub ? [[sentRight(s.pub), `форма дошла не та: ${JSON.stringify(received[s.pub] && Object.fromEntries(received[s.pub].form))}`]] : []),
    ...(s.nothingSent ? [[!received[s.nothingSent], 'запрос ушёл, хотя аргументы неверны']] : []),
    ...(s.query !== undefined ? [[received[s.pub]?.query === s.query, `query на e1cib/start: ${JSON.stringify(received[s.pub]?.query)} (ожидался ${s.query})`]] : []),
  ];
  const bad = checks.filter(([ok]) => !ok).map(([, why]) => why);
  console.log(`  ${bad.length ? '✗' : '✓'} ${s.name}${bad.length ? `\n      ${bad.join('; ')}` : ''}`);
  if (bad.length) {
    failed++;
    console.log(`      ─── output ───\n${r.out.trim()}`);
  }
}
server.close();

console.log();
if (failed) {
  console.log(`FAIL: ${failed}/${scenarios.length} сценариев — вход под пользователем отправляет не то или отказ читается не так`);
  process.exit(1);
}
console.log(`OK: ${scenarios.length}/${scenarios.length} — форма входа и параметры запуска уходят целиком, отказы названы, пароль не печатается, молча отброшенного входа нет`);
process.exit(0);
