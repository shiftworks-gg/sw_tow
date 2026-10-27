// Shiftworks Tow: shift panel. Receives state from client/panel.lua once per second while on shift.
// No input focus, no network: everything it shows comes from Lua.
(() => {
  'use strict';

  // Tabler Icons 3.48.0 (MIT, https://tabler.io/icons), outline paths.
  const ICONS = {
    truck: '<path d="M5 17a2 2 0 1 0 4 0a2 2 0 1 0 -4 0"/><path d="M15 17a2 2 0 1 0 4 0a2 2 0 1 0 -4 0"/><path d="M5 17h-2v-11a1 1 0 0 1 1 -1h9v12m-4 0h6m4 0h2v-6h-8m0 -5h5l3 5"/>',
    package: '<path d="M12 3l8 4.5l0 9l-8 4.5l-8 -4.5l0 -9l8 -4.5"/><path d="M12 12l8 -4.5"/><path d="M12 12l0 9"/><path d="M12 12l-8 -4.5"/><path d="M16 5.25l-8 4.5"/>',
    'map-pin': '<path d="M9 11a3 3 0 1 0 6 0a3 3 0 0 0 -6 0"/><path d="M17.657 16.657l-4.243 4.243a2 2 0 0 1 -2.827 0l-4.244 -4.243a8 8 0 1 1 11.314 0"/>',
    route: '<path d="M3 19a2 2 0 1 0 4 0a2 2 0 0 0 -4 0"/><path d="M19 7a2 2 0 1 0 0 -4a2 2 0 0 0 0 4"/><path d="M11 19h5.5a3.5 3.5 0 0 0 0 -7h-8a3.5 3.5 0 0 1 0 -7h4.5"/>',
    cash: '<path d="M7 15h-3a1 1 0 0 1 -1 -1v-8a1 1 0 0 1 1 -1h12a1 1 0 0 1 1 1v3"/><path d="M7 10a1 1 0 0 1 1 -1h12a1 1 0 0 1 1 1v8a1 1 0 0 1 -1 1h-12a1 1 0 0 1 -1 -1l0 -8"/><path d="M12 14a2 2 0 1 0 4 0a2 2 0 0 0 -4 0"/>',
  };

  const $ = (id) => document.getElementById(id);
  const panel = $('panel');
  let strings = {};
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

  function applyUi(ui) {
    const root = document.documentElement.style;
    if (ui.accent) root.setProperty('--accent', ui.accent);
    root.setProperty('--scale', String(Math.min(1.3, Math.max(0.8, Number(ui.scale) || 1))));
    root.setProperty('--top', `${Math.min(90, Math.max(0, Number(ui.top) || 32))}vh`);
    panel.classList.toggle('is-left', ui.position === 'left');
    $('label').textContent = ui.label || 'SHIFTWORKS · TOW';
    const logo = $('logo');
    logo.hidden = !ui.logo;
    if (ui.logo) logo.src = ui.logo;
    if (ui.key) $('key').textContent = ui.key;
  }

  const clock = (seconds) => {
    const s = Math.max(0, Math.floor(seconds));
    return `${String(Math.floor(s / 60)).padStart(2, '0')}:${String(s % 60).padStart(2, '0')}`;
  };

  function render(state) {
    $('title').textContent = state.call ? text('title_' + state.call.type) : text('title_idle');
    $('truck').textContent = state.truck || '—';
    $('cargo').textContent = state.cargo || text('empty');
    $('call').textContent = state.call ? `${text('type_' + state.call.type)} · ${state.call.plate}` : text('no_call');
    $('distanceRow').hidden = state.distance == null;
    if (state.distance != null) $('distance').textContent = text('km', state.distance.toFixed(1));
    $('shift').textContent = text('shift_value', state.deliveries || 0, currency(state.earned || 0));

    const timer = $('timer');
    timer.hidden = !state.call || state.call.remaining == null;
    if (!timer.hidden) {
      const { remaining, total } = state.call;
      $('timerTime').textContent = clock(remaining);
      $('timerTime').classList.toggle('is-late', remaining < 60);
      $('timerFill').style.width = `${Math.max(0, Math.min(100, (1 - remaining / total) * 100))}%`;
    }
  }

  window.addEventListener('message', ({ data }) => {
    if (!data || typeof data !== 'object') return;
    if (data.type === 'init') {
      strings = data.strings || {};
      applyStrings();
      applyUi(data.ui || {});
    } else if (data.type === 'visible') {
      panel.hidden = !data.value;
    } else if (data.type === 'state') {
      render(data.state || {});
    } else if (data.type === 'probe') {
      // /swtow_test reads back what the player sees.
      const read = (id) => $(id).textContent;
      post('probe', {
        visible: !panel.hidden,
        title: read('title'), truck: read('truck'), cargo: read('cargo'), call: read('call'),
        distance: $('distanceRow').hidden ? null : read('distance'), shift: read('shift'),
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
