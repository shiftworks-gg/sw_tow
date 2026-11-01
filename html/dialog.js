// Shiftworks Tow: the impound counter, the officer's holds and the tow order, as one window in the
// middle of the screen. Lua opens it with { type: 'dialog', kind, data, focus } and gets the player's
// choices back through the 'dialog' NUI callback; the server decides, this page only asks.
(() => {
  'use strict';

  // Tabler Icons 3.48.0 (MIT, https://tabler.io/icons), outline paths.
  const ICONS = {
    x: '<path d="M18 6l-12 12"/><path d="M6 6l12 12"/>',
    car: '<path d="M5 17a2 2 0 1 0 4 0a2 2 0 1 0 -4 0"/><path d="M15 17a2 2 0 1 0 4 0a2 2 0 1 0 -4 0"/><path d="M5 17h-2v-6l2 -5h9l4 5h1a2 2 0 0 1 2 2v4h-2m-4 0h-6m-6 -6h15m-6 0v-5"/>',
    shield: '<path d="M12 3a12 12 0 0 0 8.5 3a12 12 0 0 1 -8.5 15a12 12 0 0 1 -8.5 -15a12 12 0 0 0 8.5 -3"/>',
    clock: '<path d="M3 12a9 9 0 1 0 18 0a9 9 0 0 0 -18 0"/><path d="M12 7v5l3 3"/>',
    cash: '<path d="M7 11a2 2 0 0 1 2 -2h10a2 2 0 0 1 2 2v6a2 2 0 0 1 -2 2h-10a2 2 0 0 1 -2 -2z"/><path d="M12 14a2 2 0 1 0 4 0a2 2 0 1 0 -4 0"/><path d="M17 9v-2a2 2 0 0 0 -2 -2h-10a2 2 0 0 0 -2 2v6a2 2 0 0 0 2 2h2"/>',
    bank: '<path d="M3 21h18"/><path d="M3 10h18"/><path d="M5 6l7 -3l7 3"/><path d="M4 10v11"/><path d="M20 10v11"/><path d="M8 14v3"/><path d="M12 14v3"/><path d="M16 14v3"/>',
    lock: '<path d="M5 13a2 2 0 0 1 2 -2h10a2 2 0 0 1 2 2v6a2 2 0 0 1 -2 2h-10a2 2 0 0 1 -2 -2v-6z"/><path d="M11 16a1 1 0 1 0 2 0a1 1 0 0 0 -2 0"/><path d="M8 11v-4a4 4 0 1 1 8 0v4"/>',
    unlock: '<path d="M5 13a2 2 0 0 1 2 -2h10a2 2 0 0 1 2 2v6a2 2 0 0 1 -2 2h-10a2 2 0 0 1 -2 -2v-6z"/><path d="M11 16a1 1 0 1 0 2 0a1 1 0 0 0 -2 0"/><path d="M8 11v-5a4 4 0 0 1 8 0"/>',
    key: '<path d="M16.555 3.843l3.602 3.602a2.877 2.877 0 0 1 0 4.069l-2.643 2.643a2.877 2.877 0 0 1 -4.069 0l-.301 -.301l-6.558 6.558a2 2 0 0 1 -1.239 .578l-.175 .008h-1.172a1 1 0 0 1 -.993 -.883l-.007 -.117v-1.172a2 2 0 0 1 .467 -1.284l.119 -.13l.414 -.414h2v-2h2v-2l2.144 -2.144l-.301 -.301a2.877 2.877 0 0 1 0 -4.069l2.643 -2.643a2.877 2.877 0 0 1 4.069 0z"/><path d="M15 9h.01"/>',
    pin: '<path d="M9 11a3 3 0 1 0 6 0a3 3 0 0 0 -6 0"/><path d="M17.657 16.657l-4.243 4.243a2 2 0 0 1 -2.827 0l-4.244 -4.243a8 8 0 1 1 11.314 0"/>',
    send: '<path d="M10 14l11 -11"/><path d="M21 3l-6.5 18a.55 .55 0 0 1 -1 0l-3.5 -7l-7 -3.5a.55 .55 0 0 1 0 -1l18 -6.5"/>',
    chev: '<path d="M9 6l6 6l-6 6"/>',
  };

  const root = document.getElementById('dialog');
  let strings = {};
  let kind = null;
  let data = null;
  let selected = 0;
  let account = null;
  let busy = false;
  let error = '';
  let form = null;

  const icon = (name, cls = '') => `<svg class="ic ${cls}" viewBox="0 0 24 24" aria-hidden="true">${ICONS[name] || ''}</svg>`;
  const esc = (s) => String(s ?? '').replace(/[&<>"]/g, (c) => ({ '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;' }[c]));
  const t = (key, ...args) => {
    let i = 0;
    return (strings[key] || key).replace(/%s/g, () => String(args[i++] ?? ''));
  };
  const money = (n) => '$' + Math.round(n || 0).toLocaleString('en-US');

  // "1 d 4 h", "5 h 40 min", "12 min"
  function duration(seconds) {
    const s = Math.max(0, Math.floor(seconds || 0));
    const d = Math.floor(s / 86400);
    const h = Math.floor((s % 86400) / 3600);
    const m = Math.floor((s % 3600) / 60);
    if (d > 0) return [t('d', d), h ? t('h', h) : ''].filter(Boolean).join(' ');
    if (h > 0) return [t('h', h), m ? t('min', m) : ''].filter(Boolean).join(' ');
    return t('min', Math.max(1, m));
  }

  function post(body) {
    if (typeof GetParentResourceName !== 'function') return Promise.resolve({});
    return fetch(`https://${GetParentResourceName()}/dialog`, { method: 'POST', body: JSON.stringify(body) })
      .then((r) => r.json()).catch(() => ({}));
  }

  function close() {
    if (!kind) return;
    kind = null;
    root.hidden = true;
    root.innerHTML = '';
    post({ action: 'close' });
  }

  // Shared parts -----------------------------------------------------------------------------------

  const header = (plate, title) => `
    <div class="dlg__hd">${plate ? `<span class="plate">${esc(plate)}</span>` : ''}<h1>${esc(title)}</h1>
      <button class="dlg__x" data-act="close" aria-label="${esc(t('close'))}">${icon('x')}</button></div>`;

  const list = (title, items, line) => `
    <div class="dlg__left"><div class="lbl">${esc(title)}</div>
      ${items.map((item, i) => `<button class="dlg__opt ${i === selected ? 'is-on' : ''} ${item.held ? 'is-held' : ''}" data-pick="${i}">
        ${line(item)}${icon('chev', 'chev')}</button>`).join('')}
    </div>`;

  const shell = (left, right) => `<div class="dlg__dim"></div><div class="dlg__win" role="dialog">${left}<div class="dlg__right">${right}</div></div>`;

  // Counter ------------------------------------------------------------------------------------------

  function reasonChip(item) {
    const police = item.reason === 'police';
    const label = t('reason_' + item.reason) + (police && item.note ? ' · ' + item.note : '');
    return `<span class="dlg__chip ${police ? 'is-accent' : ''}">${icon(police ? 'shield' : 'car')}${esc(label)}</span>`;
  }

  function feeRows(p) {
    const rows = [[t('fee_base'), p.base]];
    if (p.class > 0) rows.push([t('fee_class'), p.class]);
    if (p.days > 0) rows.push([p.days === 1 ? t('fee_storage_one') : t('fee_storage', p.days), p.storage]);
    if (p.fine > 0) rows.push([t('fee_fine'), p.fine]);
    if (p.tow > 0) rows.push([t('fee_tow'), p.tow]);
    return `<div class="dlg__rows">${rows.map(([label, value]) => `<div class="dlg__row"><span>${esc(label)}</span><i></i><b>${money(value)}</b></div>`).join('')}</div>`;
  }

  // The account to pay from: the one picked if it still covers the fee, else cash, else bank.
  function payAccount(item) {
    const m = data.money || {};
    if (account && (m[account] || 0) >= item.fee) return account;
    if ((m.cash || 0) >= item.fee) return 'cash';
    if ((m.bank || 0) >= item.fee) return 'bank';
    return null;
  }

  function counter() {
    const item = data.items[selected];
    const left = list(data.title, data.items, (it) => `${icon(it.held ? 'lock' : 'car')}<div><b>${esc(it.label)}</b>
      ${it.held ? `<small>${esc(it.holdLeft != null ? t('hold_left', duration(it.holdLeft)) : t('hold_open'))}</small>` : `<span class="plate">${esc(it.plate)}</span>`}</div>`);

    let body;
    if (item.held) {
      body = `<div class="dlg__held">${icon('lock')}<div><b>${esc(item.holdLeft != null ? t('hold_left', duration(item.holdLeft)) : t('hold_open'))}</b>
        <span>${esc(t('hold_text'))}</span></div></div>
        <button class="dlg__btn" disabled>${icon('lock')}${esc(t('held_button'))}</button>`;
    } else {
      const use = payAccount(item);
      const m = data.money || {};
      const seg = ['cash', 'bank'].map((acc) => `<button data-acc="${acc}" class="${use === acc ? 'is-on' : ''}" ${(m[acc] || 0) < item.fee ? 'disabled' : ''}>
        ${icon(acc)}<span><b>${esc(t(acc))}</b><small>${money(m[acc])}</small></span></button>`).join('');
      body = `<div class="dlg__cols">${feeRows(item.parts)}
          <div class="dlg__rows"><div class="dlg__total"><span class="muted">${esc(t('to_pay'))}</span><b>${money(item.fee)}</b></div><div class="dlg__seg">${seg}</div></div></div>
        <div class="dlg__error">${esc(error || (use ? '' : t('not_enough')))}</div>
        <button class="dlg__btn" data-act="pay" ${busy || !use ? 'disabled' : ''}>${icon('key')}${esc(busy ? t('paying') : t('pay'))}</button>`;
    }
    const right = `${header(item.plate, item.label)}
      <div class="dlg__chips">${reasonChip(item)}<span class="dlg__chip">${icon('clock')}${esc(t('here_for', duration(item.storedFor)))}</span></div>
      ${body}
      <div class="dlg__keys"><kbd>Esc</kbd>${esc(t('close'))}${item.held ? '' : `<span style="flex:1"></span><kbd>Enter</kbd>${esc(t('pay_short'))}`}</div>`;
    return shell(left, right);
  }

  // Holds (officers) -------------------------------------------------------------------------------

  function holds() {
    const item = data.items[selected];
    const left = list(data.title, data.items, (it) => `${icon('lock')}<div><b>${esc(it.label)}</b><span class="plate">${esc(it.plate)}</span></div>`);
    const right = `${header(item.plate, item.label)}
      <div class="dlg__chips"><span class="dlg__chip is-danger">${icon('lock')}${esc(item.holdLeft != null ? t('hold_left', duration(item.holdLeft)) : t('hold_open'))}</span>
        ${item.fine > 0 ? `<span class="dlg__chip is-accent">${icon('shield')}${esc(t('fine_of', money(item.fine)))}</span>` : ''}
        <span class="dlg__chip">${icon('clock')}${esc(t('here_for', duration(item.storedFor)))}</span></div>
      ${item.note ? `<p class="dlg__note">${esc(item.note)}</p>` : ''}
      <div class="dlg__error">${esc(error)}</div>
      <button class="dlg__btn is-danger" data-act="lift" ${busy ? 'disabled' : ''}>${icon('unlock')}${esc(busy ? t('lifting') : t('lift'))}</button>
      <div class="dlg__keys"><kbd>Esc</kbd>${esc(t('close'))}</div>`;
    return shell(left, right);
  }

  // Tow order (officers) ---------------------------------------------------------------------------

  function holdChoices() {
    const max = data.maxHoldHours || 0;
    return [0, 1, 6, 24, 48, 72].filter((h) => h === 0 || h <= max);
  }

  function order() {
    const left = `<div class="dlg__left"><div class="lbl">${esc(t('vehicle'))}</div>
      <div class="dlg__veh"><span class="plate">${esc(data.plate)}</span><h2>${esc(data.label)}</h2>
        ${data.street ? `<p>${icon('pin')}${esc(data.street)}</p>` : ''}</div></div>`;
    const fines = [0, 250, 500, 1000, 2500].filter((f) => f <= data.maxFine);
    const right = `${header('', t('order_title'))}
      <div class="dlg__field"><label for="dlg-reason">${esc(t('reason'))}</label>
        <textarea id="dlg-reason" rows="2" maxlength="120" placeholder="${esc(t('reason_hint'))}">${esc(form.reason)}</textarea></div>
      <div class="dlg__field"><label for="dlg-fine">${esc(t('fine'))}</label>
        <div class="dlg__money"><div class="wrap"><span>$</span><input id="dlg-fine" type="number" min="0" max="${data.maxFine}" step="50" value="${form.fine}"></div>
          <div class="dlg__pick">${fines.map((f) => `<button data-fine="${f}" class="${form.fine === f ? 'is-on' : ''}">${money(f)}</button>`).join('')}</div></div>
        <small>${esc(t('fine_hint', money(data.maxFine)))}</small></div>
      <button class="dlg__switch ${form.hold ? 'is-on' : ''}" data-act="hold"><i></i><span>${esc(t('hold'))}<small>${esc(t('hold_hint'))}</small></span></button>
      <div class="dlg__field dlg__hold" ${form.hold ? '' : 'hidden'}><label>${esc(t('hold_for'))}</label>
        <div class="dlg__pick">${holdChoices().map((h) => `<button data-hours="${h}" class="${form.holdHours === h ? 'is-on' : ''}">${esc(h === 0 ? t('until_lifted') : t('h', h))}</button>`).join('')}</div></div>
      <div class="dlg__error">${esc(error)}</div>
      <button class="dlg__btn" data-act="send" ${busy ? 'disabled' : ''}>${icon('send')}${esc(busy ? t('sending') : t('send'))}</button>
      <div class="dlg__keys"><kbd>Esc</kbd>${esc(t('close'))}</div>`;
    return shell(left, right);
  }

  // Rendering and input ----------------------------------------------------------------------------

  function render() {
    if (!kind) return;
    const focused = document.activeElement && document.activeElement.id;
    root.innerHTML = kind === 'counter' ? counter() : kind === 'holds' ? holds() : order();
    root.hidden = false;
    if (focused) {
      const el = document.getElementById(focused);
      if (el) { el.focus(); if (el.setSelectionRange && el.value != null) el.setSelectionRange(el.value.length, el.value.length); }
    }
  }

  async function act(action) {
    if (busy) return;
    if (action === 'close') return close();
    if (action === 'hold') { form.hold = !form.hold; return render(); }

    let body;
    if (action === 'pay') {
      const item = data.items[selected];
      const use = payAccount(item);
      if (item.held || !use) return;
      body = { action: 'pay', id: item.id, account: use };
    } else if (action === 'lift') {
      body = { action: 'lift', id: data.items[selected].id };
    } else if (action === 'send') {
      if (!form.reason.trim()) { error = t('reason_needed'); return render(); }
      body = { action: 'send', form: { reason: form.reason.trim(), fine: form.fine, hold: form.hold, holdHours: form.hold ? form.holdHours : 0 } };
    } else return;

    busy = true; error = ''; render();
    const result = await post(body);
    busy = false;
    if (result.close) return close();
    if (result.error) error = result.error;
    if (result.data) open(kind, result.data, true);
    else render();
  }

  root.addEventListener('click', (e) => {
    const el = e.target.closest('button');
    if (!el || el.disabled) return;
    if (el.dataset.pick != null) { selected = Number(el.dataset.pick); error = ''; return render(); }
    if (el.dataset.acc) { account = el.dataset.acc; return render(); }
    if (el.dataset.fine != null) { form.fine = Number(el.dataset.fine); return render(); }
    if (el.dataset.hours != null) { form.holdHours = Number(el.dataset.hours); return render(); }
    if (el.dataset.act) act(el.dataset.act);
  });

  root.addEventListener('input', (e) => {
    if (!form) return;
    if (e.target.id === 'dlg-reason') { form.reason = e.target.value; if (error) { error = ''; render(); } }
    if (e.target.id === 'dlg-fine') {
      const n = Math.floor(Number(e.target.value) || 0);
      form.fine = Math.max(0, Math.min(data.maxFine, n));
    }
  });
  root.addEventListener('change', (e) => { if (e.target.id === 'dlg-fine') render(); });

  window.addEventListener('keydown', (e) => {
    if (!kind) return;
    if (e.key === 'Escape') { e.preventDefault(); close(); return; }
    const typing = e.target && (e.target.tagName === 'TEXTAREA' || e.target.tagName === 'INPUT');
    if (e.key === 'Enter' && !typing) {
      e.preventDefault();
      act(kind === 'counter' ? 'pay' : kind === 'holds' ? 'lift' : 'send');
    } else if ((e.key === 'ArrowDown' || e.key === 'ArrowUp') && !typing && data.items) {
      e.preventDefault();
      selected = (selected + (e.key === 'ArrowDown' ? 1 : -1) + data.items.length) % data.items.length;
      error = '';
      render();
    }
  });

  function open(newKind, newData, keepSelection) {
    const plate = keepSelection && data && data.items && data.items[selected] && data.items[selected].plate;
    kind = newKind;
    data = newData || {};
    error = '';
    busy = false;
    if (kind === 'order') {
      const p = data.preset || {};
      form = { reason: p.reason || '', fine: p.fine || 0, hold: !!p.hold, holdHours: p.holdHours || 0 };
    } else {
      form = null;
      const wanted = plate || data.select;
      const i = wanted ? data.items.findIndex((it) => it.plate === wanted) : -1;
      selected = i >= 0 ? i : 0;
      if (!keepSelection) account = null;
    }
    render();
  }

  // Filming: the button the director "presses" lights up as if clicked.
  function press(action) {
    const btn = root.querySelector(`[data-act="${action}"]`);
    if (!btn) return;
    btn.classList.add('is-pressed');
    setTimeout(() => btn.classList.remove('is-pressed'), 180);
  }

  window.addEventListener('message', ({ data: msg }) => {
    if (!msg || typeof msg !== 'object') return;
    if (msg.type === 'init') strings = msg.dialogStrings || {};
    else if (msg.type === 'dialog') open(msg.kind, msg.data);
    else if (msg.type === 'dialogClose') { kind = null; root.hidden = true; root.innerHTML = ''; }
    else if (msg.type === 'dialogPress') press(msg.action);
  });
})();
