export const name = 'html-fields: getFormState().htmlFields + getHtmlFrame — вход во фрейм поля HTML-документа';
export const tags = ['formstate', 'html'];
export const timeout = 120000;

// Обработка ПоляHTML (#89). Вход во фрейм ПолеHTMLДокумента по имени элемента 1С; дальше —
// обычный Playwright. Проверяется то, что намерили на стенде:
//   • табличный документ тоже рендерится iframe-ами, но в htmlFields не попадает;
//   • iframe поля создаётся при первом показе — неактивная страница, свёрнутая группа и
//     Видимость=Ложь дают одинаковую ошибку «not visible», а не молчаливое ожидание;
//   • только активная форма: под модальным окном фрейм не отдаётся (клик ушёл бы в окно).

export default async function({ navigateLink, getFormState, clickElement, closeForm, getHtmlFrame, assert, step, log }) {

  const errOf = async (fn) => { try { await fn(); } catch (e) { return e.message; } return null; };
  const names = (s) => (s.htmlFields || []).map(f => f.name);

  await step('htmlFields: только видимое поле, табличный документ не попал', async () => {
    const s = await navigateLink('Обработка.ПоляHTML');
    log(`htmlFields=${JSON.stringify(s.htmlFields)}`);
    assert.deepEqual(s.htmlFields, [{ name: 'ПолеЧата', label: 'Чат' }], 'одно видимое поле, заголовок без двоеточия');
  });

  await step('getHtmlFrame() без имени: дальше Playwright — скрытый дубль, клик, ответ', async () => {
    const app = await getHtmlFrame();
    // Два textarea с одним testid — первый скрыт; без фильтра Playwright упал бы на strict-режиме.
    await app.getByTestId('chat-message').filter({ visible: true }).fill('marker-89', { timeout: 5000 });
    await app.getByTestId('send-message').click({ timeout: 5000 });
    assert.equal(await app.getByTestId('terminal-response').innerText({ timeout: 3000 }), 'echo:marker-89');
  });

  await step('поиск по заголовку и по имени; неизвестное имя — ошибка со списком', async () => {
    const byLabel = await getHtmlFrame('чат');
    assert.equal(await byLabel.getByTestId('terminal-response').innerText(), 'echo:marker-89', 'по заголовку, без регистра');
    const byName = await getHtmlFrame('ПолеЧата');
    assert.equal(await byName.getByTestId('terminal-response').innerText(), 'echo:marker-89', 'по имени');
    const err = await errOf(() => getHtmlFrame('Нету'));
    log(err);
    assert.includes(err || '', 'not found', 'неизвестное имя — not found');
    assert.includes(err || '', 'ПолеСправки', 'в ошибке перечислены поля формы');
  });

  await step('скрытое поле — not visible; после показа работает', async () => {
    for (const hidden of ['ПолеСправки', 'ПолеЛога', 'ПолеСкрытое']) {
      const err = await errOf(() => getHtmlFrame(hidden));
      assert.includes(err || '', 'is not visible', `${hidden}: not visible, а не ожидание до таймаута`);
    }

    let s = await clickElement('Справка');
    assert.includes(names(s), 'ПолеСправки', 'страница открыта — поле в htmlFields');
    assert.equal(await (await getHtmlFrame('ПолеСправки')).getByTestId('help-title').innerText({ timeout: 3000 }), 'Справка');
    await clickElement('Основная');

    s = await clickElement('Лог', { expand: true });
    assert.deepEqual(names(s), ['ПолеЛога', 'ПолеЧата'], 'группа раскрыта — поле в htmlFields');
    assert.equal(await (await getHtmlFrame('ПолеЛога')).getByTestId('log').innerText({ timeout: 3000 }), 'строка лога');
    const amb = await errOf(() => getHtmlFrame());
    assert.includes(amb || '', 'pass a name', 'два видимых поля без имени — неоднозначность');
    await clickElement('Лог', { expand: false });

    // Команда чисто клиентская: запросов к серверу нет. Ожидание сети после клика раньше
    // упиралось в свой потолок (~10 с) — теперь отпускает через секунду тишины.
    const t0 = Date.now();
    s = await clickElement('Переключить скрытое');
    const ms = Date.now() - t0;
    log(`client command click: ${ms}ms`);
    assert.ok(ms < 6000, `клик по клиентской команде без 10-секундного ожидания сети (${ms}ms)`);
    assert.includes(names(s), 'ПолеСкрытое', 'Видимость=Истина — поле в htmlFields');
    assert.equal(await (await getHtmlFrame('ПолеСкрытое')).getByTestId('hidden-mark').innerText({ timeout: 3000 }), 'скрытое');
    s = await clickElement('Переключить скрытое');
    assert.ok(!names(s).includes('ПолеСкрытое'), 'снова скрыто — из htmlFields ушло (iframe остался, 0×0)');
  });

  await step('модальное окно поверх: htmlFields пуст, getHtmlFrame бросает', async () => {
    await clickElement('Ещё');
    const s = await clickElement('Изменить форму...');
    assert.equal(s.modal, true, 'открыто модальное окно');
    assert.equal(s.htmlFields, undefined, 'у модального окна HTML-полей нет');
    const err = await errOf(() => getHtmlFrame('Чат'));
    assert.includes(err || '', 'no HTML fields', 'фрейм под окном не отдаётся');
    await closeForm();
    const back = await getFormState();
    assert.includes(names(back), 'ПолеЧата', 'окно закрыто — поле снова доступно');
    await closeForm();
  });

  await step('форма только с HTML-полем (без полей ввода и кнопок) распознаётся', async () => {
    const s = await navigateLink('Обработка.ТолькоHTML');
    log(`form=${s.form} htmlFields=${JSON.stringify(s.htmlFields)}`);
    assert.ok(s.form != null, 'форма распознана');
    assert.deepEqual(s.htmlFields, [{ name: 'ПолеПанели' }], 'поле в htmlFields');
    assert.equal(await (await getHtmlFrame()).getByTestId('panel').innerText({ timeout: 3000 }), 'панель');
    await closeForm();
  });
}
