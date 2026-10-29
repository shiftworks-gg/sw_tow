// Shiftworks Tow: shift panel. Receives state from client/panel.lua once per second while on shift.
// No input focus, no network: everything it shows comes from Lua.
(() => {
  'use strict';

  // Tabler Icons 3.48.0 (MIT, https://tabler.io/icons), outline paths.
  const ICONS = {
    truck: '<path d="M5 17a2 2 0 1 0 4 0a2 2 0 1 0 -4 0"/><path d="M15 17a2 2 0 1 0 4 0a2 2 0 1 0 -4 0"/><path d="M5 17h-2v-11a1 1 0 0 1 1 -1h9v12m-4 0h6m4 0h2v-6h-8m0 -5h5l3 5"/>',
    package: '<path d="M12 3l8 4.5l0 9l-8 4.5l-8 -4.5l0 -9l8 -4.5"/><path d="M12 12l8 -4.5"/><path d="M12 12l0 9"/><path d="M12 12l-8 -4.5"/><path d="M16 5.25l-8 4.5"/>',
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
  const THEMES = ['shiftworks', 'ox', 'minimal'];
  const BRAND_ACCENT = '#ff7a2e';

  const $ = (id) => document.getElementById(id);
  const panel = $('panel');
  const root = document.documentElement;
  let strings = {};
  let lastEarned = null;
  let payoutTimer = 0;

  // Brand rule: money is always "$1,240", whatever the language.
  const currency = (n) => '$' + Math.round(n).toLocaleString('en-US');

  const icon = (name) =>
    `<svg class="sw-icon" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-linecap="round" stroke-linejoin="round" aria-hidden="true">${ICONS[name] || ''}</svg>`;

  const text = (key, ...args) => {
    let i = 0;
    return (strings[key] || key).replace(/%s/g, () => String(args[i++] ?? ''));
  };

  function applyStrings() {
    document.querySelectorAll('[data-text]').forEach((el) => {
      const name = el.dataset.icon;
      el.innerHTML = (name ? icon(name) : '') + '<span></span>';
      el.lastChild.textContent = text(el.dataset.text);
    });
  }

  // Colour helpers ---------------------------------------------------------------------------------

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

  // The accent the panel uses: a set colour, or the server's ox_lib colour, or the brand orange.
  function pickAccent(ui) {
    if (isHex(ui.accent)) return ui.accent;
    const palette = ui.ox && MANTINE[ui.ox.color];
    if (palette) return palette[Math.min(9, Math.max(0, Number(ui.ox.shade) || 8))];
    return BRAND_ACCENT;
  }

  function applyUi(ui) {
    const style = root.style;
    root.dataset.theme = THEMES.includes(ui.theme) ? ui.theme : 'shiftworks';

    const colors = ui.colors || {};
    if (isHex(colors.surface)) style.setProperty('--surface-rgb', rgbOf(colors.surface).join(', '));
    if (isHex(colors.header)) style.setProperty('--head', colors.header);
    if (isHex(colors.text)) { style.setProperty('--ink', colors.text); style.setProperty('--on-head', colors.text); }
    if (isHex(colors.muted)) style.setProperty('--ink-muted', colors.muted);
    if (isHex(colors.line)) style.setProperty('--line', colors.line);
    if (ui.opacity != null) style.setProperty('--opacity', String(Math.min(1, Math.max(0.6, Number(ui.opacity) || 1))));

    // Text on the accent is dark or white, whichever reads better; as a text colour the accent is
    // lightened until it reads on the panel (4.5:1).
    const accent = pickAccent(ui);
    const surface = '#' + getComputedStyle(root).getPropertyValue('--surface-rgb').split(',')
      .map((c) => Number(c).toString(16).padStart(2, '0')).join('');
    let accentText = accent;
    for (let t = 0.1; contrast(accentText, surface) < 4.5 && t <= 1; t += 0.1) accentText = mix(accent, '#ffffff', t);
    style.setProperty('--accent', accent);
    style.setProperty('--on-accent', contrast(accent, '#141c22') >= contrast(accent, '#ffffff') ? '#141c22' : '#ffffff');
    style.setProperty('--accent-text', accentText);

    if (ui.font && typeof ui.font.family === 'string') {
      const family = `"${ui.font.family.replace(/"/g, '')}"`;
      if (typeof ui.font.url === 'string') {
        new FontFace(ui.font.family, `url("${ui.font.url}")`).load()
          .then((face) => document.fonts.add(face)).catch(() => {});
      }
      style.setProperty('--font-ui', `${family}, ${getComputedStyle(root).getPropertyValue('--font-ui')}`);
      style.setProperty('--title-font', `${family}, var(--font-display)`);
    }

    style.setProperty('--scale', String(Math.min(1.3, Math.max(0.8, Number(ui.scale) || 1))));
    style.setProperty('--top', `${Math.min(90, Math.max(0, Number(ui.top) || 32))}vh`);
    panel.classList.toggle('is-left', ui.position === 'left');
    $('label').textContent = ui.label || 'SHIFTWORKS · TOW';
    const logo = $('logo');
    logo.hidden = !ui.logo;
    if (ui.logo) logo.src = ui.logo;
    if (ui.key) $('key').textContent = ui.key;
  }

  // Rendering --------------------------------------------------------------------------------------

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

  function payout(earned) {
    if (lastEarned != null && earned > lastEarned) {
      const el = $('payout');
      el.textContent = '+' + currency(earned - lastEarned);
      el.classList.add('is-on');
      clearTimeout(payoutTimer);
      payoutTimer = setTimeout(() => el.classList.remove('is-on'), 2600);
    }
    lastEarned = earned;
  }

  function render(state) {
    const call = state.call;
    $('title').textContent = call ? text('title_' + call.type) : text('title_idle');
    $('clock').textContent = clock(state.onShift || 0);

    // A job: the call, or a vehicle on board without one (secured on the spot).
    const route = state.route;
    $('job').hidden = !call && !route;
    $('idle').hidden = !$('job').hidden;
    $('callPlate').textContent = call ? call.plate : (state.cargo || '—');
    $('routeTo').textContent = route ? text(route.to === 'yard' ? 'to_yard' : 'to_pickup') : '';
    $('routeWhere').textContent = route ? route.where || '' : '';
    $('distance').textContent = route ? distance(route.metres) : '—';

    const timer = $('timer');
    timer.hidden = !call || call.remaining == null;
    if (!timer.hidden) {
      const late = call.remaining < 60;
      $('timerTime').textContent = clock(call.remaining);
      $('timerTime').classList.toggle('is-late', late);
      $('timerFill').classList.toggle('is-late', late);
      $('timerFill').style.width = `${Math.max(0, Math.min(100, (1 - call.remaining / call.total) * 100))}%`;
    }

    const open = state.open;
    $('openCount').hidden = !open;
    if (open) $('openCount').textContent = text('open_calls', open);
    $('openBadge').hidden = !open || $('job').hidden;
    if (open) $('openBadge').textContent = String(open);

    $('truckName').textContent = state.truck ? state.truck.name : '—';
    $('truckPlate').textContent = state.truck ? state.truck.plate : '';
    $('cargo').textContent = state.cargo || text('empty');
    $('cargo').className = state.cargo ? 'sw-num' : 'sw-muted';
    const status = $('status');
    status.hidden = !state.status;
    if (state.status) {
      status.className = 'sw-chip ' + (STATUS[state.status] || '');
      status.textContent = text('status_' + state.status);
    }

    $('tows').textContent = String(state.deliveries || 0);
    $('earned').textContent = currency(state.earned || 0);
    payout(state.earned || 0);
  }

  window.addEventListener('message', ({ data }) => {
    if (!data || typeof data !== 'object') return;
    if (data.type === 'init') {
      strings = data.strings || {};
      applyStrings();
      applyUi(data.ui || {});
    } else if (data.type === 'visible') {
      panel.hidden = !data.value;
      if (!data.value) lastEarned = null;
    } else if (data.type === 'state') {
      render(data.state || {});
    } else if (data.type === 'probe') {
      // /swtow_test reads back what the player sees.
      const read = (id) => $(id).textContent;
      post('probe', {
        visible: !panel.hidden,
        title: read('title'), truck: read('truck'), cargo: read('cargo'),
        call: $('job').hidden ? null : read('callPlate'),
        distance: $('job').hidden ? null : read('distance'),
        shift: `${read('tows')} · ${read('earned')}`,
        timer: $('timer').hidden ? null : read('timerTime'),
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
