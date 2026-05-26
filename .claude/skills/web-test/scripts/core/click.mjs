// web-test core/click v1.16 — clickElement dispatcher: spreadsheet cells, submenus, grid groups/trees, buttons/links, tabs.
// Source: https://github.com/Nikolay-Shirokov/cc-1c-skills

import {
  page, ensureConnected, ACTION_WAIT, highlightMode, normYo,
} from './state.mjs';
import {
  detectFormScript, findClickTargetScript, resolveGridScript, readSubmenuScript,
} from '../dom.mjs';
import { dismissPendingErrors, checkForErrors, fetchErrorStack } from './errors.mjs';
import { waitForStable, startNetworkMonitor } from './wait.mjs';
import { highlight, unhighlight } from '../recording/highlight.mjs';
import { safeClick } from './helpers.mjs';
import { getGridToggleIcon, shouldClickToggle } from '../table/grid-toggle.mjs';
import {
  clickSpreadsheetCell, findSpreadsheetCellByText,
} from '../table/spreadsheet.mjs';
// getFormState still in browser.mjs.
import { getFormState } from '../browser.mjs';

/** Click a button/hyperlink/tab on the current form. Use {dblclick: true} to double-click (open items from lists).
 *  First argument can also be an object { row, column } to click a SpreadsheetDocument cell. */
