const UBUS_SESSION = "00000000000000000000000000000000";
const THEME_KEY = "parental.ui.theme";
const DARK_QUERY = window.matchMedia ? window.matchMedia("(prefers-color-scheme: dark)") : null;

const state = {
  overview: null,
  health: null,
  querylog: [],
  discovered: [],
  discoveredFilter: "",
  form: { globals: {}, groups: [], clients: [] },
  dirty: false,
  theme: "auto",
};

let toastTimer = null;

async function ubusCall(object, method, params = {}) {
  try {
    const response = await fetch("/ubus", {
      method: "POST",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify({
        jsonrpc: "2.0",
        id: Date.now(),
        method: "call",
        params: [UBUS_SESSION, object, method, params],
      }),
    });
    if (!response.ok) throw new Error(`HTTP ${response.status}`);
    const json = await response.json();
    if (json.error) throw new Error(JSON.stringify(json.error));
    return json.result && json.result[1] ? json.result[1] : json.result ? json.result[0] : null;
  } catch (err) {
    console.error("ubus error", object, method, err);
    return null;
  }
}

function showToast(message, ok = true) {
  const toast = document.getElementById("toast");
  if (!toast) return;
  toast.textContent = message;
  toast.classList.toggle("success", ok);
  toast.classList.toggle("error", !ok);
  toast.hidden = false;
  clearTimeout(toastTimer);
  toastTimer = setTimeout(() => {
    toast.hidden = true;
  }, 4000);
}

function slugifyIdentifier(input) {
  const raw = (input || "").toString().trim().toLowerCase();
  let slug = raw.replace(/[^a-z0-9_-]+/g, "-").replace(/^-+|-+$/g, "");
  if (!slug) slug = "group";
  return slug;
}

function normalizeGroup(value) {
  return (value || "").toString().trim().toLowerCase();
}

