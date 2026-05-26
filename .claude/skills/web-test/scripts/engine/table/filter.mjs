// web-test table/filter v1.17 — filterList / unfilterList — simple search + advanced-column filter badges.
// Source: https://github.com/Nikolay-Shirokov/cc-1c-skills

import { page, ensureConnected, normYo, highlightMode, ACTION_WAIT } from '../core/state.mjs';
import { detectFormScript, resolveGridScript } from '../../dom.mjs';
import { dismissPendingErrors, checkForErrors } from '../core/errors.mjs';
import { waitForStable, waitForCondition } from '../core/wait.mjs';
import { highlight, unhighlight } from '../recording/highlight.mjs';
import { safeClick } from '../core/helpers.mjs';
import { selectValue, fillReferenceField } from '../forms/select-value.mjs';
import { pasteText } from '../core/clipboard.mjs';
import { getFormState } from '../forms/state.mjs';
import { clickElement } from '../core/click.mjs';

/**
 * Filter the current list by field value, or search via search bar.
 *
 * Without field: simple search via the search bar (filters by all columns, no badge).
 * With field: advanced search — clicks target column cell to auto-populate FieldSelector,
 * opens dialog (Alt+F), fills Pattern, clicks Найти. Creates a real filter badge.
 * Handles text, reference (with Tab autocomplete), and date fields automatically.
 * Multiple filters can be chained by calling filterList multiple times.
 *
 * @param {string} text - Search text or date (e.g. "Мишка", "КП00", "10.03.2016")
 * @param {object} [opts]
 * @param {string} [opts.field] - Column name for advanced search (e.g. "Наименование", "Получатель", "Дата")
 * @param {boolean} [opts.exact] - Exact match (text fields only; dates/numbers/refs always exact)
 */
