// web-test dom/grid v1.3 — grid resolution + table reading + edit-time helpers
// Source: https://github.com/Nikolay-Shirokov/cc-1c-skills

/**
 * Resolve a specific grid by semantic name (table parameter).
 * Cascade: exact gridName match → gridName contains → column contains.
 * Returns { gridSelector, gridId, gridName, gridIndex, columns } or { error, available }.
 */
export function resolveGridScript(formNum, tableName) {
  const p = `form${formNum}_`;
  return `(() => {
    const p = ${JSON.stringify(p)};
    const target = ${JSON.stringify(tableName.toLowerCase().replace(/ё/g, 'е'))};
    const norm = s => (s || '').replace(/ё/gi, 'е');
    const allGrids = [...document.querySelectorAll('[id^="' + p + '"].grid, [id^="' + p + '"] .grid')]
      .filter(g => g.offsetWidth > 0 && g.offsetHeight > 0);
    if (!allGrids.length) return { error: 'no_grids', message: 'No grids found on form' };
    const infos = allGrids.map((g, idx) => {
      const gridId = g.id || '';
      const gridName = gridId.replace(p, '');
      const head = g.querySelector('.gridHead');
      const columns = [];
      if (head) {
        const headLine = head.querySelector('.gridLine') || head;
        [...headLine.children].forEach(box => {
          if (box.offsetWidth === 0) return;
          const textEl = box.querySelector('.gridBoxText');
          const text = (textEl || box).innerText?.trim().replace(/\\n/g, ' ') || '';
          if (text) columns.push(text);
        });
      }
      // Visual label from group title element
      const titleEl = document.getElementById(p + gridName + '#title_div')
                   || document.getElementById(p + 'Группа' + gridName + '#title_div');
      const label = titleEl ? (titleEl.innerText?.trim().replace(/:\s*$/, '').replace(/ /g, ' ') || '') : '';
      return { idx, gridId, gridName, label, columns, el: g };
    });
    // 1. Exact gridName match (case-insensitive)
    let found = infos.find(i => norm(i.gridName).toLowerCase() === target);
    // 2. Exact label match
    if (!found) found = infos.find(i => i.label && norm(i.label).toLowerCase() === target);
    // 3. gridName contains target
    if (!found) found = infos.find(i => norm(i.gridName).toLowerCase().includes(target));
    // 4. Label contains target
    if (!found) found = infos.find(i => i.label && norm(i.label).toLowerCase().includes(target));
    // 5. Any column contains target
    if (!found) found = infos.find(i => i.columns.some(c => norm(c).toLowerCase().includes(target)));
    if (found) {
      return {
        gridSelector: found.gridId ? '#' + CSS.escape(found.gridId) : null,
        gridId: found.gridId,
        gridName: found.gridName,
        gridIndex: found.idx,
        columns: found.columns
      };
    }
    return {
      error: 'not_found',
      message: 'Table "' + ${JSON.stringify(tableName)} + '" not found',
      available: infos.map(i => ({ name: i.gridName, ...(i.label ? { label: i.label } : {}), columns: i.columns }))
    };
  })()`;
}

/**
 * Read table/grid data with pagination.
 * Parses grid.innerText — \n separates rows, \t separates cells.
 * First row = column headers.
 * Returns { name, columns[], rows[{col:val}], total, offset, shown }.
 */
