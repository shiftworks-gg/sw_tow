// Shiftworks Tow: shift panel. Receives state from client/panel.lua once per second while on shift.
// No input focus, no network: everything it shows comes from Lua.
// The layout of the configured theme is built once; each update only changes texts and the state
// classes on the panel (is-idle / is-job, step-1..3, has-timer, has-cargo, has-open, is-late).
(() => {
  'use strict';

  // Tabler Icons 3.48.0 (MIT, https://tabler.io/icons), outline paths.
  const ICONS = {
    radar: '<path d="M21 12h-8a1 1 0 1 0 -1 1v8a9 9 0 0 0 9 -9"/><path d="M16 9a5 5 0 1 0 -7 7"/><path d="M20.486 9a9 9 0 1 0 -11.482 11.495"/>',
    pin: '<path d="M9 11a3 3 0 1 0 6 0a3 3 0 0 0 -6 0"/><path d="M17.657 16.657l-4.243 4.243a2 2 0 0 1 -2.827 0l-4.244 -4.243a8 8 0 1 1 11.314 0"/>',
    link: '<path d="M9 15l6 -6"/><path d="M11 6l.463 -.536a5 5 0 0 1 7.071 7.072l-.534 .464"/><path d="M13 18l-.397 .534a5.068 5.068 0 0 1 -7.127 0a4.972 4.972 0 0 1 0 -7.071l.524 -.463"/>',
    yard: '<path d="M3 21v-13l9 -4l9 4v13"/><path d="M13 13h4v8h-10v-6h6"/><path d="M13 21v-9a1 1 0 0 0 -1 -1h-2a1 1 0 0 0 -1 1v3"/>',
    check: '<path d="M5 12l5 5l10 -10"/>',
    truck: '<path d="M5 17a2 2 0 1 0 4 0a2 2 0 1 0 -4 0"/><path d="M15 17a2 2 0 1 0 4 0a2 2 0 1 0 -4 0"/><path d="M5 17h-2v-11a1 1 0 0 1 1 -1h9v12m-4 0h6m4 0h2v-6h-8m0 -5h5l3 5"/>',
  };

  // ox_lib colours (Mantine's default palette): ox:primaryColor names one, ox:primaryShade picks 0-9.
  const MANTINE = {
    dark: ['#c1c2c5', '#a6a7ab', '#909296', '#5c5f66', '#373a40', '#2c2e33', '#25262b', '#1a1b1e', '#141517', '#101113'],
    gray: ['#f8f9fa', '#f1f3f5', '#e9ecef', '#dee2e6', '#ced4da', '#adb5bd', '#868e96', '#495057', '#343a40', '#212529'],
    red: ['#fff5f5', '#ffe3e3', '#ffc9c9', '#ffa8a8', '#ff8787', '#ff6b6b', '#fa5252', '#f03e3e', '#e03131', '#c92a2a'],
    pink: ['#fff0f6', '#ffdeeb', '#fcc2d7', '#faa2c1', '#f783ac', '#f06595', '#e64980', '#d6336c', '#c2255c', '#a61e4d'],
    grape: ['#f8f0fc', '#f3d9fa', '#eebefa', '#e599f7', '#da77f2', '#cc5de8', '#be4bdb', '#ae3ec9', '#9c36b5', '#862e9c'],
    violet: ['#f3f0ff', '#e5dbff', '#d0bfff', '#b197fc', '#9775fa', '#845ef7', '#7950f2', '#7048e8', '#6741d9', '#5f3dc4'],
    indigo: ['#edf2ff', '#dbe4ff', '#bac8ff', '#91a7ff', '#748ffc', '#5c7cfa', '#4c6ef5', '#4263eb', '#3b5bdb', '#364fc7'],
    blue: ['#e7f5ff', '#d0ebff', '#a5d8ff', '#74c0fc', '#4dabf7', '#339af0', '#228be6', '#1c7ed6', '#1971c2', '#1864ab'],
    cyan: ['#e3fafc', '#c5f6fa', '#99e9f2', '#66d9e8', '#3bc9db', '#22b8cf', '#15aabf', '#1098ad', '#0c8599', '#0b7285'],
    teal: ['#e6fcf5', '#c3fae8', '#96f2d7', '#63e6be', '#38d9a9', '#20c997', '#12b886', '#0ca678', '#099268', '#087f5b'],
    green: ['#ebfbee', '#d3f9d8', '#b2f2bb', '#8ce99a', '#69db7c', '#51cf66', '#40c057', '#37b24d', '#2f9e44', '#2b8a3e'],
    lime: ['#f4fce3', '#e9fac8', '#d8f5a2', '#c0eb75', '#a9e34b', '#94d82d', '#82c91e', '#74b816', '#66a80f', '#5c940d'],
    yellow: ['#fff9db', '#fff3bf', '#ffec99', '#ffe066', '#ffd43b', '#fcc419', '#fab005', '#f59f00', '#f08c00', '#e67700'],
    orange: ['#fff4e6', '#ffe8cc', '#ffd8a8', '#ffc078', '#ffa94d', '#ff922b', '#fd7e14', '#f76707', '#e8590c', '#d9480f'],
  };
  // Theme -> layout. 'minimal' is the earlier name of the compact layout, kept for old configs.
  const LAYOUTS = { shiftworks: 'card', ox: 'card', mission: 'mission', compact: 'compact', minimal: 'compact' };
  const BRAND_ACCENT = '#ff7a2e';
  const RING = 2 * Math.PI * 44;

  const panel = document.getElementById('panel');
  const root = document.documentElement;
  let strings = {};
  let ui = {};
  let layout = 'card';
  let binds = {};
  let lastEarned = null;
  let payoutTimer = 0;

  // Brand rule: money is always "$1,240", whatever the language.
  const currency = (n) => '$' + Math.round(n).toLocaleString('en-US');
  const escape = (s) => String(s).replace(/[&<>"]/g, (c) => ({ '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;' }[c]));
  const icon = (name, cls = '') => `<svg class="ic ${cls}" viewBox="0 0 24 24" aria-hidden="true">${ICONS[name] || ''}</svg>`;
  const text = (key, ...args) => {
    let i = 0;
    return (strings[key] || key).replace(/%s/g, () => String(args[i++] ?? ''));
  };

  // Templates ---------------------------------------------------------------------------------------

  const ring = () => `
    <div class="ring if-timer">
      <svg viewBox="0 0 100 100"><circle class="track" cx="50" cy="50" r="44" stroke-width="7"/><circle class="arc" cx="50" cy="50" r="44" stroke-width="7" stroke-dasharray="0 ${RING}"/></svg>
      <div class="ring__text"><span class="num" data-b="timer"></span><span class="lbl" data-t="left"></span></div>
    </div>`;

  const steps = () => `
    <div class="steps if-job">
      <span class="step s1"><i>${icon('pin', 'ic-todo')}${icon('check', 'ic-done')}</i><span data-t="step_pickup"></span></span><hr class="h1">
      <span class="step s2"><i>${icon('link', 'ic-todo')}${icon('check', 'ic-done')}</i><span data-t="step_load"></span></span><hr class="h2">
      <span class="step s3"><i>${icon('yard', 'ic-todo')}${icon('check', 'ic-done')}</i><span data-t="step_deliver"></span></span>
    </div>`;

  const TEMPLATES = {
    card: () => `
      <div class="card">
        <div class="card__head">
          <div class="card__logo" data-b="logo"></div>
          <div class="card__titles"><div class="lbl" data-b="kind"></div><div class="card__title" data-b="title"></div></div>
          <div class="card__clock num"><span class="dot"></span><span data-b="clock"></span></div>
        </div>
        <div class="card__hero if-job">
          ${ring()}
          <div class="card__dest"><div class="lbl" data-b="whereLabel"></div><div class="card__where" data-b="where"></div><div class="big" data-b="distance"></div></div>
        </div>
        <div class="card__idle if-idle"><div class="lbl" data-t="waiting"></div><div class="card__hint" data-b="hint"></div></div>
        ${steps()}
        <div class="card__truck">
          ${icon('truck')}
          <span class="if-truck card__truck-name" data-b="truckName"></span><span class="if-truck tag" data-b="truckPlate"></span>
          <span class="if-notruck muted" data-t="no_truck"></span>
        </div>
        <div class="card__foot">
          <div><span class="lbl"><span data-t="cargo"></span> <span class="status if-cargo" data-b="status"></span></span>
            <span class="val cargo"><span class="plate if-cargo" data-b="plate"></span><span class="muted if-empty" data-t="empty"></span></span></div>
          <div><span class="lbl" data-t="earned"></span><span class="val" data-b="earned"></span><span class="payout" data-b="payout"></span></div>
          <div><span class="lbl" data-t="tows"></span><span class="val" data-b="tows"></span></div>
        </div>
      </div>`,

    mission: () => `
      <div class="mission">
        <div class="mission__top lbl"><span data-b="label"></span><span class="dot"></span><span class="num" data-b="clock"></span></div>
        <div class="mission__kind lbl" data-b="kind"></div>
        <div class="mission__title" data-b="title"></div>
        <div class="mission__meta if-job">
          <div><span class="lbl" data-t="distance"></span><span class="big" data-b="distance"></span></div>
          <div class="if-timer"><span class="lbl" data-t="deliver_within"></span><span class="big" data-b="timer"></span></div>
        </div>
        <div class="mission__bar if-timer"><i data-b="bar"></i></div>
        <div class="mission__foot if-idle" data-b="hint"></div>
        <div class="mission__foot if-cargo"><span class="plate" data-b="plate"></span><span class="status" data-b="status"></span></div>
        <div class="mission__foot">${icon('truck')}<span class="if-truck" data-b="truckName"></span><span class="if-truck tag" data-b="truckPlate"></span><span class="if-notruck" data-t="no_truck"></span></div>
        <div class="mission__foot">
          <span class="payout" data-b="payout"></span>
          <span data-t="earned"></span><span class="num" data-b="earned"></span><span class="sep"></span><span data-t="tows"></span><span class="num" data-b="tows"></span>
        </div>
      </div>`,

    compact: () => `
      <div class="compact">
        <div class="pill">
          <div class="pill__icon" data-b="icon"></div>
          <div class="pill__text"><div class="lbl" data-b="kind"></div><div class="pill__title" data-b="title"></div></div>
          <div class="pill__side if-job"><span class="big" data-b="distance"></span>${ring()}</div>
          <div class="pill__side if-idle"><span class="hint" data-b="hint"></span></div>
        </div>
        <div class="pill pill--sm">
          ${icon('truck')}<span class="if-truck" data-b="truckName"></span><span class="if-notruck" data-t="no_truck"></span><span class="sep"></span>
          <span class="plate if-cargo" data-b="plate"></span><span class="status if-cargo" data-b="status"></span><span class="sep if-cargo"></span>
          <span data-t="earned"></span><span class="num" data-b="earned"></span><span class="sep"></span><span data-t="tows"></span><span class="num" data-b="tows"></span>
          <span class="payout" data-b="payout"></span>
        </div>
      </div>`,
  };

  function build() {
    panel.innerHTML = TEMPLATES[layout]();
    panel.querySelectorAll('[data-t]').forEach((el) => { el.textContent = text(el.dataset.t); });
    binds = {};
    panel.querySelectorAll('[data-b]').forEach((el) => { (binds[el.dataset.b] ||= []).push(el); });
    set('label', ui.label || 'Shiftworks · Tow');
    // The card shows the server's logo when one is set, and no icon otherwise.
    (binds.logo || []).forEach((el) => {
      if (ui.logo) el.innerHTML = `<img src="${escape(ui.logo)}" alt="">`;
      else el.remove();
    });
  }

  const set = (name, value) => (binds[name] || []).forEach((el) => { el.textContent = value; });
  const setHtml = (name, value) => (binds[name] || []).forEach((el) => { el.innerHTML = value; });

  // Colours -----------------------------------------------------------------------------------------

  const isHex = (v) => typeof v === 'string' && /^#[0-9a-f]{6}$/i.test(v);
  const rgbOf = (hex) => [1, 3, 5].map((i) => parseInt(hex.slice(i, i + 2), 16));
  const luminance = (hex) => {
    const [r, g, b] = rgbOf(hex).map((c) => {
      const s = c / 255;
      return s <= 0.03928 ? s / 12.92 : ((s + 0.055) / 1.055) ** 2.4;
    });
    return 0.2126 * r + 0.7152 * g + 0.0722 * b;
  };
  const contrast = (a, b) => {
    const [hi, lo] = [luminance(a), luminance(b)].sort((x, y) => y - x);
    return (hi + 0.05) / (lo + 0.05);
  };
  const mix = (a, b, t) => '#' + rgbOf(a).map((c, i) => Math.round(c + (rgbOf(b)[i] - c) * t).toString(16).padStart(2, '0')).join('');

  // The accent: a set colour, or the server's ox_lib colour, or the brand orange.
  function pickAccent() {
    if (isHex(ui.accent)) return ui.accent;
    const palette = ui.ox && MANTINE[ui.ox.color];
    if (palette) return palette[Math.min(9, Math.max(0, Number(ui.ox.shade) || 8))];
    return BRAND_ACCENT;
  }

  function applyUi() {
    const style = root.style;
    const theme = LAYOUTS[ui.theme] ? ui.theme : 'shiftworks';
    root.dataset.theme = theme;
    layout = LAYOUTS[theme];

    const colors = ui.colors || {};
    if (isHex(colors.surface)) {
      style.setProperty('--surface-rgb', rgbOf(colors.surface).join(', '));
      style.setProperty('--surface-top', mix(colors.surface, '#ffffff', 0.06));
      style.setProperty('--surface-bottom', colors.surface);
    }
    if (isHex(colors.header)) style.setProperty('--surface-top', colors.header);
    if (isHex(colors.text)) style.setProperty('--ink', colors.text);
    if (isHex(colors.muted)) style.setProperty('--ink-muted', colors.muted);
    if (isHex(colors.line)) style.setProperty('--line', colors.line);
    if (ui.opacity != null) style.setProperty('--opacity', String(Math.min(1, Math.max(0.6, Number(ui.opacity) || 1))));

    // Text on the accent is dark or white, whichever reads better; as a text colour the accent is
    // lightened until it reads on the panel (4.5:1).
    const accent = pickAccent();
    const surface = '#' + getComputedStyle(root).getPropertyValue('--surface-rgb').split(',')
      .map((c) => Number(c).toString(16).padStart(2, '0')).join('');
    let accentText = accent;
    for (let t = 0.1; contrast(accentText, surface) < 4.5 && t <= 1; t += 0.1) accentText = mix(accent, '#ffffff', t);
    style.setProperty('--accent', accent);
    style.setProperty('--accent-rgb', rgbOf(accent).join(', '));
    style.setProperty('--on-accent', contrast(accent, '#141c22') >= contrast(accent, '#ffffff') ? '#141c22' : '#ffffff');
    style.setProperty('--accent-text', accentText);

    if (ui.font && typeof ui.font.family === 'string') {
      const family = `"${ui.font.family.replace(/"/g, '')}"`;
      if (typeof ui.font.url === 'string') {
        new FontFace(ui.font.family, `url("${ui.font.url}")`).load().then((face) => document.fonts.add(face)).catch(() => {});
      }
      style.setProperty('--font-ui', `${family}, ${getComputedStyle(root).getPropertyValue('--font-ui')}`);
      style.setProperty('--title-font', `${family}, var(--font-display)`);
      style.setProperty('--font-display', `${family}, "Barlow Condensed", sans-serif`);
    }

    style.setProperty('--scale', String(Math.min(1.3, Math.max(0.8, Number(ui.scale) || 1))));
    style.setProperty('--top', `${Math.min(90, Math.max(0, Number(ui.top) || 26))}vh`);
    panel.classList.toggle('is-left', ui.position === 'left');
    build();
  }

  // Rendering ---------------------------------------------------------------------------------------

  const clock = (seconds) => {
    const s = Math.max(0, Math.floor(seconds));
    const h = Math.floor(s / 3600);
    const mm = String(Math.floor((s % 3600) / 60)).padStart(2, '0');
    const ss = String(s % 60).padStart(2, '0');
    return h > 0 ? `${h}:${mm}:${ss}` : `${mm}:${ss}`;
  };

  const distance = (metres) => metres < 1000
    ? text('m', String(Math.round(metres / 10) * 10))
    : text('km', (metres / 1000).toFixed(1));

  const STATUS = { winching: 'is-moving', lowering: 'is-moving', secured: 'is-held', hooked: 'is-held' };
  const STEP_ICON = { 1: 'pin', 2: 'link', 3: 'yard' };
  const STEP_KEY = { 1: 'pickup', 2: 'load', 3: 'deliver' };

  // Which step of the job: drive to the vehicle, load it, take it to the yard.
  function stepOf(state) {
    if (state.returning) return 0;
    if (state.cargo) return state.status === 'winching' || state.status === 'lowering' ? 2 : 3;
    return state.route ? 1 : 0;
  }

  // "3 calls open. Press F6 to take one." The key is drawn as a key cap.
  function hint(open, short) {
    const key = `<span class="key">${escape(ui.key || 'F6')}</span>`;
    if (short) return `${open ? escape(text('open_short', open)) : ''} ${key}`;
    const take = escape(text('take_hint')).replace('{key}', key);
    return open ? `${escape(text(open === 1 ? 'call_open' : 'calls_open', open))} ${take}` : escape(text('no_calls'));
  }

  function payout(earned) {
    if (lastEarned != null && earned > lastEarned) {
      set('payout', '+' + currency(earned - lastEarned));
      (binds.payout || []).forEach((el) => el.classList.add('is-on'));
      clearTimeout(payoutTimer);
      payoutTimer = setTimeout(() => (binds.payout || []).forEach((el) => el.classList.remove('is-on')), 2600);
    }
    lastEarned = earned;
  }

  function render(state) {
    const call = state.call;
    const route = state.route;
    const step = stepOf(state);
    // Ending the shift: drive the truck back to the depot. Shown like a job without steps or timer.
    const returning = !!state.returning;
    const job = step > 0 || returning;
    const timed = !returning && !!call && call.remaining != null;
    const late = timed && call.remaining < 60;
    const kind = call ? text('title_' + call.type) : null;

    const c = panel.classList;
    c.toggle('is-job', job);
    c.toggle('is-idle', !job);
    c.toggle('has-timer', timed);
    c.toggle('has-cargo', !!state.cargo);
    c.toggle('has-truck', !!state.truck);
    c.toggle('has-open', !!state.open);
    c.toggle('is-late', late);
    c.toggle('is-return', returning);
    for (let i = 1; i <= 3; i++) c.toggle('step-' + i, step === i);

    set('clock', clock(state.onShift || 0));
    const doing = returning ? text(state.returning === 'office' ? 'do_office' : 'do_return') : job ? text('do_' + STEP_KEY[step]) : text('title_idle');
    const stepName = returning ? text('title_return') : job ? text('step_' + STEP_KEY[step]) : '';
    if (returning) {
      set('kind', text('title_return'));
      set('title', layout === 'card' ? doing : (route && route.where) || doing);
    } else if (layout === 'card') {
      set('kind', job ? (kind || stepName) : (ui.label || 'Shiftworks · Tow'));
      set('title', doing);
    } else if (layout === 'mission') {
      set('kind', job ? [kind, stepName].filter(Boolean).join(' · ') : text('title_idle'));
      set('title', job ? (step === 2 ? doing : (route && route.where) || doing) : text('waiting'));
    } else {
      set('kind', job ? [stepName, kind].filter(Boolean).join(' · ') : `${text('title_idle')} · ${clock(state.onShift || 0)}`);
      set('title', job ? (step === 2 ? doing : (route && route.where) || doing) : text('waiting'));
    }

    const logo = !job && ui.logo ? `<img src="${escape(ui.logo)}" alt="">` : null;
    setHtml('icon', logo || icon(returning ? 'truck' : job ? STEP_ICON[step] : 'radar'));
    setHtml('hint', hint(state.open || 0, layout === 'compact'));

    set('whereLabel', text(returning ? 'at_depot' : step === 3 ? 'at_yard' : 'at_pickup'));
    set('where', route ? route.where || '' : '');
    set('distance', route ? distance(route.metres) : '—');

    if (timed) {
      set('timer', clock(call.remaining));
      const left = Math.max(0, Math.min(1, call.remaining / call.total));
      panel.querySelectorAll('.arc').forEach((el) => el.setAttribute('stroke-dasharray', `${(RING * left).toFixed(1)} ${RING}`));
      (binds.bar || []).forEach((el) => { el.style.width = `${(1 - left) * 100}%`; });
      (binds.timer || []).forEach((el) => el.classList.toggle('late', late));
    }

    set('truckName', state.truck ? state.truck.name : '');
    set('truckPlate', state.truck ? state.truck.plate : '');
    set('plate', state.cargo || '');
    (binds.status || []).forEach((el) => {
      el.className = 'status ' + (STATUS[state.status] || '') + (el.classList.contains('if-cargo') ? ' if-cargo' : '');
      el.textContent = state.status ? text('status_' + state.status) : '';
    });

    set('tows', String(state.deliveries || 0));
    set('earned', currency(state.earned || 0));
    payout(state.earned || 0);
  }

  window.addEventListener('message', ({ data }) => {
    if (!data || typeof data !== 'object') return;
    if (data.type === 'init') {
      strings = data.strings || {};
      ui = data.ui || {};
      applyUi();
    } else if (data.type === 'visible') {
      panel.hidden = !data.value;
      if (!data.value) lastEarned = null;
    } else if (data.type === 'state') {
      render(data.state || {});
    } else if (data.type === 'probe') {
      // /swtow_test reads back what the player sees.
      const read = (name) => (binds[name] && binds[name][0] ? binds[name][0].textContent : null);
      const has = (cls) => panel.classList.contains(cls);
      post('probe', {
        visible: !panel.hidden,
        title: read('title'), kind: read('kind'),
        truck: has('has-truck') ? `${read('truckName')} ${read('truckPlate')}` : null,
        cargo: has('has-cargo') ? read('plate') : text('empty'),
        distance: has('is-job') ? read('distance') : null,
        shift: `${read('tows')} · ${read('earned')}`,
        timer: has('has-timer') ? read('timer') : null,
      });
    }
  });

  function post(name, body) {
    if (typeof GetParentResourceName !== 'function') return;
    fetch(`https://${GetParentResourceName()}/${name}`, { method: 'POST', body: JSON.stringify(body || {}) }).catch(() => {});
  }

  // Tell Lua the page is ready for the init message (GetParentResourceName is provided by FiveM).
  post('ready');
})();
