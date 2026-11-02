// Shiftworks Tow: the call list (client/calllist.lua). It takes the panel's place while open and never
// has input focus: Lua reads the keys and sends what to show. Rows: the worker's own call, open calls
// nearest first, then ending the shift. Distances and arrows are updated five times a second.
(() => {
  'use strict';

  const root = document.getElementById('calls');
  const body = document.body;
  let strings = {};
  let rows = [];
  let selected = 0;

  const ARROW = '<svg viewBox="0 0 24 24" aria-hidden="true"><path d="M12 1.5L19.5 22L12 17.5L4.5 22Z"/></svg>';

  const escape = (s) => String(s ?? '').replace(/[&<>"]/g, (c) => ({ '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;' }[c]));
  const text = (key, ...args) => {
    let i = 0;
    return (strings[key] || key).replace(/%s/g, () => String(args[i++] ?? ''));
  };
  // Brand rule: money is always "$1,240", whatever the language.
  const money = (n) => '$' + Math.round(n).toLocaleString('en-US');
  const distance = (metres) => metres < 1000
    ? text('m', String(Math.round(metres / 10) * 10))
    : text('km', (metres / 1000).toFixed(1));
  const age = (seconds) => seconds < 60 ? text('just_now') : text('min_ago', Math.floor(seconds / 60));
  const TYPES = { player: 1, police: 1, contract: 1, abandoned: 1 };

  // The arrow turns the short way round: 350° -> 10° is 20° clockwise, not 340° back.
  function turn(el, deg) {
    const prev = Number(el.dataset.deg);
    const next = Number.isFinite(prev) && el.dataset.deg !== undefined ? prev + ((((deg - prev) % 360) + 540) % 360 - 180) : deg;
    el.dataset.deg = String(next);
    el.style.setProperty('--deg', `${next}deg`);
  }

  function callRow(row, i) {
    const type = TYPES[row.type] ? row.type : 'player';
    const kind = row.mine
      ? `<span class="cl__kind is-mine">${escape(text('your_call'))}</span>`
      : `<span class="cl__kind t-${type}">${escape(text('type_' + type))}</span>`;
    const pay = row.pay > 0 ? `<span class="cl__pay">≈ ${money(row.pay)}</span>` : '';
    const message = row.message ? `<div class="cl__msg">${escape(row.message)}</div>` : '';
    return `
      <div class="cl__row${i === selected ? ' is-sel' : ''}" data-i="${i}">
        <div class="cl__arrow" data-deg="${Number(row.bearing) || 0}" style="--deg: ${Number(row.bearing) || 0}deg">${ARROW}</div>
        <div class="cl__main"><div class="cl__dist" data-dist>${escape(distance(row.metres))}</div><div class="cl__street">${escape(row.street)}</div></div>
        <div class="cl__side">${kind}${pay}</div>
        <div class="cl__more">
          <div class="cl__meta"><span class="plate">${escape(row.plate)}</span><span>#${Number(row.id) || 0} · ${escape(age(row.age || 0))}</span></div>
          ${message}
          <div class="cl__act"><span class="key">Enter</span><span>${escape(text(row.mine ? 'drop' : 'take'))}</span></div>
        </div>
      </div>`;
  }

  function endRow(row, i) {
    return `
      <div class="cl__row is-end${i === selected ? ' is-sel' : ''}" data-i="${i}">
        <div class="cl__end">${escape(row.title)}</div>
        <div class="cl__more">
          <div class="cl__msg">${escape(row.hint)}</div>
          <div class="cl__act"><span class="key">Enter</span><span>${escape(row.title)}</span></div>
        </div>
      </div>`;
  }

  function render() {
    const hasCalls = rows.some((row) => row.kind === 'call');
    const list = rows.map((row, i) => (row.kind === 'call' ? callRow(row, i) : endRow(row, i))).join('');
    root.innerHTML = `
      <div class="card cl__card">
        <div class="card__head">
          <div class="card__titles"><div class="lbl">${escape(text('label'))} · ${escape(text('nearest'))}</div><div class="card__title">${escape(text('title'))}</div></div>
        </div>
        <div class="cl__list">${hasCalls ? '' : `<div class="cl__empty">${escape(text('empty'))}</div>`}${list}</div>
        <div class="cl__keys"><span class="key k2">↑</span><span class="key k2">↓</span><span>${escape(text('keys_choose'))}</span>
          <span class="cl__keys-end"><span class="key k2">Esc</span><span>${escape(text('keys_close'))}</span></span></div>
      </div>`;
    showSelected();
  }

  function showSelected() {
    root.querySelectorAll('.cl__row').forEach((el) => el.classList.toggle('is-sel', Number(el.dataset.i) === selected));
    const el = root.querySelector('.cl__row.is-sel');
    if (el) el.scrollIntoView({ block: 'nearest' });
  }

  function show(value) {
    root.hidden = !value;
    body.classList.toggle('calls-open', value);
    if (!value) root.classList.remove('is-busy');
  }

  window.addEventListener('message', ({ data: msg }) => {
    if (!msg || typeof msg !== 'object') return;
    if (msg.type === 'init') {
      strings = msg.callStrings || {};
    } else if (msg.type === 'calls') {
      rows = Array.isArray(msg.rows) ? msg.rows : [];
      selected = Number(msg.selected) || 0;
      root.classList.toggle('is-left', !!msg.left);
      render();
      show(true);
    } else if (msg.type === 'callsSelect') {
      selected = Number(msg.selected) || 0;
      showSelected();
    } else if (msg.type === 'callsLive') {
      (msg.rows || []).forEach((live) => {
        const el = root.querySelector(`.cl__row[data-i="${Number(live.index)}"]`);
        if (!el) return;
        const arrow = el.querySelector('.cl__arrow');
        if (arrow) turn(arrow, Number(live.bearing) || 0);
        const dist = el.querySelector('[data-dist]');
        if (dist) dist.textContent = distance(live.metres);
      });
    } else if (msg.type === 'callsBusy') {
      root.classList.toggle('is-busy', !!msg.value);
    } else if (msg.type === 'callsClose') {
      show(false);
    }
  });
})();
