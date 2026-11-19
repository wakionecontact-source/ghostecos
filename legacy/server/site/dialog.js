/**
 * Унифицированные диалоги GhostEcos.
 * Заменяет нативные browser-окна (alert/confirm/prompt) на красивые модалки
 * в стиле экосистемы.
 *
 * Использование:
 *   await Dialog.alert("Сохранено");
 *   const ok = await Dialog.confirm("Удалить?", {danger: true});
 *   const name = await Dialog.prompt("Имя:", "по умолчанию", {placeholder: "..."});
 *
 * Возвращает Promise. confirm/prompt отдают null при отмене.
 */
(function (global) {
  const STYLE_ID = 'ge-dialog-styles';

  function ensureStyles() {
    if (document.getElementById(STYLE_ID)) return;
    const css = `
      .ge-dlg-overlay {
        position: fixed; inset: 0; z-index: 10000;
        background: rgba(2, 6, 23, 0.65); backdrop-filter: blur(6px);
        display: flex; align-items: center; justify-content: center;
        padding: 20px; opacity: 0; transition: opacity .15s;
        font-family: 'Inter', -apple-system, "Segoe UI", Roboto, sans-serif;
      }
      .ge-dlg-overlay.show { opacity: 1; }
      .ge-dlg-box {
        background: #0f172a; border: 1px solid rgba(255,255,255,0.13);
        border-radius: 16px; padding: 22px 22px 18px;
        width: 100%; max-width: 380px; color: #f1f5f9;
        box-shadow: 0 20px 60px rgba(0,0,0,0.6);
        transform: scale(0.96); transition: transform .18s cubic-bezier(0.34,1.56,0.64,1);
      }
      .ge-dlg-overlay.show .ge-dlg-box { transform: scale(1); }
      .ge-dlg-title {
        font-size: 16px; font-weight: 700; margin-bottom: 8px; line-height: 1.4;
      }
      .ge-dlg-msg {
        font-size: 13px; color: #94a3b8; line-height: 1.55;
        white-space: pre-wrap; word-break: break-word;
      }
      .ge-dlg-input {
        width: 100%; box-sizing: border-box; margin-top: 14px;
        background: rgba(0,0,0,0.3); border: 1px solid rgba(255,255,255,0.15);
        color: #f1f5f9; padding: 11px 13px; border-radius: 10px;
        font-family: inherit; font-size: 14px; outline: none;
        transition: border-color .15s;
      }
      .ge-dlg-input:focus { border-color: #a855f7; }
      .ge-dlg-actions {
        display: flex; gap: 8px; margin-top: 18px;
      }
      .ge-dlg-btn {
        flex: 1; padding: 11px; border-radius: 10px; border: none;
        font-weight: 700; cursor: pointer; font-family: inherit; font-size: 13px;
        transition: filter .15s, transform .05s;
      }
      .ge-dlg-btn:active { transform: scale(0.97); }
      .ge-dlg-btn:hover:not(:disabled) { filter: brightness(1.08); }
      .ge-dlg-btn:disabled { opacity: 0.5; cursor: default; }
      .ge-dlg-btn.cancel {
        background: transparent; color: #f1f5f9;
        border: 1px solid rgba(255,255,255,0.18);
      }
      .ge-dlg-btn.ok {
        background: linear-gradient(135deg, #a855f7, #ec4899); color: #fff;
      }
      .ge-dlg-btn.danger {
        background: linear-gradient(135deg, #f43f5e, #ec4899); color: #fff;
      }
    `;
    const tag = document.createElement('style');
    tag.id = STYLE_ID; tag.textContent = css;
    document.head.appendChild(tag);
  }

  function build(opts) {
    ensureStyles();
    const overlay = document.createElement('div');
    overlay.className = 'ge-dlg-overlay';
    const box = document.createElement('div');
    box.className = 'ge-dlg-box';
    overlay.appendChild(box);

    if (opts.title) {
      const t = document.createElement('div');
      t.className = 'ge-dlg-title';
      t.textContent = opts.title;
      box.appendChild(t);
    }
    if (opts.message) {
      const m = document.createElement('div');
      m.className = 'ge-dlg-msg';
      m.textContent = opts.message;
      box.appendChild(m);
    }
    let inputEl = null;
    if (opts.input) {
      inputEl = document.createElement('input');
      inputEl.className = 'ge-dlg-input';
      inputEl.type = 'text';
      if (opts.defaultValue != null) inputEl.value = opts.defaultValue;
      if (opts.placeholder) inputEl.placeholder = opts.placeholder;
      if (opts.maxLength) inputEl.maxLength = opts.maxLength;
      box.appendChild(inputEl);
    }
    const actions = document.createElement('div');
    actions.className = 'ge-dlg-actions';
    box.appendChild(actions);

    document.body.appendChild(overlay);
    // force reflow → анимация
    overlay.offsetWidth;
    overlay.classList.add('show');

    return { overlay, box, actions, inputEl };
  }

  function close(overlay) {
    overlay.classList.remove('show');
    setTimeout(() => { try { overlay.remove(); } catch(_){} }, 180);
  }

  function alertFn(message, opts = {}) {
    return new Promise(resolve => {
      const { overlay, actions } = build({
        title: opts.title || '',
        message: message,
      });
      const ok = document.createElement('button');
      ok.className = 'ge-dlg-btn ok';
      ok.textContent = opts.okText || 'ОК';
      ok.onclick = () => { close(overlay); resolve(); };
      actions.appendChild(ok);
      setTimeout(() => ok.focus(), 100);
    });
  }

  function confirmFn(message, opts = {}) {
    return new Promise(resolve => {
      const { overlay, actions } = build({
        title: opts.title || '',
        message: message,
      });
      // Once-guard — resolve может вызваться только раз (защита от двойного клика)
      let done = false;
      const finish = (v) => { if (done) return; done = true; close(overlay); resolve(v); };

      const cancel = document.createElement('button');
      cancel.className = 'ge-dlg-btn cancel';
      cancel.textContent = opts.cancelText || 'Отмена';
      cancel.onclick = () => finish(false);
      actions.appendChild(cancel);

      const ok = document.createElement('button');
      ok.className = 'ge-dlg-btn ' + (opts.danger ? 'danger' : 'ok');
      ok.textContent = opts.okText || (opts.danger ? 'Удалить' : 'ОК');
      ok.onclick = () => finish(true);
      actions.appendChild(ok);

      // keydown слушаем на document (overlay без tabindex не получит keyup)
      const onKey = (e) => {
        if (e.key === 'Escape') { e.preventDefault(); finish(false); document.removeEventListener('keydown', onKey); }
        else if (e.key === 'Enter') { e.preventDefault(); finish(true); document.removeEventListener('keydown', onKey); }
      };
      document.addEventListener('keydown', onKey);
      setTimeout(() => ok.focus(), 100);
    });
  }

  function promptFn(message, defaultValue = '', opts = {}) {
    return new Promise(resolve => {
      const { overlay, actions, inputEl } = build({
        title: opts.title || '',
        message: message,
        input: true,
        defaultValue: defaultValue,
        placeholder: opts.placeholder || '',
        maxLength: opts.maxLength,
      });
      // Once-guard — resolve вызывается только один раз
      let done = false;
      const finish = (v) => { if (done) return; done = true; close(overlay); resolve(v); };

      const cancel = document.createElement('button');
      cancel.className = 'ge-dlg-btn cancel';
      cancel.textContent = opts.cancelText || 'Отмена';
      cancel.onclick = () => finish(null);
      actions.appendChild(cancel);

      const ok = document.createElement('button');
      ok.className = 'ge-dlg-btn ' + (opts.danger ? 'danger' : 'ok');
      ok.textContent = opts.okText || 'ОК';
      ok.onclick = () => finish(inputEl.value);
      actions.appendChild(ok);

      inputEl.addEventListener('keydown', e => {
        if (e.key === 'Enter') { e.preventDefault(); finish(inputEl.value); }
        else if (e.key === 'Escape') { e.preventDefault(); finish(null); }
      });
      setTimeout(() => { inputEl.focus(); inputEl.select(); }, 100);
    });
  }

  global.Dialog = {
    alert: alertFn,
    confirm: confirmFn,
    prompt: promptFn,
  };
})(window);
