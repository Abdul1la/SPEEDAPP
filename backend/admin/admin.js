// Speed Alert admin panel. Plain JavaScript, no build step.
// Everything is rendered with textContent (never innerHTML), so names, notes
// and comments typed by drivers can't inject code.
'use strict';

const TOKEN_KEY = 'speedalert.admin.token';
const PAGE = 50;

const state = { me: null, tab: 'overview' };

// ---- Helpers -------------------------------------------------------------

/** Creates an element: h('button', { class: 'x', onclick }, 'text', child). */
function h(tag, attrs, ...children) {
  const el = document.createElement(tag);
  for (const [k, v] of Object.entries(attrs || {})) {
    if (v == null || v === false) continue;
    if (k.startsWith('on')) el.addEventListener(k.slice(2), v);
    else if (k === 'class') el.className = v;
    else el.setAttribute(k, v === true ? '' : String(v));
  }
  for (const c of children.flat()) {
    if (c == null || c === false) continue;
    el.append(c instanceof Node ? c : document.createTextNode(String(c)));
  }
  return el;
}

function token() {
  try {
    return sessionStorage.getItem(TOKEN_KEY);
  } catch {
    return null;
  }
}
function setToken(t) {
  try {
    if (t) sessionStorage.setItem(TOKEN_KEY, t);
    else sessionStorage.removeItem(TOKEN_KEY);
  } catch {
    /* private mode: stay signed in only until reload */
  }
}

async function api(method, path, body) {
  const headers = {};
  const t = token();
  if (t) headers.authorization = `Bearer ${t}`;
  if (body !== undefined) headers['content-type'] = 'application/json';
  const res = await fetch(path, {
    method,
    headers,
    body: body === undefined ? undefined : JSON.stringify(body),
  });
  const data = res.status === 204 ? null : await res.json().catch(() => null);
  if (res.status === 401 && path !== '/v1/auth/login?panel=true') {
    setToken(null);
    showLogin('Your session ended. Sign in again.');
    throw new Error('Signed out');
  }
  if (!res.ok) throw new Error(data?.error?.message || `Request failed (${res.status})`);
  return data;
}

let toastTimer;
function toast(message) {
  const el = document.getElementById('toast');
  el.textContent = message;
  el.hidden = false;
  clearTimeout(toastTimer);
  toastTimer = setTimeout(() => (el.hidden = true), 3500);
}

/** Runs an action from a button: disables it meanwhile, shows errors. */
async function act(button, fn, done) {
  button.disabled = true;
  try {
    await fn();
    if (done) toast(done);
    await render();
  } catch (e) {
    if (e.message !== 'Signed out') toast(e.message);
  } finally {
    button.disabled = false;
  }
}

const when = (iso) => (iso ? new Date(iso).toLocaleString() : '—');
const mapLink = (p) =>
  h('a', { href: `https://www.google.com/maps?q=${p.lat},${p.lng}`, target: '_blank', rel: 'noopener noreferrer' },
    `${p.lat.toFixed(5)}, ${p.lng.toFixed(5)}`);
const typeTag = (p) => h('span', { class: `tag ${p.type}` }, p.type === 'camera' ? 'Speed camera' : 'Speed bump');
const statusTag = (s, reason) => h('span', { class: `tag ${s}` }, reason ? `${s} · ${reason}` : s);
const who = (u) => (u ? u.email || u.displayName || `Driver #${u.id}` : 'Community');
const isAdmin = () => state.me?.role === 'admin';

function pager(page, count, go) {
  if (page === 0 && count < PAGE) return null;
  return h('div', { class: 'pager' },
    h('button', { disabled: page === 0, onclick: () => go(page - 1) }, 'Previous'),
    h('span', { class: 'muted' }, `Page ${page + 1}`),
    h('button', { disabled: count < PAGE, onclick: () => go(page + 1) }, 'Next'));
}

// ---- Sign in -------------------------------------------------------------