export function readTableScript(formNum, { maxRows = 20, offset = 0, gridSelector } = {}) {
  const p = `form${formNum}_`;
  return `(() => {
    const p = ${JSON.stringify(p)};
    const grid = ${gridSelector
      ? `document.querySelector(${JSON.stringify(gridSelector)})`
      : `[...document.querySelectorAll('[id^="' + p + '"].grid, [id^="' + p + '"] .grid')]
      .find(g => g.offsetWidth > 0 && g.offsetHeight > 0)`};
    if (!grid) return { error: 'no_table', message: 'No table found on form ${formNum}' };
    const name = grid.id ? grid.id.replace(p, '') : '';

    // DOM-based parsing: gridHead → columns, gridBody → gridLine rows → gridBox cells
    const head = grid.querySelector('.gridHead');
    const body = grid.querySelector('.gridBody');
    if (!head || !body) {
      // Fallback: innerText-based (for non-standard grids)
      const gText = grid.innerText?.trim() || '';
      const lines = gText.split('\\n').filter(Boolean);
      return { name, columns: [], rows: [], total: lines.length, offset: 0, shown: 0,
               hint: 'Grid has no gridHead/gridBody structure' };
    }

    // Extract column headers with X-coordinates for alignment
    const columns = [];
    const headLine = head.querySelector('.gridLine') || head;
    [...headLine.children].forEach(box => {
      if (box.offsetWidth === 0) return;
      const textEl = box.querySelector('.gridBoxText');
      const text = (textEl || box).innerText?.trim().replace(/\\n/g, ' ') || '';
      if (!text) {
        // Unnamed column — check if data cells contain checkboxes
        const firstLine = body?.querySelector('.gridLine');
        if (firstLine) {
          const visibleHeaders = [...headLine.children].filter(c => c.offsetWidth > 0);
          const idx = visibleHeaders.indexOf(box);
          const cells = [...firstLine.children].filter(c => c.offsetWidth > 0);
          if (cells[idx]?.querySelector('.checkbox')) {
            const r = box.getBoundingClientRect();
            columns.push({ text: '(checkbox)', x: r.x, w: r.width, right: r.x + r.width, y: r.y, h: r.height });
          }
        }
        return;
      }
      const r = box.getBoundingClientRect();
      columns.push({ text, x: r.x, w: r.width, right: r.x + r.width, y: r.y, h: r.height });
    });

    // Multi-row grid support: detect stacked/merged headers.
    // Group headers by X-range. For each group, count data sub-rows from first line.
    // - Stacked headers (2+ headers at same X) with multiple data rows → match by Y-order
    // - Single merged header with multiple data rows → expand to numbered columns (e.g. "Субконто Дт 1")
    const xGroups = new Map();
    columns.forEach(c => {
      const key = Math.round(c.x) + ':' + Math.round(c.right);
      if (!xGroups.has(key)) xGroups.set(key, []);
      xGroups.get(key).push(c);
    });
    for (const [, hdrs] of xGroups) hdrs.sort((a, b) => a.y - b.y);

    const firstDataLine = body?.querySelector('.gridLine');
    const subRowMap = new Map();
    if (firstDataLine) {
      [...firstDataLine.children].forEach(box => {
        if (box.offsetWidth === 0) return;
        const r = box.getBoundingClientRect();
        const cx = r.x + r.width / 2;
        for (const [key, hdrs] of xGroups) {
          const h0 = hdrs[0];
          if (cx >= h0.x && cx < h0.right) {
            if (!subRowMap.has(key)) subRowMap.set(key, []);
            subRowMap.get(key).push({ y: r.y });
            break;
          }
        }
      });
      for (const [, subs] of subRowMap) subs.sort((a, b) => a.y - b.y);
    }

    const multiRowGroups = new Map();
    for (const [key, hdrs] of xGroups) {
      const subs = subRowMap.get(key);
      if (!subs || subs.length <= 1) continue;
      if (hdrs.length >= 2) {
        multiRowGroups.set(key, hdrs);
      } else if (hdrs.length === 1 && subs.length > 1) {
        const base = hdrs[0];
        const baseIdx = columns.indexOf(base);
        columns.splice(baseIdx, 1);
        const expanded = [];
        for (let si = 0; si < subs.length; si++) {
          const numbered = {
            text: base.text + ' ' + (si + 1),
            x: base.x, w: base.w, right: base.right,
            y: base.y + si, h: base.h / subs.length, _subIdx: si
          };
          columns.splice(baseIdx + si, 0, numbered);
          expanded.push(numbered);
        }
        multiRowGroups.set(key, expanded);
      }
    }

    function matchColumn(cellX, cellW, cellY) {
      const cx = cellX + cellW / 2;
      for (const [key, hdrs] of multiRowGroups) {
        const h0 = hdrs[0];
        if (cx >= h0.x && cx < h0.right) {
          const subs = subRowMap.get(key);
          if (subs) {
            const subIdx = subs.findIndex(s => Math.abs(s.y - cellY) < 5);
            if (subIdx >= 0 && subIdx < hdrs.length) return hdrs[subIdx];
          }
          let best = hdrs[0], bestDist = Infinity;
          for (const h of hdrs) {
            const dist = Math.abs(cellY - h.y);
            if (dist < bestDist) { bestDist = dist; best = h; }
          }
          return best;
        }
      }
      return columns.find(c => cx >= c.x && cx < c.right);
    }

    // Extract data rows from gridBody
    const allLines = body.querySelectorAll('.gridLine');
    const total = allLines.length;
    const rows = [];
    const end = Math.min(${offset} + ${maxRows}, total);
    for (let i = ${offset}; i < end; i++) {
      const line = allLines[i];
      if (!line) break;
      const row = {};
      columns.forEach(c => { row[c.text] = ''; });
      [...line.children].forEach(box => {
        if (box.offsetWidth === 0) return;
        const textEl = box.querySelector('.gridBoxText');
        const chk = box.querySelector('.checkbox');
        let val;
        if (chk) {
          val = chk.classList.contains('select') ? 'true' : 'false';
        } else {
          val = (textEl || box).innerText?.trim().replace(/\\n/g, ' ') || '';
          if (!val) return;
        }
        // Match cell to column by X+Y overlap (multi-row aware)
        const r = box.getBoundingClientRect();
        const col = matchColumn(r.x, r.width, r.y);
        if (col) {
          row[col.text] = row[col.text] ? row[col.text] + ' / ' + val : val;
        }
      });
      // Detect row kind: group (gridListH), parent/up (gridListV), or element
      const imgBox = line.querySelector('.gridBoxImg');
      if (imgBox) {
        if (imgBox.querySelector('.gridListH')) row._kind = 'group';
        else if (imgBox.querySelector('.gridListV')) row._kind = 'parent';
      }
      // Tree mode: detect expand/collapse state and indent level
      const treeBox = line.querySelector('.gridBoxTree');
      if (treeBox) {
        const treeIcon = imgBox?.querySelector('[tree="true"]');
        if (treeIcon) {
          const bg = treeIcon.style.backgroundImage || '';
          row._tree = bg.includes('gx=0') ? 'expanded' : 'collapsed';
        }
        row._level = imgBox ? imgBox.querySelectorAll('.dIB').length - 1 : 0;
      }
      // Selection state: selRow = selected row in grid
      if (line.classList.contains('selRow') || line.classList.contains('select')) row._selected = true;
      rows.push(row);
    }
    const isTree = !!body.querySelector('.gridBoxTree');
    const hasGroups = rows.some(r => r._kind === 'group');
    const result = { name, columns: columns.map(c => c.text), rows, total, offset: ${offset}, shown: rows.length };
    if (isTree) result.viewMode = 'tree';
    if (hasGroups) result.hierarchical = true;
    return result;
  })()`;
}