export async function filterList(text, { field, exact } = {}) {
  ensureConnected();
  await dismissPendingErrors();
  const formNum = await page.evaluate(detectFormScript());
  if (formNum === null) throw new Error('filterList: no form found');

  if (!field) {
    // --- Simple search: fill search input + Enter ---
    const searchId = await page.evaluate(`(() => {
      const p = 'form${formNum}_';
      const el = [...document.querySelectorAll('input.editInput[id^="' + p + '"]')]
        .find(el => el.offsetWidth > 0 && /Строк[аи]Поиска|SearchString/i.test(el.id));
      return el ? el.id : null;
    })()`);

    if (searchId) {
      await page.click(`[id="${searchId}"]`);
      await page.waitForTimeout(200);
      await page.keyboard.press('Control+A');
      await pasteText(text);
      await page.waitForTimeout(300);
      await page.keyboard.press('Enter');
      await waitForStable(formNum);

      const state = await getFormState();
      state.filtered = { type: 'search', text };
      return state;
    }

    // No search input — Ctrl+F opens advanced search on such forms.
    // Click first grid cell then fall through to advanced search path below.
    const firstCell = await page.evaluate(`(() => {
      const p = 'form${formNum}_';
      const grid = [...document.querySelectorAll('[id^="' + p + '"].grid, [id^="' + p + '"] .grid')]
        .find(g => g.offsetWidth > 0);
      if (!grid) return null;
      const rows = [...grid.querySelectorAll('.gridBody .gridLine')];
      if (!rows.length) return null;
      const cells = [...rows[0].querySelectorAll('.gridBox')];
      if (!cells.length) return null;
      const r = cells[0].getBoundingClientRect();
      return { x: Math.round(r.x + r.width / 2), y: Math.round(r.y + r.height / 2) };
    })()`);
    if (!firstCell) throw new Error('filterList: no search input and no grid found on this form');
    await page.mouse.click(firstCell.x, firstCell.y);
    await page.waitForTimeout(300);
    field = ''; // fall through to advanced search, skip DLB (empty field = keep auto-selected)
  }

  // --- Advanced search: click target column cell → Alt+F → fill Pattern → Найти ---
  // Clicking a cell in the target column makes it active, so when Alt+F opens the
  // advanced search dialog, FieldSelector is auto-populated with the correct field name.
  // This avoids changing FieldSelector programmatically (which can cause errors).
  const isDateValue = /^\d{2}\.\d{2}\.\d{4}$/.test(text.trim());

  // 1. Click a cell in the target column to activate it (auto-populates FieldSelector).
  //    If the column isn't visible in the grid, click any cell and use DLB fallback later.
  let needDlb = false;
  const gridEl = await page.evaluate(`(() => {
    const p = 'form${formNum}_';
    const grid = [...document.querySelectorAll('[id^="' + p + '"].grid, [id^="' + p + '"] .grid')]
      .find(g => g.offsetWidth > 0);
    if (!grid) return { error: 'no_grid' };
    const targetField = ${JSON.stringify(field)};
    const headers = [...grid.querySelectorAll('.gridHead .gridBox')];
    let colIndex = -1;
    let startsWithIdx = -1;
    let includesIdx = -1;
    for (let i = 0; i < headers.length; i++) {
      const t = headers[i].innerText?.trim().replace(/\\u00a0/g, ' ');
      if (!t) continue;
      const ny = s => s.replace(/ё/gi, 'е').replace(/\\u00a0/g, ' ');
      const tl = ny(t.toLowerCase()), fl = ny(targetField.toLowerCase());
      if (tl === fl) { colIndex = i; break; }
      if (startsWithIdx < 0 && tl.startsWith(fl)) { startsWithIdx = i; }
      else if (includesIdx < 0 && tl.includes(fl)) { includesIdx = i; }
    }
    if (colIndex < 0) colIndex = startsWithIdx >= 0 ? startsWithIdx : includesIdx;
    const rows = [...grid.querySelectorAll('.gridBody .gridLine')];
    if (!rows.length) return { error: 'no_rows' };
    if (colIndex < 0) {
      // Column not in grid — click first cell of first row, will use DLB to change field
      const cells = [...rows[0].querySelectorAll('.gridBox')];
      if (!cells.length) return { error: 'no_cells' };
      const r = cells[0].getBoundingClientRect();
      return { x: Math.round(r.x + r.width / 2), y: Math.round(r.y + r.height / 2), needDlb: true };
    }
    const cells = [...rows[0].querySelectorAll('.gridBox')];
    if (colIndex >= cells.length) return { error: 'cell_not_found' };
    const r = cells[colIndex].getBoundingClientRect();
    return { x: Math.round(r.x + r.width / 2), y: Math.round(r.y + r.height / 2) };
  })()`);
  if (gridEl.error) throw new Error(`filterList: ${gridEl.error}`);
  needDlb = !!gridEl.needDlb;
  await page.mouse.click(gridEl.x, gridEl.y);
  await page.waitForTimeout(500);

  // 2. Open advanced search dialog via Alt+F (with fallback to Еще menu)
  await page.keyboard.press('Alt+f');
  await page.waitForTimeout(2000);

  let dialogForm = await page.evaluate(detectFormScript());
  if (dialogForm === formNum) {
    // Alt+F didn't open dialog — fallback to Еще → Расширенный поиск
    await clickElement('Еще');
    await page.waitForTimeout(500);
    const menu = await page.evaluate(readSubmenuScript());
    const searchItem = Array.isArray(menu) && menu.find(i =>
      i.name.replace(/\u00a0/g, ' ').toLowerCase().includes('расширенный поиск'));
    if (!searchItem) {
      await page.keyboard.press('Escape');
      throw new Error('filterList: advanced search dialog could not be opened');
    }
    await page.mouse.click(searchItem.x, searchItem.y);
    await page.waitForTimeout(2000);
    dialogForm = await page.evaluate(detectFormScript());
    if (dialogForm === formNum) {
      throw new Error('filterList: advanced search dialog did not open');
    }
  }

  // 2b. If column wasn't in the grid, change FieldSelector via DLB dropdown
  //     Skip DLB when field is empty (fallback from no-search-input path — keep auto-selected field)
  if (needDlb && field) {
    const fsInfo = await page.evaluate(`(() => {
      const p = 'form' + ${JSON.stringify(String(dialogForm))} + '_';
      const fsInput = [...document.querySelectorAll('input.editInput[id^="' + p + '"]')]
        .find(el => el.offsetWidth > 0 && /FieldSelector/i.test(el.id));
      const dlb = document.getElementById(p + 'FieldSelector_DLB');
      return {
        current: fsInput?.value?.trim() || '',
        dlbX: dlb && dlb.offsetWidth > 0 ? Math.round(dlb.getBoundingClientRect().x + dlb.getBoundingClientRect().width / 2) : 0,
        dlbY: dlb && dlb.offsetWidth > 0 ? Math.round(dlb.getBoundingClientRect().y + dlb.getBoundingClientRect().height / 2) : 0
      };
    })()`);

    if (normYo(fsInfo.current.toLowerCase()) !== normYo(field.toLowerCase())) {
      await page.mouse.click(fsInfo.dlbX, fsInfo.dlbY);
      await page.waitForTimeout(1500);

      const ddResult = await page.evaluate(`(() => {
        const edd = document.getElementById('editDropDown');
        if (!edd || edd.offsetWidth === 0) return { error: 'no_dropdown' };
        const ny = s => s.replace(/ё/gi, 'е').replace(/\\u00a0/g, ' ');
        const target = ny(${JSON.stringify(field.toLowerCase())});
        const items = [...edd.querySelectorAll('div')].filter(el =>
          el.offsetWidth > 0 && el.innerText?.trim() && !el.innerText.includes('\\n'));
        const match = items.find(el => ny(el.innerText.trim().toLowerCase()) === target)
          || items.find(el => ny(el.innerText.trim().toLowerCase()).includes(target));
        if (!match) return { error: 'field_not_found', available: items.map(el => el.innerText.trim()) };
        const r = match.getBoundingClientRect();
        return { x: Math.round(r.x + r.width / 2), y: Math.round(r.y + r.height / 2), name: match.innerText.trim() };
      })()`);

      if (ddResult.error) {
        await page.keyboard.press('Escape');
        await page.waitForTimeout(500);
        await page.keyboard.press('Escape');
        await page.waitForTimeout(500);
        throw new Error(`filterList: field "${field}" not found in FieldSelector. Available: ${ddResult.available?.join(', ') || 'none'}`);
      }
      await page.mouse.click(ddResult.x, ddResult.y);
      await page.waitForTimeout(3000);
    }
  }

  // 3. Read dialog state and fill Pattern
  //    Detect field type by Pattern's sibling buttons:
  //    - iCalendB → date field (Home+Shift+End+Ctrl+V to replace date value)
  //    - iDLB on Pattern → reference field (paste + Tab for autocomplete)
  //    - neither → plain text field (just paste)
  const dialogInfo = await page.evaluate(`(() => {
    const p = 'form' + ${JSON.stringify(String(dialogForm))} + '_';
    const fsInput = [...document.querySelectorAll('input.editInput[id^="' + p + '"]')]
      .find(el => el.offsetWidth > 0 && /FieldSelector/i.test(el.id));
    const ptInput = [...document.querySelectorAll('input.editInput[id^="' + p + '"]')]
      .find(el => el.offsetWidth > 0 && /Pattern/i.test(el.id));
    const ptLabel = ptInput?.closest('label');
    const btns = ptLabel ? [...ptLabel.querySelectorAll('span.btn')].map(b => b.className) : [];
    const isDate = btns.some(c => c.includes('iCalendB'));
    const isRef = !isDate && btns.some(c => c.includes('iDLB'));
    return {
      fieldSelector: fsInput?.value?.trim() || '',
      patternValue: ptInput?.value?.trim() || '',
      patternId: ptInput?.id || '',
      isDate,
      isRef
    };
  })()`);

  if (dialogInfo.isDate) {
    // Date field: fill via Home → Shift+End (select all) → Ctrl+V (paste)
    if (isDateValue && dialogInfo.patternValue !== text.trim()) {
      await page.click(`[id="${dialogInfo.patternId}"]`);
      await page.waitForTimeout(200);
      await page.keyboard.press('Home');
      await page.waitForTimeout(100);
      await page.keyboard.press('Shift+End');
      await page.waitForTimeout(100);
      await pasteText(text);
      await page.waitForTimeout(500);
    }
  } else {
    // Text or reference field: fill Pattern via clipboard paste
    await page.click(`[id="${dialogInfo.patternId}"]`);
    await page.waitForTimeout(200);
    await page.keyboard.press('Control+A');
    await pasteText(text);
    await page.waitForTimeout(300);

    if (dialogInfo.isRef) {
      // Reference field: Tab triggers autocomplete to resolve text → reference value
      await page.keyboard.press('Tab');
      await page.waitForTimeout(2000);
    }
  }

  // 3b. Switch CompareType if exact match requested (text fields only).
  //    Date/number: always exact, CompareType disabled. Reference: default exact (selects ref).
  if (exact && !dialogInfo.isDate && !dialogInfo.isRef) {
    const exactRadio = await page.evaluate(`(() => {
      const p = 'form' + ${JSON.stringify(String(dialogForm))} + '_';
      // Check if CompareType group is disabled (dates, numbers)
      const group = document.getElementById(p + 'CompareType');
      if (group && group.classList.contains('disabled')) return { already: true };
      const el = document.getElementById(p + 'CompareType#2#radio');
      if (!el || el.offsetWidth === 0) return null;
      if (el.classList.contains('select')) return { already: true };
      const r = el.getBoundingClientRect();
      return { x: Math.round(r.x + r.width / 2), y: Math.round(r.y + r.height / 2) };
    })()`);
    if (exactRadio && !exactRadio.already) {
      await page.mouse.click(exactRadio.x, exactRadio.y);
      await page.waitForTimeout(300);
    }
  }

  // 4. Click "Найти" via mouse.click (dialog is modal — page.click may be blocked)
  const findBtnCoords = await page.evaluate(`(() => {
    const btns = [...document.querySelectorAll('a.press')].filter(el => el.offsetWidth > 0);
    const btn = btns.find(el => el.innerText?.trim() === 'Найти');
    if (!btn) return null;
    const r = btn.getBoundingClientRect();
    return { x: Math.round(r.x + r.width / 2), y: Math.round(r.y + r.height / 2) };
  })()`);
  if (findBtnCoords) {
    await page.mouse.click(findBtnCoords.x, findBtnCoords.y);
  } else {
    await clickElement('Найти');
  }
  await page.waitForTimeout(2000);

  // 5. Close advanced search dialog if it stayed open (some forms keep it open after Найти).
  //    Check the specific dialog form — not generic modalSurface — to avoid closing parent modals
  //    (e.g. a selection form that opened this advanced search).
  for (let attempt = 0; attempt < 3; attempt++) {
    const dialogVisible = await page.evaluate(`(() => {
      const p = 'form${dialogForm}_';
      return [...document.querySelectorAll('[id^="' + p + '"]')].some(el => el.offsetWidth > 0);
    })()`);
    if (!dialogVisible) break;
    await page.keyboard.press('Escape');
    await page.waitForTimeout(500);
  }
  await waitForStable(formNum);

  const state = await getFormState();
  state.filtered = { type: 'advanced', field, text, exact: !!exact };
  return state;
}

