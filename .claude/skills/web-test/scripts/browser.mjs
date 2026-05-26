// web-test browser v1.16 — Playwright browser management for 1C web client
// Source: https://github.com/Nikolay-Shirokov/cc-1c-skills
/**
 * Playwright browser management for 1C web client.
 *
 * Maintains a single browser instance across MCP tool calls.
 * Handles connection, navigation, waiting, screenshots.
 */
import { chromium } from 'playwright';
import { spawn, execFileSync } from 'child_process';
import { statSync, mkdirSync, existsSync as fsExistsSync, writeFileSync, readFileSync, rmSync, readdirSync } from 'fs';
import { dirname, resolve as pathResolve, join as pathJoin, basename, extname } from 'path';
import { tmpdir } from 'os';
import { fileURLToPath, pathToFileURL } from 'url';
import {
  readSectionsScript, readTabsScript, readCommandsScript,
  readFormScript, navigateSectionScript, openCommandScript,
  findClickTargetScript, findFieldButtonScript, readSubmenuScript,
  resolveFieldsScript, getFormStateScript,
  detectFormScript, readTableScript, checkErrorsScript,
  switchTabScript, resolveGridScript
} from './dom.mjs';

// Module-level state, constants, normYo and resolveProjectPath live in core/state.mjs.
// Imported as live bindings — reads stay current; writes go through setters.
import {
  browser, page, sessionPrefix, seanceId, recorder,
  lastCaptions, lastRecordingDuration, highlightMode,
  persistentUserDataDir, preserveClipboard, clipboardWarnLogged,
  contexts, activeContextName, activeMode,
  setBrowser, setPage, setSessionPrefix, setSeanceId, setRecorder,
  setLastCaptions, setLastRecordingDuration, setHighlightMode,
  setPersistentUserDataDir, setActiveContextName, setActiveMode,
  setClipboardWarnLogged,
  LOAD_TIMEOUT, INIT_TIMEOUT, ACTION_WAIT, MAX_WAIT, POLL_INTERVAL, STABLE_CYCLES,
  EXT_ID, projectRoot, resolveProjectPath, normYo,
  isConnected, ensureConnected, getPage, setPreserveClipboard,
} from './core/state.mjs';

export { isConnected, getPage, setPreserveClipboard, ensureConnected };
export async function saveClipboard() {
  if (!page) return;
  try {
    await page.evaluate(async () => {
      try {
        const items = await navigator.clipboard.read();
        const saved = [];
        for (const item of items) {
          const types = {};
          for (const t of item.types) types[t] = await item.getType(t);
          saved.push(types);
        }
        window.__webTestSavedClipboard = saved;
        delete window.__webTestClipboardError;
      } catch (e) {
        window.__webTestSavedClipboard = null;
        window.__webTestClipboardError = e?.name || String(e);
      }
    });
  } catch {
    // page.evaluate itself failed (closed page, navigation in flight) — skip.
  }
}
export async function restoreClipboard() {
  if (!page) return;
  let err = null;
  try {
    err = await page.evaluate(async () => {
      const saved = window.__webTestSavedClipboard;
      const captured = window.__webTestClipboardError || null;
      delete window.__webTestSavedClipboard;
      delete window.__webTestClipboardError;
      try {
        if (!saved || saved.length === 0) {
          // Save failed (e.g. CF_HDROP from Explorer not readable via Clipboard API)
          // or buffer was empty. Either way, the test's writeText already destroyed
          // any prior native formats in the OS clipboard, so explicitly clear here
          // to avoid leaking the test value into the user's clipboard.
          await navigator.clipboard.writeText('');
          return captured;
        }
        const items = saved.map(types => new ClipboardItem(types));
        await navigator.clipboard.write(items);
        return null;
      } catch (e) {
        return e?.name || String(e);
      }
    });
  } catch {
    return;
  }
  if (err && !clipboardWarnLogged) {
    setClipboardWarnLogged(true);
    console.error(`[web-test] clipboard preserve skipped: ${err} (logged once per session)`);
  }
}

/**
 * Paste `text` via OS clipboard (the only trusted-paste path that 1C respects
 * for autocomplete and Cyrillic). Wraps the writeText+confirm-key pair in a
 * narrow save/restore so a user's clipboard survives the test run — the window
 * between save and restore is microseconds.
 *
 * - `confirm` — key (string) or sequence (array) to press after writeText.
 *   Defaults to 'Control+V'. Use ['Control+a', 'Control+v'] for select-all-then-paste,
 *   or 'Shift+F11' for the goto-link dialog.
 * - `postDelay` — ms to wait between confirm-press and restore, for dialogs
 *   that read clipboard asynchronously (e.g. Shift+F11). Default 0.
 */
