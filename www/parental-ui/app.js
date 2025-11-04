const UBUS_SESSION = "00000000000000000000000000000000";

async function ubusCall(object, method, params = {}) {
  try {
    const res = await fetch("/ubus", {
      method: "POST",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify({ jsonrpc: "2.0", id: 1, method: "call", params: [UBUS_SESSION, object, method, params] }),
    });
    const json = await res.json();
    if (json.error) throw new Error(JSON.stringify(json.error));
    return json.result[1] || json.result[0];
  } catch (e) {
    console.error("ubus error", e);
    return null;
  }
}

let OVERVIEW = null;
let QUERYLOG = [];

function populateGroupFilter() {
  const sel = document.getElementById("group-filter");
  const current = sel.value || "all";
  sel.innerHTML = '<option value="all">All</option>';
  if (!OVERVIEW || !OVERVIEW.groups) return;
  Object.keys(OVERVIEW.groups).forEach(gkey => {
    const opt = document.createElement('option');
    opt.value = gkey; opt.textContent = OVERVIEW.groups[gkey].name || gkey;
    sel.appendChild(opt);
  });
  sel.value = current;
}

function renderClients() {
  const tbody = document.querySelector("#clients tbody");
  tbody.innerHTML = "";
  if (!OVERVIEW || !OVERVIEW.clients) {
    tbody.innerHTML = '<tr><td colspan="3">No clients found.</td></tr>';
    return;
  }
  const filter = document.getElementById('group-filter').value;
  Object.values(OVERVIEW.clients)
    .filter(c => filter === 'all' || c.group === filter)
    .forEach(client => {
      const row = document.createElement("tr");
      const groupName = client.group && OVERVIEW.groups[client.group] ? OVERVIEW.groups[client.group].name : '—';
      row.innerHTML = `
        <td><strong>${client.name || 'Unnamed'}</strong><br><small>${client.mac}</small></td>
        <td>${groupName}</td>
        <td>
          <button class="btn-pause" data-mac="${client.mac}">Pause 30m</button>
          <button class="btn-block" data-mac="${client.mac}">Block</button>
          <button class="btn-unblock" data-mac="${client.mac}">Unblock</button>
        </td>`;
      tbody.appendChild(row);
    });

  document.querySelectorAll('.btn-pause').forEach(btn => btn.onclick = async () => {
    await ubusCall('parental', 'pause_client', { mac: btn.dataset.mac, duration: 30 });
  });
  document.querySelectorAll('.btn-block').forEach(btn => btn.onclick = async () => {
    await ubusCall('parental', 'block_client', { mac: btn.dataset.mac });
  });
  document.querySelectorAll('.btn-unblock').forEach(btn => btn.onclick = async () => {
    await ubusCall('parental', 'unblock_client', { mac: btn.dataset.mac });
  });
}

function renderUsage() {
  const div = document.getElementById('usage');
  if (!OVERVIEW) { div.textContent = ''; return; }
  // Count queries per known client using match against name or MAC
  const counts = {};
  Object.values(OVERVIEW.clients).forEach(c => counts[c.mac] = 0);
  QUERYLOG.forEach(e => {
    const cl = (e.client || '').toLowerCase();
    Object.values(OVERVIEW.clients).forEach(c => {
      if (!cl) return;
      if (cl.includes((c.mac || '').toLowerCase()) || (c.name && cl.includes(c.name.toLowerCase()))) {
        counts[c.mac] = (counts[c.mac] || 0) + 1;
      }
    });
  });
  const max = Math.max(1, ...Object.values(counts));
  div.innerHTML = '<h3>Recent DNS Queries (by client)</h3>' +
    Object.values(OVERVIEW.clients)
      .map(c => {
        const v = counts[c.mac] || 0;
        const w = Math.round((v / max) * 100);
        return `<div class="bar"><span>${c.name || c.mac}</span><div class="barfill" style="width:${w}%">${v}</div></div>`;
      }).join('');
}

async function refresh() {
  const [overviewData, healthData, qlog] = await Promise.all([
    ubusCall('parental', 'get_overview'),
    ubusCall('parental', 'health'),
    ubusCall('parental', 'adguard_querylog', { limit: 200 })
  ]);
  OVERVIEW = overviewData || OVERVIEW;
  QUERYLOG = (qlog && qlog.entries) || [];
  populateGroupFilter();
  renderClients();
  renderUsage();
  const s = document.getElementById("status");
  if (healthData) {
    s.innerText = `NFT: ${healthData.nft} | FW4: ${healthData.fw4_chain} | Cron: ${healthData.cron} | AdGuard: ${healthData.adguard}`;
  } else {
    s.innerText = 'Disconnected';
  }
}

document.getElementById('group-filter').onchange = () => { renderClients(); };
document.getElementById('btn-sync').onclick = () => ubusCall('parental', 'sync_adguard');

// Dark mode toggle
const DARK_KEY = 'parental.dark';
const applyDark = (v) => { document.body.classList.toggle('dark', !!v); };
applyDark(localStorage.getItem(DARK_KEY) === '1');
document.getElementById('toggle-dark').checked = document.body.classList.contains('dark');
document.getElementById('toggle-dark').onchange = (e) => {
  const on = e.target.checked ? '1' : '0';
  localStorage.setItem(DARK_KEY, on);
  applyDark(on === '1');
};

refresh();
setInterval(refresh, 5000);