function showLogin(message = '') {
  document.getElementById('app').hidden = true;
  document.getElementById('login').hidden = false;
  document.getElementById('login-error').textContent = message;
}

document.getElementById('login-form').addEventListener('submit', async (e) => {
  e.preventDefault();
  const form = e.currentTarget;
  const error = document.getElementById('login-error');
  error.textContent = '';
  try {
    const data = await api('POST', '/v1/auth/login?panel=true', {
      email: form.email.value,
      password: form.password.value,
      deviceName: 'Admin panel',
    });
    if (data.user.role === 'user') {
      setToken(data.token);
      await api('POST', '/v1/auth/logout').catch(() => {});
      setToken(null);
      error.textContent = 'This account is not a moderator or admin.';
      return;
    }
    setToken(data.token);
    form.reset();
    await start();
  } catch (err) {
    error.textContent = err.message;
  }
});

document.getElementById('logout').addEventListener('click', async () => {
  await api('POST', '/v1/auth/logout').catch(() => {});
  setToken(null);
  showLogin();
});

for (const b of document.querySelectorAll('#tabs button')) {
  b.addEventListener('click', () => {
    state.tab = b.dataset.tab;
    state.page = 0;
    render();
  });
}

async function start() {
  if (!token()) return showLogin();
  try {
    const { user } = await api('GET', '/v1/me');
    if (user.role === 'user') {
      setToken(null);
      return showLogin('This account is not a moderator or admin.');
    }
    state.me = user;
  } catch {
    return;
  }
  document.getElementById('login').hidden = true;
  document.getElementById('app').hidden = false;
  document.getElementById('me').textContent = `${state.me.email} (${state.me.role})`;
  render();
}

// ---- Views ---------------------------------------------------------------

async function render() {
  for (const b of document.querySelectorAll('#tabs button')) {
    if (b.dataset.tab === state.tab) b.setAttribute('aria-current', 'page');
    else b.removeAttribute('aria-current');
  }
  const view = document.getElementById('view');
  try {
    const content = await VIEWS[state.tab]();
    view.replaceChildren(content);
    refreshOpenCount();
  } catch (e) {
    if (e.message !== 'Signed out') view.replaceChildren(h('p', { class: 'error' }, e.message));
  }
}

async function refreshOpenCount() {
  const s = await api('GET', '/v1/admin/stats').catch(() => null);
  const pill = document.getElementById('open-count');
  const n = s?.reports?.open ?? 0;
  pill.hidden = n === 0;
  pill.textContent = String(n);
}