// ─── Edit-time grid helpers (for fillTableRow / row-fill) ────────────────────
//
// All helpers below accept an optional `gridSelector`. When passed, they target
// that exact grid; when null/undefined they pick the LAST visible `.grid` on
// the page (this matches the implicit "current grid" used by row-fill).

/** Inline JS fragment that resolves the target grid into `const grid`. */
function gridResolver(gridSelector) {
  return gridSelector
    ? `document.querySelector(${JSON.stringify(gridSelector)})`
    : `(() => { const grids = [...document.querySelectorAll('.grid')].filter(el => el.offsetWidth > 0); return grids[grids.length - 1]; })()`;
}

/**
 * Find center coords of a target row for click-select (used by deleteTableRow).
 * Picks the second visible gridBox container in the row (skips row-number/checkbox col).
 *
 * Returns `{ x, y, total } | { error: 'no_grid'|'no_grid_body'|'row_out_of_range'|'no_cell', total? }`.
 */
export function findDeleteRowCoordsScript(gridSelector, row) {
  return `(() => {
    const grid = ${gridResolver(gridSelector)};
    if (!grid) return { error: 'no_grid' };
    const body = grid.querySelector('.gridBody');
    if (!body) return { error: 'no_grid_body' };
    const rows = [...body.querySelectorAll('.gridLine')];
    if (${row} >= rows.length) return { error: 'row_out_of_range', total: rows.length };
    const line = rows[${row}];
    // Use visible gridBox containers (not gridBoxText) to avoid clicking checkboxes
    const boxes = [...line.children].filter(b => b.offsetWidth > 0 && !b.classList.contains('gridBoxComp'));
    // Skip first column (row number / checkbox) — pick second visible box
    const box = boxes.length > 1 ? boxes[1] : boxes[0];
    if (!box) return { error: 'no_cell' };
    const cell = box.querySelector('.gridBoxText') || box;
    const r = cell.getBoundingClientRect();
    return { x: Math.round(r.x + r.width / 2), y: Math.round(r.y + r.height / 2), total: rows.length };
  })()`;
}