export async function clickElement(text, { dblclick, table, toggle, expand, modifier, timeout } = {}) {
  ensureConnected();
  // Dispatch to spreadsheet cell handler when first arg is { row, column }
  if (typeof text === 'object' && text !== null && text.column != null) {
    await dismissPendingErrors();
    return clickSpreadsheetCell(text, { dblclick, modifier });
  }
  await dismissPendingErrors();
  if (highlightMode) try { await highlight(text, { table }); await page.waitForTimeout(500); await unhighlight(); } catch {}
  let netMonitor = null;
  try {

  // First check if there's a confirmation dialog — click matching button
  const pending = await checkForErrors();
  if (pending?.confirmation) {
    const btnResult = await page.evaluate(`(() => {
      const norm = s => s?.trim().replace(/\\u00a0/g, ' ') || '';
      const ny = s => s.replace(/ё/gi, 'е').replace(/\\u00a0/g, ' ');
      const target = ny(${JSON.stringify(text.toLowerCase())});
      const btns = [...document.querySelectorAll('a.press.pressButton')].filter(el => el.offsetWidth > 0);
      let best = btns.find(el => ny(norm(el.innerText).toLowerCase()) === target);
      if (!best) best = btns.find(el => ny(norm(el.innerText).toLowerCase()).includes(target));
      if (best) {
        const r = best.getBoundingClientRect();
        return { name: norm(best.innerText), x: Math.round(r.x + r.width/2), y: Math.round(r.y + r.height/2) };
      }
      return { error: 'not_found', available: btns.map(el => norm(el.innerText)).filter(Boolean) };
    })()`);
    if (btnResult?.error) throw new Error(`clickElement: "${text}" not found among confirmation buttons. Available: ${btnResult.available?.join(', ') || 'none'}`);
    await page.mouse.click(btnResult.x, btnResult.y);
    await waitForStable();
    const state = await getFormState();
    state.clicked = { kind: 'confirmation', name: btnResult.name };
    return state;
  }

  // Check if there's an open popup — if so, try to click inside it
  const popupItems = await page.evaluate(readSubmenuScript());
  if (Array.isArray(popupItems) && popupItems.length > 0) {
    const target = normYo(text.toLowerCase());
    let found = popupItems.find(i => normYo(i.name.toLowerCase()) === target);
    if (!found) found = popupItems.find(i => normYo(i.name.toLowerCase()).includes(target));
    if (found) {
      // submenuArrow items (group headers like "Создать", "Печать") — hover to expand nested submenu
      if (found.kind === 'submenuArrow') {
        // page.hover(selector) is more reliable than page.mouse.move(x,y) —
        // some submenu groups don't expand with plain mouse.move
        if (found.id) {
          await page.hover(`[id="${found.id}"]`);
        } else {
          await page.mouse.move(found.x, found.y);
        }
        await page.waitForTimeout(ACTION_WAIT);
        const nestedItems = await page.evaluate(readSubmenuScript());
        const state = await getFormState();
        state.clicked = { kind: 'submenuArrow', name: found.name };
        if (Array.isArray(nestedItems)) {
          state.submenu = nestedItems.map(i => i.name);
          state.hint = 'Call web_click again with a submenu item name to select it';
        }
        return state;
      }
      // Regular submenu/dropdown items — trusted events required.
      // Use mouse.click(x,y) when in viewport; use :visible selector for clipped items
      // (same ID can exist hidden in parent cloud AND visible in nested cloud).
      const vpHeight = await page.evaluate('window.innerHeight');
      if (found.x && found.y && found.y > 0 && found.y < vpHeight) {
        await page.mouse.click(found.x, found.y);
      } else if (found.id) {
        await page.click(`[id="${found.id}"]:visible`);
      } else if (found.x && found.y) {
        await page.mouse.click(found.x, found.y);
      }
      await waitForStable();
      const state = await getFormState();
      state.clicked = { kind: 'popupItem', name: found.name };
      const err = await checkForErrors();
      if (err) state.errors = err;
      return state;
    }
    // No match in popup — fall through to form elements
  }

  let formNum = await page.evaluate(detectFormScript());
  if (formNum === null) throw new Error(`clickElement: no form found`);

  // Pre-resolve grid when table is specified
  let gridSelector;
  if (table) {
    const resolved = await page.evaluate(resolveGridScript(formNum, table));
    if (resolved.error) throw new Error(`clickElement: table "${table}" not found. Available: ${resolved.available?.map(a => a.name).join(', ') || 'none'}`);
    gridSelector = resolved.gridSelector;
  }

  // Find the target element ID
  let target = await page.evaluate(findClickTargetScript(formNum, text, { tableName: table, gridSelector }));

  // Retry: if not found, a modal form may still be loading (e.g. after F4).
  // Wait up to 2s for a new form to appear and re-detect.
  if (target?.error) {
    for (let retry = 0; retry < 4; retry++) {
      await page.waitForTimeout(500);
      const newForm = await page.evaluate(detectFormScript());
      if (newForm !== null && newForm !== formNum) {
        formNum = newForm;
        target = await page.evaluate(findClickTargetScript(formNum, text, { tableName: table, gridSelector }));
        if (!target?.error) break;
      }
    }
  }
  // Fallback: search spreadsheet iframes for text match before giving up
  if (target?.error) {
    const ssCell = await findSpreadsheetCellByText(formNum, text);
    if (ssCell) {
      const cx = ssCell.box.x + ssCell.box.width / 2;
      const cy = ssCell.box.y + ssCell.box.height / 2;
      const modKey = modifier === 'ctrl' ? 'Control' : modifier === 'shift' ? 'Shift' : null;
      if (modKey) await page.keyboard.down(modKey);
      if (dblclick) await page.mouse.dblclick(cx, cy);
      else await page.mouse.click(cx, cy);
      if (modKey) await page.keyboard.up(modKey);
      await waitForStable();
      const state = await getFormState();
      state.clicked = { kind: 'spreadsheetCell', name: ssCell.text, ...(dblclick ? { dblclick: true } : {}) };
      return state;
    }
    throw new Error(`clickElement: "${text}" not found. Available: ${target.available?.join(', ') || 'none'}`);
  }

  // Helper: click with optional modifier key (Ctrl/Shift for multi-select)
  const modKey = modifier === 'ctrl' ? 'Control' : modifier === 'shift' ? 'Shift' : null;
  async function modClick(x, y) {
    if (modKey) await page.keyboard.down(modKey);
    await page.mouse.click(x, y);
    if (modKey) await page.keyboard.up(modKey);
  }
  async function modDblClick(x, y) {
    if (modKey) await page.keyboard.down(modKey);
    await page.mouse.dblclick(x, y);
    if (modKey) await page.keyboard.up(modKey);
  }

  // Grid row targets — use coordinate click (single or double)
  if (target.kind === 'gridGroup' || target.kind === 'gridParent') {
    if (expand != null || toggle) {
      // Expand/collapse group in hierarchy mode — click the triangle icon (.gridListH/.gridListV).
      // expand=true: only expand (skip if already expanded), expand=false: only collapse, toggle: always click.
      const levelIconInfo = await getGridToggleIcon(target, formNum, {
        iconSelector: '.gridListH, .gridListV',
        isExpandedExpr: "icon.classList.contains('gridListV')",
      });
      const shouldClick = shouldClickToggle(levelIconInfo, expand, toggle);
      if (shouldClick) {
        if (levelIconInfo) {
          await modClick(levelIconInfo.x, levelIconInfo.y);
        } else {
          // Fallback: dblclick (standard hierarchy navigation)
          await modDblClick(target.x, target.y);
        }
      }
      await waitForStable(formNum);
      const state = await getFormState();
      state.clicked = { kind: target.kind, name: target.name, toggled: shouldClick, ...(modifier ? { modifier } : {}) };
      state.hint = shouldClick ? 'Group toggled. Use readTable to see updated list.' : 'Group already in desired state.';
      return state;
    }
    // Default: dblclick to enter group / go up to parent
    await modDblClick(target.x, target.y);
    await waitForStable(formNum);
    const state = await getFormState();
    state.clicked = { kind: target.kind, name: target.name, ...(modifier ? { modifier } : {}) };
    return state;
  }
  if (target.kind === 'gridTreeNode') {
    if (expand != null || toggle) {
      // Expand/collapse tree node — click the tree icon [tree="true"].
      // expand=true: only expand (skip if already expanded), expand=false: only collapse, toggle: always click.
      const treeIconInfo = await getGridToggleIcon(target, formNum, {
        iconSelector: '.gridBoxImg [tree="true"]',
        isExpandedExpr: '(icon.style.backgroundImage || "").includes("gx=0")',
      });
      const shouldClick = shouldClickToggle(treeIconInfo, expand, toggle);
      if (shouldClick) {
        if (treeIconInfo) {
          await modClick(treeIconInfo.x, treeIconInfo.y);
        } else {
          // Fallback: dblclick on row (works for trees without clickable +/- icons)
          await modDblClick(target.x, target.y);
        }
      }
      await waitForStable(formNum);
      const state = await getFormState();
      state.clicked = { kind: 'gridTreeNode', name: target.name, toggled: shouldClick, ...(modifier ? { modifier } : {}) };
      state.hint = shouldClick ? 'Tree node toggled. Use readTable to see updated tree.' : 'Tree node already in desired state.';
      return state;
    }
    // Default: select row (click text, no expand/collapse)
    await modClick(target.x, target.y);
    await waitForStable(formNum);
    const state = await getFormState();
    state.clicked = { kind: 'gridTreeNode', name: target.name, ...(modifier ? { modifier } : {}) };
    state.hint = 'Row selected. Use { expand: true } to expand/collapse.';
    return state;
  }
  if (target.kind === 'gridRow') {
    if (dblclick) {
      await modDblClick(target.x, target.y);
      await waitForStable();
      const state = await getFormState();
      state.clicked = { kind: 'gridRow', name: target.name, dblclick: true, ...(modifier ? { modifier } : {}) };
      return state;
    }
    await modClick(target.x, target.y);
    await waitForStable();
    const state = await getFormState();
    state.clicked = { kind: 'gridRow', name: target.name, ...(modifier ? { modifier } : {}) };
    return state;
  }

  // Start CDP network monitor BEFORE the click for buttons —
  // so we capture all server requests triggered by the click.
  if (target.kind === 'button') {
    try { netMonitor = await startNetworkMonitor(); } catch {}
  }

  // Tabs without ID — use coordinate click to avoid global [data-content] ambiguity
  if (target.kind === 'tab' && !target.id && target.x && target.y) {
    await page.mouse.click(target.x, target.y);
  } else {
    const selector = `[id="${target.id}"]`;
    // Use Playwright click for proper mousedown/mouseup events
    await safeClick(selector, { timeout: 5000 });
  }

  // If submenu button — read popup items and return them as hints
  if (target.kind === 'submenu') {
    await page.waitForTimeout(ACTION_WAIT);
    const submenuItems = await page.evaluate(readSubmenuScript());
    const state = await getFormState();
    state.clicked = { kind: 'submenu', name: target.name };
    if (Array.isArray(submenuItems)) {
      state.submenu = submenuItems.map(i => i.name);
      state.hint = 'Call web_click again with a submenu item name to select it';
    }
    return state;
  }

  await waitForStable(formNum);

  // Check if the click opened a popup/submenu (split buttons like "Создать на основании")
  const openedPopup = await page.evaluate(readSubmenuScript());
  if (Array.isArray(openedPopup) && openedPopup.length > 0) {
    const state = await getFormState();
    state.clicked = { kind: 'submenu', name: target.name };
    state.submenu = openedPopup.map(i => i.name);
    state.hint = 'Call web_click again with a submenu item name to select it';
    return state;
  }

  // For buttons that trigger server-side operations (post, write, etc.),
  // the DOM may stabilize BEFORE the server response arrives.
  // Use waitForSelector to detect error modal — this doesn't block the JS event loop.
  // Skip for grid edit mode (e.g. "Добавить" row) — no server round-trip expected.
  if (target.kind === 'button') {
    const postForm = await page.evaluate(detectFormScript());
    if (postForm === formNum) {
      const inGridEdit = await page.evaluate(`(() => {
        const f = document.activeElement;
        if (!f || (f.tagName !== 'INPUT' && f.tagName !== 'TEXTAREA')) return false;
        let n = f; while (n) { if (n.classList?.contains('grid')) return true; n = n.parentElement; }
        return false;
      })()`);
      if (!inGridEdit && netMonitor) {
        // Form didn't change — server might still be processing.
        // CDP monitor was started before click — wait for all requests to complete
        // (300ms debounce) or for a modal/balloon/confirm to appear.
        await netMonitor.waitDone(timeout);
        await waitForStable();
      }
    }
  }

  // Form may have changed — re-detect
  const state = await getFormState();
  state.clicked = { kind: target.kind, name: target.name };
  const err = await checkForErrors();
  if (err) {
    state.errors = err;
    if (err.confirmation) {
      state.confirmation = err.confirmation;
      state.hint = 'Call web_click with a button name (e.g. "Да", "Нет", "Отмена") to respond';
    }
  }
  return state;

  } finally {
    if (netMonitor) try { await netMonitor.cleanup(); } catch {}
    if (highlightMode) try { await unhighlight(); } catch {}
  }
}