export async function pasteText(text, { confirm = 'Control+V', postDelay = 0 } = {}) {
  if (!page) return;
  if (preserveClipboard) await saveClipboard();
  try {
    await page.evaluate(`navigator.clipboard.writeText(${JSON.stringify(String(text))})`);
    if (Array.isArray(confirm)) {
      for (const key of confirm) await page.keyboard.press(key);
    } else if (confirm) {
      await page.keyboard.press(confirm);
    }
    if (postDelay) await page.waitForTimeout(postDelay);
  } finally {
    if (preserveClipboard) await restoreClipboard();
  }
}

// ============================================================
// Session lifecycle + multi-context — extracted to core/session.mjs
// ============================================================
export {
  connect, disconnect, attach, detach, getSession,
  createContext, setActiveContext, listContexts, getActiveContext,
  hasContext, closeContext,
} from './core/session.mjs';

// ============================================================
// Wait + error/modal handling — extracted to core/{wait,errors}.mjs
// ============================================================
import {
  waitForStable, waitForCondition, startNetworkMonitor,
} from './core/wait.mjs';
import {
  closeModals, checkForErrors, dismissPendingErrors, fetchErrorStack,
  _detectPlatformDialogs, _closePlatformDialogs,
} from './core/errors.mjs';
import {
  safeClick, findFieldInputId, readEdd, returnFormState,
  detectNewForm as helperDetectNewForm,
} from './core/helpers.mjs';
import { getGridToggleIcon, shouldClickToggle } from './table/grid-toggle.mjs';
// Re-export only what was publicly exported before the refactor.
// waitForStable/waitForCondition/startNetworkMonitor/closeModals/checkForErrors/
// dismissPendingErrors are internal helpers — imported above for local use only.
export { fetchErrorStack } from './core/errors.mjs';

/* getPage moved to core/state.mjs */

// ============================================================
// Navigation — extracted to nav/navigation.mjs
// ============================================================
export {
  getPageState, getSections, navigateSection, getCommands,
  openCommand, switchTab, openFile, navigateLink,
} from './nav/navigation.mjs';

/** Read current form state. Single evaluate call via combined script. */
export async function getFormState() {
  ensureConnected();
  const state = await page.evaluate(getFormStateScript());
  const err = await checkForErrors();
  if (err) {
    state.errors = err;
    if (err.confirmation) {
      state.confirmation = err.confirmation;
      state.hint = 'Call web_click with a button name (e.g. "Да", "Нет", "Отмена") to respond';
    }
  }
  // Detect platform-level dialogs (About, Support Info, Error Report)
  // These are NOT 1C forms — invisible to detectForms() and not closeable via Escape.
  const pd = await _detectPlatformDialogs();
  if (pd.length) state.platformDialogs = pd;
  return state;
}

// ============================================================
// Table reading + SpreadsheetDocument — extracted to table/spreadsheet.mjs
// ============================================================
export { readTable } from './table/grid.mjs';
export { readSpreadsheet } from './table/spreadsheet.mjs';


// ============================================================
// Value selection (DLB/CB) — extracted to forms/select-value.mjs
// ============================================================
export { selectValue } from './forms/select-value.mjs';
import {
  selectValue, pickFromSelectionForm, isTypeDialog, pickFromTypeDialog,
  fillReferenceField,
} from './forms/select-value.mjs';



// ============================================================
// Fill fields — extracted to forms/fill.mjs
// ============================================================
export { fillFields, fillField } from './forms/fill.mjs';


// ============================================================
// clickElement dispatcher — extracted to core/click.mjs
// ============================================================
export { clickElement } from './core/click.mjs';
import { clickElement } from './core/click.mjs';

// ============================================================
// Close form — extracted to forms/close.mjs
// ============================================================
export { closeForm } from './forms/close.mjs';



// ============================================================
// fillTableRow / deleteTableRow — extracted to table/{row-fill,grid}.mjs
// ============================================================
export { fillTableRow } from './table/row-fill.mjs';
export { deleteTableRow } from './table/grid.mjs';

// ============================================================
// List filters — extracted to table/filter.mjs
// ============================================================
export { filterList, unfilterList } from './table/filter.mjs';


// ============================================================
// Recording, captions, narration, highlight — extracted to recording/*
// ============================================================
export {
  screenshot, wait, isRecording, startRecording, stopRecording,
} from './recording/capture.mjs';
export {
  showCaption, hideCaption, getCaptions,
  showTitleSlide, hideTitleSlide,
  showImage, hideImage,
} from './recording/captions.mjs';
export {
  highlight, unhighlight, setHighlight, isHighlightMode,
} from './recording/highlight.mjs';
export { addNarration } from './recording/narration.mjs';

/* ensureConnected moved to core/state.mjs */
