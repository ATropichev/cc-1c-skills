export const name = 'decoration-form: форма без полей ввода (гиперссылки/группы) детектируется';
export const tags = ['formstate', 'smoke'];
export const timeout = 90000;

// Обработка СтраницаНастроек — форма-«страница настроек» БЕЗ единого input.editInput /
// textarea / a.press (commandBarLocation:None): только гиперссылка-декорация + сворачиваемая
// группа. Воспроизводит реальный кейс «Администрирование → Интернет-поддержка и сервисы».
// Регресс на расширенный селектор детекции формы (dom/_shared.mjs, DETECT_FORM_FN /
// DETECT_FORMS_FN): до фикса detectForm возвращал null → getFormState = «No form detected»
// (form:null, formCount:0), навык такую форму НЕ видел.
//
// Плюс: сворачиваемые группы формы в getFormState().groups (состояние collapsed) и их
// раскрытие/сворачивание через clickElement {expand}/{toggle}. Форма содержит оба варианта
// рендера контрола (заголовок-гиперссылка и картинка-каретка ControlRepresentation), негатив
// (обычная несворачиваемая группа — НЕ в groups[]) и стресс-привязку (свободный элемент между
// группами не путает определение состояния).

export default async function({ navigateSection, openCommand, navigateLink, getFormState, clickElement, closeForm, assert, step, log }) {

  const collapsedOf = (s, name) => (s.groups || []).find(x => x.name === name)?.collapsed;

  await step('раздел: открыть «Страница настроек» командой из «Администрирование»', async () => {
    await navigateSection('Администрирование');
    const r = await openCommand('Страница настроек');
    log(`form=${r.form} formCount=${r.formCount} activeTab=${r.activeTab}`);
    assert.ok(r.form != null, 'форма распознана (form != null) — до фикса тут был null');
    assert.ok(r.formCount >= 1, 'formCount >= 1');
    const hy = (r.hyperlinks || []).map(h => h.name);
    assert.includes(hy, 'Техническая информация', 'гиперссылка-декорация видна в состоянии');
    assert.equal((r.fields || []).length, 0, 'полей ввода на форме нет (декорации-only)');
    await closeForm();
  });

  await step('navigateLink: та же форма через «Обработка.СтраницаНастроек»', async () => {
    const r = await navigateLink('Обработка.СтраницаНастроек');
    log(`form=${r.form} formCount=${r.formCount} activeTab=${r.activeTab}`);
    assert.ok(r.form != null, 'форма распознана через navigateLink');
    assert.ok(r.formCount >= 1, 'formCount >= 1');
    const state = await getFormState();
    const hy = (state.hyperlinks || []).map(h => h.name);
    assert.includes(hy, 'Техническая информация', 'гиперссылка видна и в getFormState');
    await closeForm();
  });

  await step('groups: getFormState показывает сворачиваемые группы + состояние', async () => {
    const s = await navigateLink('Обработка.СтраницаНастроек');
    log(`groups=${JSON.stringify((s.groups || []).map(g => [g.name, g.collapsed]))}`);
    assert.ok(s.groups?.length, 'groups[] присутствует');
    assert.equal(collapsedOf(s, 'ГруппаКлассификаторы'), true, 'вариант A (гиперссылка) — свёрнута');
    assert.equal(collapsedOf(s, 'ГруппаРазвёрнутая'), false, 'развёрнутая — collapsed:false');
    assert.equal(collapsedOf(s, 'ГруппаКартинкой'), true, 'вариант B (картинка) — свёрнута');
    assert.ok(!s.groups.some(g => g.name === 'ГруппаОбычная'),
      'обычная несворачиваемая группа НЕ попадает в groups[] (негатив — не шумит)');
    // Стресс-привязка: свободный элемент между группами не путает определение состояния.
    assert.equal(collapsedOf(s, 'ГруппаСтрессСвёрнутая'), true, 'стресс: свёрнутая определена верно');
    assert.equal(collapsedOf(s, 'ГруппаСтрессРазвёрнутая'), false, 'стресс: развёрнутая определена верно');
  });

  await step('group toggle: clickElement {expand}/{toggle} по вариантам A и B', async () => {
    // Вариант A (заголовок-гиперссылка): раскрыть → идемпотентный повтор → свернуть.
    let r = await clickElement('Классификаторы и курсы валют', { expand: true });
    assert.equal(r.clicked.toggled, true, 'A expand:true — кликнул');
    assert.equal(collapsedOf(r, 'ГруппаКлассификаторы'), false, 'A раскрыта');
    r = await clickElement('Классификаторы и курсы валют', { expand: true });
    assert.equal(r.clicked.toggled, false, 'A expand:true повторно — идемпотентно (no-op)');
    r = await clickElement('Классификаторы и курсы валют', { expand: false });
    assert.equal(collapsedOf(r, 'ГруппаКлассификаторы'), true, 'A свёрнута обратно');
    // Вариант B (картинка-каретка #titleBtn): toggle.
    r = await clickElement('Свёрнута картинкой', { toggle: true });
    assert.equal(collapsedOf(r, 'ГруппаКартинкой'), false, 'B раскрыта тоглом');
    await closeForm();
  });

  await step('свёрнутая группа С ТАБЛИЦЕЙ: collapsed против факта видимости грида', async () => {
    // Багрепорт 2026-07-23. Два дефекта на этой группе (у остальных содержимое — декорации):
    //  1) 1С кладёт первым сиблингом за #title_div служебную обёртку <дочерний>#group_div
    //     (logicGroupContainer, display:block, height:0), а контент идёт дальше по сиблингам →
    //     чтение display первого сиблинга давало collapsed:false в ОБОИХ состояниях;
    //  2) #title_text растягивается по ширине содержимого (173px свёрнута → 1295px развёрнута),
    //     кликабелен только вложенный label слева → клик в центр промахивался, и свернуть
    //     обратно было нельзя.
    // Грид в tables[] — независимая от collapsed проверка факта.
    const grid = (st) => (st.tables || []).some(t => t.name === 'ТаблицаВСвёрнутой');
    const s = await navigateLink('Обработка.СтраницаНастроек');
    assert.equal(collapsedOf(s, 'ГруппаСвёрнутаяСТаблицей'), true, 'шаг 0: collapsed:true сразу после открытия');
    assert.equal(grid(s), false, 'шаг 0: грида нет — группа действительно свёрнута');

    let r = await clickElement('Свёрнутая с таблицей', { expand: true });
    assert.equal(r.clicked.toggled, true, 'expand:true — кликнул');
    assert.equal(collapsedOf(r, 'ГруппаСвёрнутаяСТаблицей'), false, 'раскрыта');
    assert.equal(grid(r), true, 'грид появился в tables[]');

    r = await clickElement('Свёрнутая с таблицей', { expand: true });
    assert.equal(r.clicked.toggled, false, 'expand:true повторно — идемпотентно (no-op)');

    // Свернуть обратно: до фикса точки клика этот шаг молча не срабатывал (заголовок растянут).
    r = await clickElement('Свёрнутая с таблицей', { expand: false });
    assert.equal(r.clicked.toggled, true, 'expand:false — кликнул');
    assert.equal(collapsedOf(r, 'ГруппаСвёрнутаяСТаблицей'), true, 'свёрнута обратно');
    assert.equal(grid(r), false, 'грид пропал из tables[]');
    await closeForm();
  });

  await step('вложенная группа первым ребёнком: обёртка вида <дочерний>_div', async () => {
    // Служебную обёртку .logicGroupContainer платформа пишет двумя способами: у таблицы —
    // <дочерний>#group_div, у вложенной группы — <дочерний>_div. Правило, знающее только
    // первую форму, читает display обёртки (block) и рапортует «раскрыта» у свёрнутой.
    const виден = (st) => (st.texts || []).some(t => /Содержимое вложенной группы/.test(t.value));
    const s = await navigateLink('Обработка.СтраницаНастроек');
    assert.equal(collapsedOf(s, 'ГруппаСВложенной'), true, 'свёрнута сразу после открытия');
    assert.equal(виден(s), false, 'содержимое вложенной группы не видно');

    let r = await clickElement('Свёрнутая с вложенной группой', { expand: true });
    assert.equal(collapsedOf(r, 'ГруппаСВложенной'), false, 'раскрыта');
    assert.equal(виден(r), true, 'содержимое вложенной группы появилось');

    r = await clickElement('Свёрнутая с вложенной группой', { expand: true });
    assert.equal(r.clicked.toggled, false, 'expand:true повторно — идемпотентно');

    r = await clickElement('Свёрнутая с вложенной группой', { expand: false });
    assert.equal(collapsedOf(r, 'ГруппаСВложенной'), true, 'свёрнута обратно');
    assert.equal(виден(r), false, 'содержимое скрылось');
    await closeForm();
  });

  await step('скрытый первый узел: состояние берётся не по первому сиблингу', async () => {
    // Первый элемент группы скрыт своей логикой (visible:false), видимое содержимое — дальше
    // по цепочке сиблингов. Так ведёт себя боевая форма с таблицей, у которой скрыта командная
    // панель: чтение «display первого контент-узла» у РАСКРЫТОЙ группы даёт «свёрнута», и
    // clickElement({expand}) считает свой клик несработавшим.
    const пары = [
      ['Скрыт первый узел', 'ГруппаСкрытыйПервый', /^Видно только эту декорацию$/],
      ['Скрыт первый узел (картинка)', 'ГруппаСкрытыйПервыйКартинка', /Видно только эту декорацию \(картинка\)/],
    ];
    for (const [заголовок, имя, маркер] of пары) {
      const s = await navigateLink('Обработка.СтраницаНастроек');
      const виден = (st) => (st.texts || []).some(t => маркер.test(t.value));
      assert.equal(collapsedOf(s, имя), true, `${имя}: свёрнута после открытия`);
      assert.equal(виден(s), false, `${имя}: содержимое скрыто`);

      let r = await clickElement(заголовок, { expand: true });
      assert.equal(collapsedOf(r, имя), false, `${имя}: раскрыта (первый узел так и остался скрытым)`);
      assert.equal(виден(r), true, `${имя}: видимый узел появился`);

      r = await clickElement(заголовок, { expand: true });
      assert.equal(r.clicked.toggled, false, `${имя}: expand:true повторно — идемпотентно`);

      r = await clickElement(заголовок, { expand: false });
      assert.equal(collapsedOf(r, имя), true, `${имя}: свёрнута обратно`);
      assert.equal(виден(r), false, `${имя}: содержимое скрылось`);
      await closeForm();
    }
  });

  await step('меняющийся заголовок + цель ниже вьюпорта: ответ даёт стабильный ключ', async () => {
    // У группы задан CollapsedRepresentationTitle, поэтому текст заголовка меняется при
    // раскрытии, и повторный клик по прежнему тексту падает с «not found». Ответ на клик
    // отдаёт техническое имя (group) и текущий заголовок (title), а hint предупреждает о смене.
    // Группа последняя на форме: раскрытая выше таблица уводит её за пределы окна — координатный
    // клик туда раньше не доходил, теперь цель сперва скроллится в вид.
    const G = 'ГруппаМеняющийсяЗаголовок';
    const s = await navigateLink('Обработка.СтраницаНастроек');
    assert.equal(collapsedOf(s, G), true, 'свёрнута после открытия');
    assert.equal((s.groups || []).find(g => g.name === G)?.title, 'Показать подробности',
      'в свёрнутом виде — заголовок свёрнутого представления');
    await clickElement('Свёрнутая с таблицей', { expand: true });  // удлиняем форму

    let r = await clickElement('Показать подробности', { expand: true });
    assert.equal(r.clicked.toggled, true, 'кликнул (цель за вьюпортом — со скроллом)');
    assert.equal(collapsedOf(r, G), false, 'раскрыта');
    assert.equal(r.clicked.group, G, 'clicked.group — техническое имя группы');
    assert.equal(r.clicked.title, 'Скрыть подробности', 'clicked.title — текущий заголовок');
    assert.includes(r.hint, 'now titled "Скрыть подробности"', 'hint предупреждает о смене заголовка');

    // Прежний текст больше не находится — ради этого в ответе и есть стабильный ключ.
    await assert.throws(() => clickElement('Показать подробности', { expand: false }),
      'клик по прежнему заголовку не проходит');

    r = await clickElement(r.clicked.group, { expand: true });
    assert.equal(r.clicked.toggled, false, 'по техническому имени expand идемпотентен');
    r = await clickElement(G, { expand: false });
    assert.equal(collapsedOf(r, G), true, 'свёрнута обратно по техническому имени');
    assert.equal(r.clicked.title, 'Показать подробности', 'заголовок вернулся к свёрнутому');
    await closeForm();
  });

  await step('растянутая гиперссылка: клик доходит до обработчика', async () => {
    // Проверка соседнего с дефектом 2 случая. Ссылка растянута на всю ширину формы
    // (horizontalStretch + autoMaxWidth:false → контейнер 1295px), но промаха тут НЕ бывает:
    // её внутренний текстовый узел — div.ellipsis.flex-1-1-100, он тянется ВМЕСТЕ с
    // контейнером (1293 из 1295), тогда как у заголовка группы внутри label без flex-1-1-100,
    // шириной по тексту. Шаг стоит страховкой на случай смены вёрстки платформой.
    // Обработчик Нажатие сообщает — без следа доставку клика не отличить от no-op.
    const сообщения = (st) => (st.errors?.messages || []).join(' | ');
    const s = await navigateLink('Обработка.СтраницаНастроек');
    assert.equal(сообщения(s), '', 'до клика сообщений нет');
    const r = await clickElement('Растянутая ссылка');
    assert.includes(сообщения(r), 'клик по растянутой ссылке доставлен',
      'клик по растянутой ссылке дошёл до обработчика');
    await closeForm();
  });

  await step('popup: всплывающая группа — behavior, открытие показывает содержимое', async () => {
    const s = await navigateLink('Обработка.СтраницаНастроек');
    const pg = (s.groups || []).find(g => g.name === 'ГруппаВсплывающая');
    assert.ok(pg, 'всплывающая группа в groups[]');
    assert.equal(pg.behavior, 'popup', 'помечена behavior:popup (отличима от collapsible)');
    assert.equal(pg.collapsed, true, 'закрыта — collapsed:true');
    assert.ok(!(s.texts || []).some(t => /всплывающей/.test(t.value)), 'содержимое скрыто, пока закрыта');
    // Открыть → содержимое панели становится видно в состоянии формы.
    let r = await clickElement('Всплывающая группа', { expand: true });
    assert.equal((r.groups || []).find(g => g.name === 'ГруппаВсплывающая')?.collapsed, false, 'открыта');
    assert.ok((r.texts || []).some(t => /всплывающей/.test(t.value)), 'после открытия содержимое видно');
    r = await clickElement('Всплывающая группа', { expand: true });
    assert.equal(r.clicked.toggled, false, 'expand идемпотентен для popup');
    r = await clickElement('Всплывающая группа', { expand: false });
    assert.equal((r.groups || []).find(g => g.name === 'ГруппаВсплывающая')?.collapsed, true, 'закрыта обратно');
    await closeForm();
  });
}
