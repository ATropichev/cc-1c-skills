export const name = 'Фильтры списка: simple-search, advanced-column';
export const tags = ['filter', 'smoke'];
export const timeout = 60000;

export default async function({ navigateSection, openCommand, filterList, unfilterList, readTable, closeForm, assert, step, log }) {

  await step('simple-search: filterList по тексту по всем колонкам', async () => {
    await navigateSection('Склад');
    await openCommand('Контрагенты');
    const before = await readTable({ maxRows: 50 });
    log(`before filter: total=${before.total}`);
    assert.ok(before.total >= 4, 'Должно быть минимум 4 контрагента до фильтра');

    await filterList('Север');
    const after = await readTable({ maxRows: 50 });
    log(`after simple-search 'Север': rows=${after.rows?.length} names=${after.rows?.map(r => r['Наименование']).join(',')}`);
    assert.ok(after.rows?.length >= 1 && after.rows?.length < before.total, 'Фильтр должен сузить список');
    assert.ok(after.rows.every(r => /Север/i.test(r['Наименование'] || '')), 'Все строки должны содержать Север');

    await unfilterList();
    const restored = await readTable({ maxRows: 50 });
    log(`after unfilter: total=${restored.total}`);
    assert.equal(restored.total, before.total, 'После unfilterList список восстановлен');
  });

  await step('advanced-column: filterList по конкретной колонке', async () => {
    await filterList('Север', { field: 'Наименование' });
    const t = await readTable({ maxRows: 50 });
    log(`advanced-column 'Наименование'='Север': rows=${t.rows?.length} names=${t.rows?.map(r => r['Наименование']).join(',')}`);
    assert.ok(t.rows?.length >= 1, 'Должна найтись хотя бы одна строка');
    assert.ok(t.rows.every(r => /Север/i.test(r['Наименование'] || '')), 'Все строки фильтруются по Наименование');

    await unfilterList();
    await closeForm();
  });
}