/**
 * Count `.gridLine` rows in the body of the target grid.
 * Returns the row count, or `0` when grid/body absent.
 */
export function countGridRowsScript(gridSelector) {
  return `(() => {
    const grid = ${gridResolver(gridSelector)};
    const body = grid?.querySelector('.gridBody');
    return body ? body.querySelectorAll('.gridLine').length : 0;
  })()`;
}

/**
 * Is the target grid a tree grid? (presence of `.gridBoxTree`)
 * Returns boolean.
 */
export function isTreeGridScript(gridSelector) {
  return `(() => {
    const grid = ${gridResolver(gridSelector)};
    return grid ? !!grid.querySelector('.gridBoxTree') : false;
  })()`;
}

/**
 * Return center coords of the grid's `.gridHead` element.
 * Used as a click target to commit a pending cell edit (clicking the header
 * defocuses the input without selecting another row).
 *
 * Returns `{ x, y } | null`.
 */
export function findGridHeadCenterCoordsScript(gridSelector) {
  return `(() => {
    const grid = ${gridResolver(gridSelector)};
    if (!grid) return null;
    const head = grid.querySelector('.gridHead');
    if (!head) return null;
    const r = head.getBoundingClientRect();
    return { x: Math.round(r.x + r.width / 2), y: Math.round(r.y + r.height / 2) };
  })()`;
}

/**
 * Return the index of the currently selected row in the target grid, or
 * fall back to the last row when nothing is selected.
 *
 * Returns row index, or `-1` when no rows.
 */
export function getSelectedOrLastRowIndexScript(gridSelector) {
  return `(() => {
    const grid = ${gridResolver(gridSelector)};
    if (!grid) return -1;
    const body = grid.querySelector('.gridBody');
    if (!body) return -1;
    const lines = [...body.querySelectorAll('.gridLine')];
    const sel = lines.findIndex(l => l.classList.contains('selected'));
    return sel >= 0 ? sel : lines.length - 1;
  })()`;
}

/**
 * Scan a form's grid for a row matching `searchLower` (case- and ё-insensitive,
 * NBSP-normalised). Match order: exact → startsWith → includes.
 *
 * When `searchLower` is empty, returns coords of the first row (fallback).
 *
 * Returns `{ rowCount, x, y, isGroup } | { rowCount: 0 } | null`.
 */
export function scanGridRowsScript(formNum, searchLower) {
  return `(() => {
    const p = 'form${formNum}_';
    const grid = document.querySelector('[id^="' + p + '"].grid, [id^="' + p + '"] .grid');
    if (!grid) return null;
    const body = grid.querySelector('.gridBody');
    if (!body) return null;
    const lines = [...body.querySelectorAll('.gridLine')];
    if (!lines.length) return { rowCount: 0 };
    const searchLower = ${JSON.stringify(searchLower || '')};
    let sel = null;
    if (searchLower) {
      const norm = s => (s || '').replace(/\\u00a0/g, ' ').trim().toLowerCase().replace(/ё/gi, 'е');
      const rowData = lines.map(l => ({ el: l, text: norm(l.innerText) }));
      sel = rowData.find(r => r.text === searchLower)?.el
        || rowData.find(r => r.text.startsWith(searchLower))?.el
        || rowData.find(r => r.text.includes(searchLower))?.el;
    } else {
      sel = lines[0]; // empty search → first row
    }
    if (!sel) return null;
    const imgBox = sel.querySelector('.gridBoxImg');
    const isGroup = imgBox ? !!imgBox.querySelector('.gridListH') : false;
    const r = sel.getBoundingClientRect();
    return { rowCount: lines.length, x: Math.round(r.x + r.width / 2), y: Math.round(r.y + r.height / 2), isGroup };
  })()`;
}
