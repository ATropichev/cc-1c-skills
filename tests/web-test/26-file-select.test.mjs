export const name = 'file select: clickElement { file } — окно 1С «Выбор файлов» и системное окно расширения';
export const tags = ['openfile', 'file'];
export const timeout = 120000;

export default async function({ openFile, clickElement, closeForm, getFormState, assert, step, log }) {
  const { fileURLToPath } = await import('url');
  const path = await import('path');

  // Сам EPF стенда — заведомо существующий файл для выбора; путь от корня репозитория, не от cwd
  const epfPath = fileURLToPath(new URL('../../test-tmp/13-openfile/build/ТестОткрытия.epf', import.meta.url));
  const epfDir = path.dirname(epfPath);
  const errorOf = async (fn) => { try { await fn(); return null; } catch (e) { return e.message; } };
  const result = async () => (await getFormState()).fields?.find(f => f.name === 'Результат')?.value;

  await step('setup: открыть обработку с кнопками выбора файла', async () => {
    const r = await openFile(epfPath);
    assert.equal(r.activeTab, 'Тест открытия', 'открыта форма ТестОткрытия');
  });

  await step('html: «Помещение» — окно 1С «Выбор файлов», файл выбран', async () => {
    const r = await clickElement('Помещение', { file: epfPath });
    log(`via=${r.file?.via} result=${await result()}`);
    assert.equal(r.file?.via, 'html', 'выбор через окно 1С');
    assert.equal(await result(), 'Помещение: ТестОткрытия.epf', 'форма получила файл');
  });

  await step('native: «Диалог» — системное окно расширения работы с файлами (если компонента подключена)', async () => {
    await clickElement('Подключение');
    const attached = (await result()) === 'подключено=Истина';
    if (!attached) {
      log('пропуск: расширение работы с файлами в веб-клиенте не подключено (нет компоненты нужной версии)');
      return;
    }
    if (process.platform !== 'win32') {
      log(`пропуск: системное окно выбора файла на ${process.platform} пока не поддерживается`);
      return;
    }
    const r = await clickElement('Диалог', { file: epfPath });
    log(`via=${r.file?.via} result=${await result()}`);
    assert.equal(r.file?.via, 'native', 'выбор через системное окно');
    assert.equal(await result(), `Диалог: ${epfPath}`, 'форма получила полный путь');

    const r2 = await clickElement('Каталог', { file: epfDir });
    log(`via=${r2.file?.via} result=${await result()}`);
    assert.equal(r2.file?.via, 'native', 'каталог — через системное окно «Выбор папки»');
    assert.equal(await result(), `Каталог: ${epfDir}`, 'форма получила каталог');
  });

  await step('ошибка: каталог в окне 1С «Выбор файлов» — понятный отказ', async () => {
    const msg = await errorOf(() => clickElement('Помещение', { file: epfDir }));
    assert.ok(/takes files only/.test(msg ?? ''), `ошибка про каталог: ${msg}`);
  });

  await step('ошибка: файла нет — отказ до клика', async () => {
    const msg = await errorOf(() => clickElement('Помещение', { file: 'test-tmp/нет-такого-файла.epf' }));
    assert.ok(/not found/.test(msg ?? ''), `ошибка про отсутствующий файл: ${msg}`);
  });

  await step('ошибка: после клика окно выбора не появилось', async () => {
    const t0 = Date.now();
    const msg = await errorOf(() => clickElement('Подключение', { file: epfPath, timeout: 3000 }));
    assert.ok(/no file selection dialog appeared/.test(msg ?? ''), `ошибка про отсутствие окна: ${msg}`);
    assert.ok(Date.now() - t0 < 10000, `отказ по таймауту, а не зависание (${Date.now() - t0} мс)`);
  });

  await step('cleanup: закрыть форму', async () => {
    await closeForm();
  });
}