function escapeHtml(str) {
  return (str || "")
    .replace(/&/g, "&amp;")
    .replace(/</g, "&lt;")
    .replace(/>/g, "&gt;")
    .replace(/"/g, "&quot;")
    .replace(/'/g, "&#39;");
}

function mapDiscovered(list) {
  if (!Array.isArray(list)) return [];
  const seen = new Map();
  list.forEach((entry) => {
    const mac = (entry && entry.mac ? entry.mac : "").toUpperCase();
    if (!mac) return;
    const current =
      seen.get(mac) || {
        mac,
        hostname: "",
        ips: [],
        ipv6: [],
        sources: [],
        interface: "",
        group: "",
        signal: null,
        last_seen: null,
      };
    const host = entry.hostname || entry.name;
    if (host && !current.hostname) current.hostname = host;
    const ip = entry.ip || entry.address;
    if (ip && !current.ips.includes(ip)) current.ips.push(ip);
    const ip6 = entry.ipv6;
    if (ip6 && !current.ipv6.includes(ip6)) current.ipv6.push(ip6);
    const iface = entry.interface || entry.ifname;
    if (iface && !current.interface) current.interface = iface;
    const group = entry.group;
    if (group && !current.group) current.group = group;
    const sources = [];
    if (Array.isArray(entry.sources)) sources.push(...entry.sources);
    if (entry.source) sources.push(entry.source);
    sources.forEach((src) => {
      if (!src) return;
      if (!current.sources.includes(src)) current.sources.push(src);
    });
    if (
      typeof entry.signal === "number" &&
      (current.signal == null || entry.signal > current.signal)
    ) {
      current.signal = entry.signal;
    }
    const seenTs = Number(entry.last_seen);
    if (!Number.isNaN(seenTs)) {
      if (current.last_seen == null || seenTs > current.last_seen) current.last_seen = seenTs;
    }
    seen.set(mac, current);
  });
  return Array.from(seen.values()).map((item) => ({
    mac: item.mac,
    hostname: item.hostname,
    ip: item.ips[0] || "",
    ips: item.ips,
    ipv6: item.ipv6,
    sources: item.sources,
    interface: item.interface,
    group: item.group,
    signal: item.signal,
    last_seen: item.last_seen,
  }));
}

function buildFormFromOverview(data) {
  const globals = Object.assign(
    {
      enabled: "1",
      default_policy: "allow",
      adguard_url: "",
      adguard_token: "",
      log_level: "info",
      telegram_token: "",
      telegram_chat_id: "",
    },
    data && data.globals ? data.globals : {}
  );

  const groups = [];
  const used = {};
  const rawGroups = (data && data.groups_list) || [];
  rawGroups.forEach((g, idx) => {
    const sectionRaw = g.section && !g.section.startsWith("@") ? g.section : g.name || g.id || `group${idx + 1}`;
    let alias = slugifyIdentifier(sectionRaw);
    let base = alias;
    let counter = 1;
    while (used[alias]) {
      alias = `${base}${++counter}`;
    }
    used[alias] = true;
    groups.push({
      section: alias,
      name: g.name || "",
      dns_profile: g.dns_profile || "",
      quota_daily_min: g.quota_daily_min != null ? String(g.quota_daily_min) : "",
      schedule: Array.isArray(g.schedule) ? g.schedule.slice() : [],
    });
  });

  const clients = ((data && data.clients_list) || []).map((c) => ({
    mac: (c.mac || "").toUpperCase(),
    name: c.name || "",
    group: c.group || "",
    pause_until: c.pause_until || null,
  }));

  return { globals, groups, clients };
}

function setDirty(flag) {
  state.dirty = !!flag;
  const flagEl = document.getElementById("dirty-flag");
  if (flagEl) flagEl.hidden = !state.dirty;
  const saveBtn = document.getElementById("btn-save");
  if (saveBtn) saveBtn.disabled = !state.dirty;
}

function applyTheme(mode) {
  let resolved = mode;
  if (mode === "auto" && DARK_QUERY) {
    resolved = DARK_QUERY.matches ? "dark" : "light";
  }
  document.body.dataset.theme = resolved;
  const select = document.getElementById("theme-mode");
  if (select) select.value = mode;
}

function updateOverviewSummary() {
  const summary = document.querySelectorAll("#overview-summary div dd");
  if (summary.length >= 4) {
    summary[0].textContent = state.form.groups.length;
    summary[1].textContent = state.form.clients.length;
    summary[2].textContent = state.discovered.length;
    summary[3].textContent = state.querylog.length;
  }
}

function updateHealth() {
  const chip = document.getElementById("health-status");
  const kv = document.querySelectorAll("#health-breakdown div dd");
  if (!state.health) {
    if (chip) {
      chip.textContent = "Disconnected";
      chip.classList.remove("good");
      chip.classList.add("bad");
    }
    if (kv.length >= 4) {
      kv[0].textContent = "—";
      kv[1].textContent = "—";
      kv[2].textContent = "—";
      kv[3].textContent = "—";
    }
    return;
  }
  const health = state.health;
  const nft = health.nft || "missing";
  const fw = health.fw4_chain || "missing";
  const cron = health.cron || "missing";
  const adg = health.adguard || "000";
  if (kv.length >= 4) {
    kv[0].textContent = nft;
    kv[1].textContent = fw;
    kv[2].textContent = cron;
    kv[3].textContent = adg;
  }
  if (chip) {
    const healthy = nft === "ok" && fw === "present" && cron === "ok";
    chip.textContent = healthy ? "Healthy" : "Attention";
    chip.classList.toggle("good", healthy);
    chip.classList.toggle("bad", !healthy);
  }
}

function renderGroupFilter() {
  const select = document.getElementById("group-filter");
  if (!select) return;
  const previous = select.value || "all";
  select.innerHTML = '<option value="all">All</option>';
  state.form.groups.forEach((g) => {
    const option = document.createElement("option");
    option.value = g.section;
    option.textContent = g.name || g.section;
    select.appendChild(option);
  });
  if ([...select.options].some((opt) => opt.value === previous)) {
    select.value = previous;
  }
}

function renderClients() {
  const tbody = document.querySelector("#clients-table tbody");
  if (!tbody) return;
  const filterValue = document.getElementById("group-filter").value;
  const normalizedFilter = filterValue === "all" ? "" : normalizeGroup(filterValue);
  const groups = state.form.groups;
  const rows = [];
  state.form.clients.forEach((client, idx) => {
    if (normalizedFilter && normalizeGroup(client.group) !== normalizedFilter) {
      return;
    }
    const groupOptions = groups
      .map((g) => `<option value="${escapeHtml(g.section)}" ${normalizeGroup(client.group) === normalizeGroup(g.section) ? "selected" : ""}>${escapeHtml(g.name || g.section)}</option>`)
      .join("");
    rows.push(`
      <tr data-index="${idx}">
        <td><input type="text" class="client-name" value="${escapeHtml(client.name)}" placeholder="Device name"></td>
        <td><input type="text" class="client-mac" value="${escapeHtml(client.mac)}" placeholder="AA:BB:CC:DD:EE:FF" maxlength="17"></td>
        <td><select class="client-group"><option value="">Unassigned</option>${groupOptions}</select></td>
        <td class="row-actions">
          <button class="mini" data-action="pause">Pause 30m</button>
          <button class="mini" data-action="block">Block</button>
          <button class="mini success" data-action="unblock">Unblock</button>
          <button class="mini danger" data-action="remove">Remove</button>
        </td>
      </tr>
    `);
  });
  if (!rows.length) {
    tbody.innerHTML = '<tr><td colspan="4" class="muted">No clients for this selection.</td></tr>';
  } else {
    tbody.innerHTML = rows.join("");
  }

  tbody.querySelectorAll("input.client-name").forEach((input) => {
    input.addEventListener("input", (e) => {
      const idx = Number(e.target.closest("tr").dataset.index);
      state.form.clients[idx].name = e.target.value;
      setDirty(true);
    });
  });

  tbody.querySelectorAll("input.client-mac").forEach((input) => {
    input.addEventListener("blur", (e) => {
      const idx = Number(e.target.closest("tr").dataset.index);
      const mac = e.target.value.replace(/\s+/g, "").toUpperCase();
      state.form.clients[idx].mac = mac;
      e.target.value = mac;
      setDirty(true);
    });
  });

  tbody.querySelectorAll("select.client-group").forEach((select) => {
    select.addEventListener("change", (e) => {
      const idx = Number(e.target.closest("tr").dataset.index);
      state.form.clients[idx].group = e.target.value;
      setDirty(true);
      renderQuickActions();
    });
  });

  tbody.querySelectorAll("button[data-action]").forEach((btn) => {
    btn.addEventListener("click", async (e) => {
      const tr = e.target.closest("tr");
      const idx = Number(tr.dataset.index);
      const client = state.form.clients[idx];
      const mac = client.mac;
      const action = e.target.dataset.action;
      if (!mac) {
        showToast("Set a MAC address first.", false);
        return;
      }
      if (action === "remove") {
        state.form.clients.splice(idx, 1);
        setDirty(true);
        renderClients();
        renderQuickActions();
        return;
      }
      if (action === "pause") {
        await ubusCall("parental", "pause_client", { mac, duration: 30 });
        showToast(`Paused ${mac} for 30 minutes.`);
      } else if (action === "block") {
        await ubusCall("parental", "block_client", { mac });
        showToast(`Blocked ${mac}.`);
      } else if (action === "unblock") {
        await ubusCall("parental", "unblock_client", { mac });
        showToast(`Unblocked ${mac}.`);
      }
    });
  });
}

function renderUsage() {
  const container = document.getElementById("usage-bars");
  if (!container) return;
  const clients = state.form.clients;
  if (!clients.length) {
    container.innerHTML = '<p class="muted">No managed clients yet.</p>';
    return;
  }
  const counts = new Map();
  clients.forEach((c) => counts.set(c.mac, 0));
  state.querylog.forEach((entry) => {
    const target = matchQueryToClient(entry, clients);
    if (target && counts.has(target)) {
      counts.set(target, counts.get(target) + 1);
    }
  });
  const max = Math.max(1, ...counts.values());
  const rows = clients.map((c) => {
    const count = counts.get(c.mac) || 0;
    const width = Math.round((count / max) * 100);
    const label = c.name || c.mac;
    return `
      <div class="bar">
        <span class="label">${escapeHtml(label)}</span>
        <div class="bar-track"><div class="bar-fill" style="width:${width}%"></div></div>
        <span>${count}</span>
      </div>
    `;
  });
  container.innerHTML = rows.join("");
}

function matchQueryToClient(entry, clients) {
  const clientField = (entry && entry.client ? entry.client : "").toLowerCase();
  if (!clientField) return null;
  for (const client of clients) {
    if (!client.mac) continue;
    if (clientField.includes(client.mac.toLowerCase())) return client.mac;
    if (client.name && clientField.includes(client.name.toLowerCase())) return client.mac;
  }
  return null;
}

function filterDiscoveredList(devices) {
  const needle = (state.discoveredFilter || "").trim().toLowerCase();
  if (!needle) return devices;
  return devices.filter((dev) => {
    const fields = [
      dev.mac,
      dev.hostname,
      dev.ip,
      ...(Array.isArray(dev.ips) ? dev.ips : []),
      ...(Array.isArray(dev.ipv6) ? dev.ipv6 : []),
      ...(Array.isArray(dev.sources) ? dev.sources : []),
      dev.interface,
      dev.group,
    ]
      .filter(Boolean)
      .join(" ")
      .toLowerCase();
    return fields.includes(needle);
  });
}

function formatLastSeen(value) {
  if (value == null || value === "") return "";
  const numeric = Number(value);
  if (Number.isNaN(numeric)) return "";
  let delta = numeric;
  const now = Date.now() / 1000;
  if (numeric > 1e9) {
    delta = Math.max(0, now - numeric);
  }
  if (delta < 60) return "just now";
  if (delta < 3600) return `${Math.round(delta / 60)} min ago`;
  if (delta < 86400) return `${Math.round(delta / 3600)} hr ago`;
  const days = Math.round(delta / 86400);
  return `${days} day${days === 1 ? "" : "s"} ago`;
}

function renderDiscovered() {
  const container = document.getElementById("discovered-list");
  if (!container) return;
  const filterInput = document.getElementById("discovered-filter");
  if (filterInput && filterInput.value !== state.discoveredFilter) {
    filterInput.value = state.discoveredFilter;
  }
  const devices = filterDiscoveredList(state.discovered);
  if (!devices.length) {
    container.innerHTML = `<p class="muted">${state.discoveredFilter ? "No devices match your search." : "No devices discovered on LAN."}</p>`;
    return;
  }
  const rows = devices.map((dev) => {
    const managedClient = state.form.clients.find((c) => c.mac === dev.mac);
    const managed = Boolean(managedClient);
    const ipParts = [];
    if (dev.ip) ipParts.push(dev.ip);
    if (Array.isArray(dev.ips)) {
      dev.ips.forEach((ip) => {
        if (ip && !ipParts.includes(ip)) ipParts.push(ip);
      });
    }
    if (Array.isArray(dev.ipv6)) {
      dev.ipv6.forEach((ip) => {
        if (ip && !ipParts.includes(ip)) ipParts.push(ip);
      });
    }
    const ipLabel = ipParts.length ? ` • ${escapeHtml(ipParts.join(" · "))}` : "";
    const tags = [];
    if (dev.group) tags.push(`<span class="tag group-tag">Group: ${escapeHtml(dev.group)}</span>`);
    if (dev.interface) tags.push(`<span class="tag">${escapeHtml(dev.interface)}</span>`);
    if (typeof dev.signal === "number") tags.push(`<span class="tag">Signal ${escapeHtml(String(dev.signal))} dBm</span>`);
    const lastSeen = formatLastSeen(dev.last_seen);
    if (lastSeen) tags.push(`<span class="tag muted">${escapeHtml(lastSeen)}</span>`);
    if (Array.isArray(dev.sources) && dev.sources.length) {
      dev.sources.forEach((src) => {
        if (!src) return;
        tags.push(`<span class="tag subtle">${escapeHtml(src)}</span>`);
      });
    }
    const tagLine = tags.length ? `<div class="device-meta">${tags.join("")}</div>` : "";
    const managedLabel = managed
      ? `<span class="muted">Managed${managedClient && managedClient.group ? ` (${escapeHtml(managedClient.group)})` : ""}</span>`
      : '<button class="mini" data-add="1">Add</button>';
    return `
      <div class="device" data-mac="${dev.mac}">
        <div class="device-info">
          <strong>${escapeHtml(dev.hostname || dev.mac)}</strong>
          <span>${escapeHtml(dev.mac)}${ipLabel}</span>
          ${tagLine}
        </div>
        ${managedLabel}
      </div>
    `;
  });
  container.innerHTML = rows.join("\n");
  container.querySelectorAll(".device button[data-add]").forEach((btn) => {
    btn.addEventListener("click", (e) => {
      const mac = e.target.closest(".device").dataset.mac;
      addDiscoveredClient(mac);
    });
  });
}

function addDiscoveredClient(mac) {
  const device = state.discovered.find((d) => d.mac === mac);
  if (!device) return;
  const existing = state.form.clients.find((c) => c.mac === mac);
  const selectedGroup = document.getElementById("group-filter").value;
  if (existing) {
    if (!existing.name && device.hostname) existing.name = device.hostname;
    if (!existing.group && selectedGroup !== "all") existing.group = selectedGroup;
  } else {
    state.form.clients.push({
      mac,
      name: device.hostname || "",
      group: selectedGroup !== "all" ? selectedGroup : "",
      pause_until: null,
    });
  }
  setDirty(true);
  renderClients();
  renderQuickActions();
  showToast(`${mac} added to managed clients.`);
}

function renderGroups() {
  const container = document.getElementById("groups-container");
  if (!container) return;
  if (!state.form.groups.length) {
    container.innerHTML = '<p class="muted">No groups defined. Create one to start scheduling access.</p>';
    return;
  }
  const rows = state.form.groups.map((group, idx) => {
    const assigned = state.form.clients.filter((c) => normalizeGroup(c.group) === normalizeGroup(group.section)).length;
    return `
      <div class="group-card" data-index="${idx}">
        <button class="group-remove mini" title="Remove group">✕</button>
        <h4>${escapeHtml(group.name || group.section)}</h4>
        <div class="group-meta">
          <label>Identifier
            <input type="text" class="group-section" value="${escapeHtml(group.section)}">
          </label>
          <label>Display name
            <input type="text" class="group-name" value="${escapeHtml(group.name)}" placeholder="Family">
          </label>
        </div>
        <div class="group-meta">
          <label>DNS profile
            <input type="text" class="group-dns" value="${escapeHtml(group.dns_profile)}" placeholder="AdGuard profile">
          </label>
          <label>Daily quota (minutes)
            <input type="number" min="0" class="group-quota" value="${escapeHtml(group.quota_daily_min || "")}">
          </label>
        </div>
        <div class="group-meta full">
          <label>Schedules (one per line)
            <textarea class="group-schedule">${escapeHtml((group.schedule || []).join("\n"))}</textarea>
          </label>
        </div>
        <div class="group-meta full muted">Assigned clients: ${assigned}</div>
      </div>
    `;
  });
  container.innerHTML = rows.join("");

  container.querySelectorAll(".group-remove").forEach((btn) => {
    btn.addEventListener("click", (e) => {
      const idx = Number(e.target.closest(".group-card").dataset.index);
      const removed = state.form.groups.splice(idx, 1)[0];
      state.form.clients.forEach((c) => {
        if (normalizeGroup(c.group) === normalizeGroup(removed.section)) {
          c.group = "";
        }
      });
      setDirty(true);
      renderGroupFilter();
      renderGroups();
      renderClients();
      renderQuickActions();
    });
  });

  container.querySelectorAll("input.group-section").forEach((input) => {
    input.addEventListener("change", (e) => {
      const card = e.target.closest(".group-card");
      const idx = Number(card.dataset.index);
      const oldValue = state.form.groups[idx].section;
      let value = slugifyIdentifier(e.target.value || state.form.groups[idx].name || `group${idx + 1}`);
      if (!value) value = `group${idx + 1}`;
      state.form.groups[idx].section = value;
      e.target.value = value;
      state.form.clients.forEach((c) => {
        if (normalizeGroup(c.group) === normalizeGroup(oldValue)) {
          c.group = value;
        }
      });
      setDirty(true);
      renderGroupFilter();
      renderClients();
      renderQuickActions();
    });
  });

  container.querySelectorAll("input.group-name").forEach((input) => {
    input.addEventListener("input", (e) => {
      const idx = Number(e.target.closest(".group-card").dataset.index);
      state.form.groups[idx].name = e.target.value;
      setDirty(true);
      renderGroupFilter();
      renderClients();
      renderQuickActions();
    });
  });

  container.querySelectorAll("input.group-dns").forEach((input) => {
    input.addEventListener("input", (e) => {
      const idx = Number(e.target.closest(".group-card").dataset.index);
      state.form.groups[idx].dns_profile = e.target.value;
      setDirty(true);
    });
  });

  container.querySelectorAll("input.group-quota").forEach((input) => {
    input.addEventListener("input", (e) => {
      const idx = Number(e.target.closest(".group-card").dataset.index);
      const value = e.target.value;
      state.form.groups[idx].quota_daily_min = value === "" ? "" : value;
      setDirty(true);
    });
  });

  container.querySelectorAll("textarea.group-schedule").forEach((textarea) => {
    textarea.addEventListener("input", (e) => {
      const idx = Number(e.target.closest(".group-card").dataset.index);
      const lines = e.target.value
        .split(/\n+/)
        .map((line) => line.trim())
        .filter((line) => line.length > 0);
      state.form.groups[idx].schedule = lines;
      setDirty(true);
    });
  });
}

function renderSettings() {
  const globals = state.form.globals;
  const enabled = document.getElementById("setting-enabled");
  const policy = document.getElementById("setting-default-policy");
  const agUrl = document.getElementById("setting-adguard-url");
  const agToken = document.getElementById("setting-adguard-token");
  const logLevel = document.getElementById("setting-log-level");
  const telegramToken = document.getElementById("setting-telegram-token");
  const telegramChat = document.getElementById("setting-telegram-chat");
  if (enabled) enabled.checked = globals.enabled !== "0";
  if (policy) policy.value = globals.default_policy || "allow";
  if (agUrl) agUrl.value = globals.adguard_url || "";
  if (agToken) agToken.value = globals.adguard_token || "";
  if (logLevel) logLevel.value = globals.log_level || "info";
  if (telegramToken) telegramToken.value = globals.telegram_token || "";
  if (telegramChat) telegramChat.value = globals.telegram_chat_id || "";
}

function renderQuickActions() {
  const buttons = document.querySelectorAll(".quick-actions .action");
  if (!buttons.length) return;
  const filter = document.getElementById("group-filter").value;
  if (!state.form.groups.length || filter === "all") {
    buttons.forEach((btn) => (btn.disabled = true));
    return;
  }
  const group = state.form.groups.find((g) => normalizeGroup(g.section) === normalizeGroup(filter));
  const display = group ? group.name || group.section : filter;
  buttons.forEach((btn) => {
    btn.disabled = false;
    const action = btn.dataset.action;
    if (action === "pause-all") btn.textContent = `Pause ${display} (30m)`;
    if (action === "block-all") btn.textContent = `Block ${display}`;
    if (action === "unblock-all") btn.textContent = `Unblock ${display}`;
    btn.dataset.group = filter;
  });
}

function renderAll() {
  updateOverviewSummary();
  updateHealth();
  renderGroupFilter();
  renderClients();
  renderUsage();
  renderDiscovered();
  renderGroups();
  renderSettings();
  renderQuickActions();
}

function attachStaticHandlers() {
  const theme = localStorage.getItem(THEME_KEY) || "auto";
  state.theme = theme;
  applyTheme(theme);
  const themeSelect = document.getElementById("theme-mode");
  if (themeSelect) {
    themeSelect.addEventListener("change", (e) => {
      state.theme = e.target.value;
      localStorage.setItem(THEME_KEY, state.theme);
      applyTheme(state.theme);
    });
  }
  if (DARK_QUERY) {
    const listener = () => applyTheme(state.theme);
    if (DARK_QUERY.addEventListener) {
      DARK_QUERY.addEventListener("change", listener);
    } else if (DARK_QUERY.addListener) {
      DARK_QUERY.addListener(listener);
    }
  }

  document.getElementById("group-filter").addEventListener("change", () => {
    renderClients();
    renderQuickActions();
  });

  document.getElementById("btn-add-client").addEventListener("click", () => {
    const selectedGroup = document.getElementById("group-filter").value;
    state.form.clients.push({
      mac: "",
      name: "",
      group: selectedGroup !== "all" ? selectedGroup : "",
      pause_until: null,
    });
    setDirty(true);
    renderClients();
  });

  document.getElementById("btn-add-group").addEventListener("click", () => {
    const base = `group${state.form.groups.length + 1}`;
    let section = slugifyIdentifier(base);
    const used = new Set(state.form.groups.map((g) => normalizeGroup(g.section)));
    let counter = 1;
    while (used.has(normalizeGroup(section))) {
      section = slugifyIdentifier(`${base}-${++counter}`);
    }
    state.form.groups.push({ section, name: "", dns_profile: "", quota_daily_min: "", schedule: [] });
    setDirty(true);
    renderGroupFilter();
    renderGroups();
    renderQuickActions();
  });

  const scanBtn = document.getElementById("btn-scan");
  if (scanBtn) {
    scanBtn.addEventListener("click", () => refresh(true));
  }
  const discoveryFilter = document.getElementById("discovered-filter");
  if (discoveryFilter) {
    discoveryFilter.addEventListener("input", (e) => {
      state.discoveredFilter = e.target.value;
      renderDiscovered();
    });
  }

  document.getElementById("btn-refresh").addEventListener("click", () => refresh());
  document.getElementById("btn-sync").addEventListener("click", async () => {
    await ubusCall("parental", "sync_adguard");
    showToast("AdGuard sync triggered.");
  });
  document.getElementById("btn-apply").addEventListener("click", async () => {
    await ubusCall("parental", "apply");
    showToast("Firewall rules reloaded.");
  });
  document.getElementById("btn-save").addEventListener("click", () => saveConfig());

  document.querySelectorAll(".tab-button").forEach((btn) => {
    btn.addEventListener("click", () => {
      const target = btn.dataset.tab;
      document.querySelectorAll(".tab-button").forEach((b) => b.classList.toggle("active", b === btn));
      document.querySelectorAll(".tab-panel").forEach((panel) => {
        panel.classList.toggle("active", panel.id === `tab-${target}`);
      });
    });
  });

  document.querySelectorAll(".quick-actions .action").forEach((btn) => {
    btn.addEventListener("click", async (e) => {
      const action = e.target.dataset.action;
      const groupValue = e.target.dataset.group;
      const clients = state.form.clients.filter((c) => normalizeGroup(c.group) === normalizeGroup(groupValue));
      if (!clients.length) {
        showToast("No clients in this group.", false);
        return;
      }
      if (action === "pause-all") {
        await Promise.all(clients.map((c) => ubusCall("parental", "pause_client", { mac: c.mac, duration: 30 })));
        showToast(`Paused ${clients.length} client(s).`);
      } else if (action === "block-all") {
        await Promise.all(clients.map((c) => ubusCall("parental", "block_client", { mac: c.mac })));
        showToast(`Blocked ${clients.length} client(s).`);
      } else if (action === "unblock-all") {
        await Promise.all(clients.map((c) => ubusCall("parental", "unblock_client", { mac: c.mac })));
        showToast(`Unblocked ${clients.length} client(s).`);
      }
    });
  });

  const enabled = document.getElementById("setting-enabled");
  if (enabled) enabled.addEventListener("change", (e) => {
    state.form.globals.enabled = e.target.checked ? "1" : "0";
    setDirty(true);
  });
  const policy = document.getElementById("setting-default-policy");
  if (policy) policy.addEventListener("change", (e) => {
    state.form.globals.default_policy = e.target.value;
    setDirty(true);
  });
  const agUrl = document.getElementById("setting-adguard-url");
  if (agUrl) agUrl.addEventListener("input", (e) => {
    state.form.globals.adguard_url = e.target.value;
    setDirty(true);
  });
  const agToken = document.getElementById("setting-adguard-token");
  if (agToken) agToken.addEventListener("input", (e) => {
    state.form.globals.adguard_token = e.target.value;
    setDirty(true);
  });
  const logLevel = document.getElementById("setting-log-level");
  if (logLevel) logLevel.addEventListener("change", (e) => {
    state.form.globals.log_level = e.target.value;
    setDirty(true);
  });
  const telToken = document.getElementById("setting-telegram-token");
  if (telToken) telToken.addEventListener("input", (e) => {
    state.form.globals.telegram_token = e.target.value;
    setDirty(true);
  });
  const telChat = document.getElementById("setting-telegram-chat");
  if (telChat) telChat.addEventListener("input", (e) => {
    state.form.globals.telegram_chat_id = e.target.value;
    setDirty(true);
  });
}

async function refresh(forceReload = false) {
  const refreshBtn = document.getElementById("btn-refresh");
  if (refreshBtn) refreshBtn.disabled = true;
  try {
    const [overview, health, querylog] = await Promise.all([
      ubusCall("parental", "get_overview"),
      ubusCall("parental", "health"),
      ubusCall("parental", "adguard_querylog", { limit: 200 }),
    ]);
    if (health) state.health = health;
    if (querylog && Array.isArray(querylog.entries)) state.querylog = querylog.entries;
    if (overview) {
      state.overview = overview;
      state.discovered = mapDiscovered(overview.discovered);
      if (!state.dirty || forceReload) {
        state.form = buildFormFromOverview(overview);
        setDirty(false);
      }
    }
    renderAll();
    const stamp = document.getElementById("last-refresh");
    if (stamp) stamp.textContent = `Last update: ${new Date().toLocaleTimeString()}`;
  } catch (err) {
    console.error("refresh error", err);
    showToast("Failed to refresh data.", false);
  } finally {
    if (refreshBtn) refreshBtn.disabled = false;
  }
}

function buildSavePayload() {
  const globals = Object.assign({}, state.form.globals);
  const groups = state.form.groups.map((g, idx) => ({
    section: g.section || `group${idx + 1}`,
    name: g.name || null,
    dns_profile: g.dns_profile || null,
    quota_daily_min: g.quota_daily_min === "" ? null : g.quota_daily_min,
    schedule: Array.isArray(g.schedule) ? g.schedule.filter((line) => line && line.trim()) : [],
  }));
  const clients = state.form.clients
    .filter((c) => c.mac && c.mac.length)
    .map((c) => ({
      mac: c.mac.toUpperCase(),
      name: c.name || null,
      group: c.group || "",
      pause_until: c.pause_until || null,
    }));
  return { globals, groups, clients };
}

async function saveConfig() {
  if (!state.dirty) return;
  const payload = buildSavePayload();
  const result = await ubusCall("parental", "save_config", payload);
  if (result && result.status === "ok") {
    showToast("Configuration saved.");
    setDirty(false);
    await refresh(true);
  } else {
    showToast("Failed to save configuration.", false);
  }
}

attachStaticHandlers();
setDirty(false);
renderAll();
refresh();
setInterval(() => refresh(false), 5000);