const VIEWS = {
  async overview() {
    const s = await api('GET', '/v1/admin/stats');
    const stat = (label, value) => h('div', { class: 'card stat' }, h('span', { class: 'muted' }, label), h('strong', {}, value));
    return h('div', {},
      h('h2', {}, 'Overview'),
      h('div', { class: 'stats' },
        stat('Open reports', s.reports.open),
        stat('Active cameras', s.points.cameras),
        stat('Active speed bumps', s.points.bumps),
        stat('Hidden points', s.points.hidden),
        stat('Removed points', s.points.removed),
        stat('Drivers', s.users.total),
        stat('With an account', s.users.registered),
        stat('Active this week', s.users.active7d),
        stat('Banned', s.users.banned)),
      h('p', { class: 'muted' },
        `Last 24 hours: ${s.last24h.points} new points, ${s.last24h.votes} votes, ` +
        `${s.last24h.reports} reports, ${s.last24h.users} new drivers.`));
  },

  async reports() {
    state.reportStatus ??= 'open';
    state.page ??= 0;
    const data = await api('GET', `/v1/admin/reports?status=${state.reportStatus}&limit=${PAGE}&offset=${state.page * PAGE}`);
    const filter = h('select', { onchange: (e) => { state.reportStatus = e.target.value; state.page = 0; render(); } },
      ...['open', 'resolved', 'dismissed'].map((s) => h('option', { value: s, selected: s === state.reportStatus }, s)));
    const rows = data.reports.map((r) => {
      const p = r.point;
      const actions = r.status !== 'open' || !p ? null : h('div', { class: 'actions' },
        ...[
          ['keep_point', 'Point is fine', 'Kept the point'],
          ['dismiss', 'Dismiss this report', 'Report dismissed'],
          ['hide_point', 'Hide point', 'Point hidden'],
          ['remove_point', 'Remove point', 'Point removed'],
        ].map(([action, label, done]) => {
          const b = h('button', { class: action === 'remove_point' ? 'danger' : null }, label);
          b.addEventListener('click', () => act(b, () => api('POST', `/v1/admin/reports/${r.id}/resolve`, { action }), done));
          return b;
        }));
      return h('div', { class: 'card row' },
        h('div', { class: 'row-head' },
          h('span', { class: 'title' }, `Report: ${r.reason.replace('_', ' ')}`),
          p && typeTag(p),
          p && statusTag(p.status, p.statusReason),
          p && h('span', { class: 'muted' }, `Point #${p.id}`)),
        r.comment && h('div', {}, `“${r.comment}”`),
        p && h('div', { class: 'meta' },
          mapLink(p),
          h('span', {}, p.speedLimit ? `Limit ${p.speedLimit}` : 'No limit'),
          h('span', {}, `✓ ${p.confirmCount}  ✗ ${p.goneCount}  ⚑ ${p.reportCount}`),
          h('span', {}, `Added by ${who(p.owner)}`),
          p.note && h('span', {}, `Note: ${p.note}`)),
        h('div', { class: 'meta' },
          h('span', {}, `Reported by ${who(r.reporter)}`),
          h('span', {}, when(r.createdAt)),
          r.resolutionNote && h('span', {}, `Note: ${r.resolutionNote}`)),
        actions);
    });
    return h('div', {},
      h('h2', {}, 'Reports'),
      h('div', { class: 'toolbar' }, filter),
      rows.length ? h('div', { class: 'list' }, rows) : h('div', { class: 'empty' }, 'Nothing here. 🎉'),
      pager(state.page, data.reports.length, (pg) => { state.page = pg; render(); }));
  },

  async points() {
    state.pointStatus ??= '';
    state.pointQ ??= '';
    state.page ??= 0;
    const qs = new URLSearchParams({ limit: PAGE, offset: state.page * PAGE });
    if (state.pointStatus === 'reported') qs.set('reported', 'true');
    else if (state.pointStatus) qs.set('status', state.pointStatus);
    if (state.pointQ) qs.set('q', state.pointQ);
    if (state.pointOwner) qs.set('ownerId', state.pointOwner.id);
    const data = await api('GET', `/v1/admin/points?${qs}`);
    const owner = state.pointOwner && h('span', { class: 'muted' },
      `Only points by ${state.pointOwner.label} `,
      h('button', { class: 'link', onclick: () => { state.pointOwner = null; state.page = 0; render(); } }, 'Show all'));

    const status = h('select', { onchange: (e) => { state.pointStatus = e.target.value; state.page = 0; render(); } },
      ...[['', 'All'], ['active', 'Active'], ['hidden', 'Hidden'], ['removed', 'Removed'], ['reported', 'Has open reports']]
        .map(([v, l]) => h('option', { value: v, selected: v === state.pointStatus }, l)));
    const search = h('input', { type: 'search', placeholder: 'Point id, note or owner email', value: state.pointQ });
    const form = h('form', { class: 'toolbar', onsubmit: (e) => { e.preventDefault(); state.pointQ = search.value.trim(); state.page = 0; render(); } },
      status, search, h('button', { type: 'submit' }, 'Search'));

    const rows = data.points.map((p) => {
      const setStatus = (s, label, done) => {
        const b = h('button', { class: s === 'removed' ? 'danger' : null }, label);
        b.addEventListener('click', () => act(b, () => api('PATCH', `/v1/admin/points/${p.id}`, { status: s }), done));
        return b;
      };
      const edit = h('form', { class: 'inline-form', hidden: true },
        h('label', {}, 'Type', h('select', { name: 'type' },
          h('option', { value: 'camera', selected: p.type === 'camera' }, 'Speed camera'),
          h('option', { value: 'bump', selected: p.type === 'bump' }, 'Speed bump'))),
        h('label', {}, 'Speed limit', h('input', { name: 'speedLimit', type: 'number', min: 5, max: 300, value: p.speedLimit ?? '' })),
        h('label', {}, 'Note', h('input', { name: 'note', maxlength: 200, value: p.note ?? '' })),
        h('button', { type: 'submit', class: 'primary' }, 'Save'));
      edit.addEventListener('submit', (e) => {
        e.preventDefault();
        const limit = edit.speedLimit.value.trim();
        act(edit.querySelector('button'), () => api('PATCH', `/v1/admin/points/${p.id}`, {
          type: edit.type.value,
          speedLimit: limit === '' ? null : Number(limit),
          note: edit.note.value.trim() || null,
        }), 'Point saved');
      });
      return h('div', { class: 'card row' },
        h('div', { class: 'row-head' },
          h('span', { class: 'title' }, `#${p.id}`), typeTag(p), statusTag(p.status, p.statusReason),
          p.visibility === 'private' && h('span', { class: 'tag' }, 'private')),
        h('div', { class: 'meta' },
          mapLink(p),
          h('span', {}, p.speedLimit ? `Limit ${p.speedLimit}` : 'No limit'),
          h('span', {}, p.direction == null ? 'Both ways' : `Direction ${p.direction}°`),
          h('span', {}, `✓ ${p.confirmCount}  ✗ ${p.goneCount}  ⚑ ${p.reportCount}`),
          h('span', {}, `Added by ${who(p.owner)}`),
          h('span', {}, `Updated ${when(p.updatedAt)}`)),
        p.note && h('div', {}, `Note: ${p.note}`),
        h('div', { class: 'actions' },
          p.status !== 'active' && setStatus('active', 'Restore', 'Point restored'),
          p.status === 'active' && setStatus('hidden', 'Hide', 'Point hidden'),
          p.status !== 'removed' && setStatus('removed', 'Remove', 'Point removed'),
          h('button', { onclick: () => { edit.hidden = !edit.hidden; } }, 'Edit')),
        edit);
    });
    return h('div', {},
      h('h2', {}, 'Points'),
      form,
      owner,
      rows.length ? h('div', { class: 'list' }, rows) : h('div', { class: 'empty' }, 'No points match.'),
      pager(state.page, data.points.length, (pg) => { state.page = pg; render(); }));
  },

  async users() {
    state.userQ ??= '';
    state.userStatus ??= '';
    state.page ??= 0;
    const qs = new URLSearchParams({ limit: PAGE, offset: state.page * PAGE });
    if (state.userQ) qs.set('q', state.userQ);
    if (state.userStatus) qs.set('status', state.userStatus);
    const data = await api('GET', `/v1/admin/users?${qs}`);

    const status = h('select', { onchange: (e) => { state.userStatus = e.target.value; state.page = 0; render(); } },
      ...[['', 'Everyone'], ['active', 'Active'], ['banned', 'Banned']]
        .map(([v, l]) => h('option', { value: v, selected: v === state.userStatus }, l)));
    const search = h('input', { type: 'search', placeholder: 'Email, name or id', value: state.userQ });
    const form = h('form', { class: 'toolbar', onsubmit: (e) => { e.preventDefault(); state.userQ = search.value.trim(); state.page = 0; render(); } },
      status, search, h('button', { type: 'submit' }, 'Search'));

    const rows = data.users.map((u) => {
      const self = u.id === state.me.id;
      const canManage = !self && (u.role === 'user' || isAdmin());
      const ban = h('form', { class: 'inline-form', hidden: true },
        h('label', {}, 'Reason (the driver sees this)', h('input', { name: 'reason', maxlength: 255, placeholder: 'e.g. adding fake cameras' })),
        h('label', { style: null }, h('span', {}, h('input', { name: 'hide', type: 'checkbox' }), ' Also hide their points')),
        h('button', { type: 'submit', class: 'danger' }, 'Ban'));
      ban.addEventListener('submit', (e) => {
        e.preventDefault();
        act(ban.querySelector('button'), () => api('POST', `/v1/admin/users/${u.id}/ban`, {
          reason: ban.reason.value.trim() || null,
          hidePoints: ban.hide.checked,
        }), 'Driver banned');
      });
      let role = null;
      if (isAdmin() && !self && !u.isAnonymous) {
        role = h('select', {},
          ...['user', 'moderator', 'admin'].map((r) => h('option', { value: r, selected: r === u.role }, r)));
        role.addEventListener('change', () => act(role, () => api('PATCH', `/v1/admin/users/${u.id}`, { role: role.value }), 'Role changed'));
      }
      const unban = h('button', {}, 'Unban');
      unban.addEventListener('click', () => act(unban, () => api('POST', `/v1/admin/users/${u.id}/unban`), 'Driver unbanned'));
      return h('div', { class: 'card row' },
        h('div', { class: 'row-head' },
          h('span', { class: 'title' }, u.email || (u.displayName ? u.displayName : `Anonymous driver #${u.id}`)),
          u.role !== 'user' && h('span', { class: 'tag role' }, u.role),
          u.status === 'banned' && h('span', { class: 'tag banned' }, 'banned'),
          self && h('span', { class: 'muted' }, '(you)')),
        h('div', { class: 'meta' },
          h('span', {}, `#${u.id}`),
          h('span', {}, `${u.points} points`),
          u.openReportsAgainst > 0 && h('span', {}, `⚑ ${u.openReportsAgainst} open reports on their points`),
          h('span', {}, `Joined ${when(u.createdAt)}`),
          h('span', {}, `Last seen ${when(u.lastSeenAt)}`),
          u.banReason && h('span', {}, `Ban reason: ${u.banReason}`)),
        canManage && h('div', { class: 'actions' },
          h('button', {
            onclick: () => {
              Object.assign(state, {
                tab: 'points', pointQ: '', pointStatus: '', page: 0,
                pointOwner: { id: u.id, label: u.email || `driver #${u.id}` },
              });
              render();
            },
          }, 'Points…'),
          u.status === 'banned' ? unban : h('button', { class: 'danger', onclick: () => { ban.hidden = !ban.hidden; } }, 'Ban…'),
          role),
        canManage && ban);
    });
    return h('div', {},
      h('h2', {}, 'Users'),
      form,
      rows.length ? h('div', { class: 'list' }, rows) : h('div', { class: 'empty' }, 'No users match.'),
      pager(state.page, data.users.length, (pg) => { state.page = pg; render(); }));
  },

  async activity() {
    state.page ??= 0;
    const data = await api('GET', `/v1/admin/audit?limit=${PAGE}&offset=${state.page * PAGE}`);
    const rows = data.entries.map((e) =>
      h('div', { class: 'card row' },
        h('div', { class: 'row-head' },
          h('span', { class: 'title' }, e.action.replace('.', ': ').replace('_', ' ')),
          h('span', { class: 'muted' }, `${e.target.type} #${e.target.id}`)),
        h('div', { class: 'meta' },
          h('span', {}, `By ${e.actor ? e.actor.email : 'deleted user'}`),
          h('span', {}, when(e.at)),
          e.details && h('span', {}, JSON.stringify(e.details)))));
    return h('div', {},
      h('h2', {}, 'Activity'),
      h('p', { class: 'muted' }, 'Every moderator and admin action, newest first.'),
      rows.length ? h('div', { class: 'list' }, rows) : h('div', { class: 'empty' }, 'No actions yet.'),
      pager(state.page, data.entries.length, (pg) => { state.page = pg; render(); }));
  },
};

start();
