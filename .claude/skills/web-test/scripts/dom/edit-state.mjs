// web-test dom/edit-state v1.0 — focus and popup detection inside the 1C web client
// Source: https://github.com/Nikolay-Shirokov/cc-1c-skills

/**
 * Is the currently focused element an INPUT (optionally TEXTAREA too)?
 * Returns boolean.
 *
 * @param {object} [opts]
 * @param {boolean} [opts.allowTextarea=false] — also return true for TEXTAREA.
 */
export function isInputFocusedScript({ allowTextarea = false } = {}) {
  const cond = allowTextarea
    ? `f.tagName === 'INPUT' || f.tagName === 'TEXTAREA'`
    : `f.tagName === 'INPUT'`;
  return `(() => {
    const f = document.activeElement;
    return !!(f && (${cond}));
  })()`;
}

/**
 * Is the currently focused INPUT/TEXTAREA inside a `.grid` ancestor?
 * Used to verify grid edit-mode (active cell editor).
 * Returns boolean.
 */
export function isInputFocusedInGridScript() {
  return `(() => {
    const f = document.activeElement;
    if (!f || (f.tagName !== 'INPUT' && f.tagName !== 'TEXTAREA')) return false;
    let n = f;
    while (n) {
      if (n.classList?.contains('grid')) return true;
      n = n.parentElement;
    }
    return false;
  })()`;
}

/**
 * Is a calculator (`.calculate`) or calendar (`.frameCalendar`) popup visible?
 * Returns `'calculator' | 'calendar' | null`.
 *
 * For the "popup gone" check, callers use: `!await findOpenPopup()`.
 */
export function findOpenPopupScript() {
  return `(() => {
    const calc = document.querySelector('.calculate');
    if (calc && calc.offsetWidth > 0) return 'calculator';
    const cal = document.querySelector('.frameCalendar');
    if (cal && cal.offsetWidth > 0) return 'calendar';
    return null;
  })()`;
}