/**
 * Remove active filters/search from the current list.
 *
 * Without field: clears ALL filters (Ctrl+Q for advanced search + clear search field).
 * With field: clicks the × button on the specific filter badge (selective removal).
 *
 * @param {object} [opts]
 * @param {string} [opts.field] - Remove only the filter for this field (clicks badge ×)
 */
export async function unfilterList({ field } = {}) {
  ensureConnected();
  await dismissPendingErrors();
  const formNum = await page.evaluate(detectFormScript());
  if (formNum === null) throw new Error('unfilterList: no form found');

  if (field) {
    // --- Selective: click × on specific filter badge ---
    const closeBtn = await page.evaluate(`(() => {
      const p = 'form${formNum}_';
      const norm = s => s?.trim().replace(/\\u00a0/g, ' ').replace(/:$/, '').replace(/\\n/g, ' ') || '';
      const ny = s => s.replace(/ё/gi, 'е').replace(/\\u00a0/g, ' ');
      const target = ny(${JSON.stringify(field.toLowerCase())});
      const items = [...document.querySelectorAll('[id^="' + p + '"].trainItem')].filter(el => el.offsetWidth > 0);
      for (const item of items) {
        const titleEl = item.querySelector('.trainName');
        const title = ny(norm(titleEl?.innerText).toLowerCase());
        if (title === target || title.includes(target)) {
          const close = item.querySelector('.trainClose');
          if (close) {
            const r = close.getBoundingClientRect();
            return { x: Math.round(r.x + r.width / 2), y: Math.round(r.y + r.height / 2), field: norm(titleEl?.innerText) };
          }
        }
      }
      const available = items.map(item => norm(item.querySelector('.trainName')?.innerText));
      return { error: 'not_found', available };
    })()`);

    if (closeBtn?.error) throw new Error(`unfilterList: filter badge "${field}" not found. Available: ${closeBtn.available?.join(', ') || 'none'}`);
    await page.mouse.click(closeBtn.x, closeBtn.y);
    await waitForStable(formNum);

    const state = await getFormState();
    state.unfiltered = { field: closeBtn.field };
    return state;
  }

  // --- Clear ALL filters ---

  // 1. Remove all advanced filter badges (.trainItem × buttons)
  for (let attempt = 0; attempt < 20; attempt++) {
    const badge = await page.evaluate(`(() => {
      const p = 'form${formNum}_';
      const item = [...document.querySelectorAll('[id^="' + p + '"].trainItem')]
        .find(el => el.offsetWidth > 0);
      if (!item) return null;
      const close = item.querySelector('.trainClose');
      if (!close) return null;
      const r = close.getBoundingClientRect();
      return { x: Math.round(r.x + r.width / 2), y: Math.round(r.y + r.height / 2) };
    })()`);
    if (!badge) break;
    await page.mouse.click(badge.x, badge.y);
    await waitForStable(formNum);
  }

  // 2. Cancel active search via Ctrl+Q
  await page.keyboard.press('Control+q');
  await waitForStable(formNum);

  // 3. Clear simple search field if it has a value
  const searchInfo = await page.evaluate(`(() => {
    const p = 'form${formNum}_';
    const el = [...document.querySelectorAll('input.editInput[id^="' + p + '"]')]
      .find(el => el.offsetWidth > 0 && /Строк[аи]Поиска|SearchString/i.test(el.id));
    return el ? { id: el.id, value: el.value || '' } : null;
  })()`);

  if (searchInfo?.value) {
    await page.click(`[id="${searchInfo.id}"]`);
    await page.waitForTimeout(200);
    await page.keyboard.press('Control+A');
    await page.keyboard.press('Delete');
    await page.keyboard.press('Enter');
    await waitForStable(formNum);
  }

  const state = await getFormState();
  state.unfiltered = true;
  return state;
}
