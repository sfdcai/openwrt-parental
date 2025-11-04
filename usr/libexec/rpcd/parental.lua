#!/usr/bin/lua
-- rpcd plugin providing parental.* methods

local json
do
  local ok, lib = pcall(require, "luci.jsonc")
  if ok and type(lib) == "table" and type(lib.parse) == "function" then
    json = lib
  else
    local fallback_ok, fallback = pcall(require, "cjson.safe")
    if fallback_ok and type(fallback) == "table" then
      json = {
        parse = function(raw)
          if type(raw) ~= "string" then return nil end
          local decoded = fallback.decode(raw)
          if type(decoded) == "table" then return decoded end
          return nil
        end,
      }
    else
      io.stderr:write("[parental] luci.jsonc unavailable, JSON parsing disabled\n")
      json = {
        parse = function(_)
          return nil
        end,
      }
    end
  end
end

local function sh(cmd)
  local f = io.popen(cmd .. " 2>&1")
  if not f then return "" end
  local out = f:read("*a")
  f:close()
  return out or ""
end

local function trim(s)
  return (s or ""):gsub("^%s+", ""):gsub("%s+$", "")
end

local function parse_uci()
  local out = sh("uci -q show parental")
  local globals = {}
  local raw_groups = {}
  local raw_clients = {}
  local group_order = {}
  local client_order = {}

  local function ensure_group(section)
    if not raw_groups[section] then
      raw_groups[section] = { section = section, schedule = {}, clients = {} }
      table.insert(group_order, section)
    end
    return raw_groups[section]
  end

  local function ensure_client(section)
    if not raw_clients[section] then
      raw_clients[section] = { section = section }
      table.insert(client_order, section)
    end
    return raw_clients[section]
  end

  for line in out:gmatch("[^\n]+") do
    repeat
      local section, stype = line:match("^parental%.([^.=]+)=(%w+)$")
      if section and stype == "group" then
        local g = ensure_group(section)
        g.type = stype
        break
      elseif section and stype == "client" then
        local c = ensure_client(section)
        c.type = stype
        break
      end

      local key, value = line:match("^parental%.settings%.([^.=]+)='(.-)'$")
      if key then
        globals[key] = value
        break
      end

      local sec, opt, val = line:match("^parental%.([^.=]+)%.([^.=]+)='(.-)'$")
      if sec and sec ~= "settings" then
        local target = "group"
        if (raw_clients[sec] and raw_clients[sec].type == "client") or opt == "mac" or opt == "pause_until" or opt == "group" then
          target = "client"
        elseif raw_groups[sec] and raw_groups[sec].type == "group" then
          target = "group"
        end

        if target == "group" then
          local g = ensure_group(sec)
          if opt == "schedule" then
            table.insert(g.schedule, val)
          elseif opt == "clients" then
            table.insert(g.clients, val)
          else
            g[opt] = val
          end
        else
          local c = ensure_client(sec)
          if opt == "mac" then
            c.mac = val
          elseif opt == "name" then
            c.name = val
          elseif opt == "group" then
            c.group = val
          elseif opt == "pause_until" then
            c.pause_until = val
          end
        end
        break
      end
    until true
  end

  local groups_map = {}
  local groups_list = {}
  for _, section in ipairs(group_order) do
    local g = raw_groups[section]
    if g and (g.type == "group" or section:match("@group%[")) then
      local name = g.name or g[".name"] or section
      local entry = {
        id = section,
        section = section,
        name = name,
        dns_profile = g.dns_profile,
        schedule = g.schedule or {},
        clients = g.clients or {},
        quota_daily_min = g.quota_daily_min and tonumber(g.quota_daily_min) or nil
      }
      groups_map[section] = entry
      table.insert(groups_list, entry)
    end
  end

  local clients_map = {}
  local clients_list = {}
  for _, section in ipairs(client_order) do
    local c = raw_clients[section]
    if c and (c.type == "client" or section:match("@client%[")) then
      local mac = (c.mac or ""):upper()
      if mac ~= "" then
        local entry = {
          id = section,
          section = section,
          mac = mac,
          name = c.name,
          group = c.group,
          pause_until = c.pause_until and tonumber(c.pause_until) or nil
        }
        clients_map[mac] = entry
        table.insert(clients_list, entry)
      end
    end
  end

  return {
    globals = globals,
    groups = groups_map,
    groups_list = groups_list,
    clients = clients_map,
    clients_list = clients_list
  }
end

local function merge_fields(target, fields)
  for k, v in pairs(fields) do
    if v and v ~= "" and (not target[k] or target[k] == "") then
      target[k] = v
    end
  end
end

local function decode_json(raw)
  if not raw or raw == "" then return nil end
  local ok, parsed = pcall(json.parse, raw)
  if ok and type(parsed) == "table" then return parsed end
  return nil
end

local function gather_discovered(managed_clients)
  local discovered = {}
  local seen = {}
  local lan_ifaces = {}

  local function track_iface(name)
    name = trim(name or "")
    if name ~= "" then
      lan_ifaces[name] = true
    end
  end

  local function add(mac, fields)
    mac = (mac or ""):upper()
    if mac == "" or mac == "00:00:00:00:00:00" then return end
    local entry = seen[mac]
    if not entry then
      entry = { mac = mac }
      seen[mac] = entry
      table.insert(discovered, entry)
    end

    if type(fields) == "table" then
      if fields.interface then
        track_iface(fields.interface)
        entry.interface = entry.interface or fields.interface
      end
      if fields.group and (not entry.group or entry.group == "") then
        entry.group = fields.group
      end
      if fields.signal then
        local sig = tonumber(fields.signal)
        if sig and (not entry.signal or sig > entry.signal) then
          entry.signal = sig
        end
      end
      if fields.last_seen then
        local ts = tonumber(fields.last_seen)
        if ts and (not entry.last_seen or ts > entry.last_seen) then
          entry.last_seen = ts
        end
      end
      if fields.ipv6 and (not entry.ipv6 or entry.ipv6 == "") then
        entry.ipv6 = fields.ipv6
      end
      local src = fields.source or fields.origin
      if src and src ~= "" then
        entry.sources = entry.sources or {}
        local exists = false
        for _, val in ipairs(entry.sources) do
          if val == src then exists = true break end
        end
        if not exists then table.insert(entry.sources, src) end
      end
      merge_fields(entry, {
        hostname = fields.hostname or fields.name,
        ip = fields.ip or fields.address,
        vendor = fields.vendor,
        interface = fields.interface,
      })
    end
  end

  local function collect_neighbors(list, origin, iface)
    if type(list) ~= "table" then return end
    for _, item in pairs(list) do
      if type(item) == "table" then
        add(item.lladdr or item.mac or item["mac-address"], {
          ip = item.ip or item.ipv4 or item.address or item["ipv4-address"],
          ipv6 = item.ipv6 or item["ipv6-address"],
          hostname = item.host or item.name or item.hostname,
          interface = iface or item.ifname or item.interface,
          source = origin or item.source,
          last_seen = item.last_seen or item.time or item.age,
        })
      end
    end
  end

  local function collect_dhcp(list, origin)
    if type(list) ~= "table" then return end
    for _, lease in pairs(list) do
      if type(lease) == "table" then
        add(lease.mac or lease.hwaddr, {
          ip = lease.ip or lease.ipaddr or lease["ipv4-address"],
          hostname = lease.hostname or lease.name,
          interface = lease.interface,
          source = origin or "dhcp",
          last_seen = lease.expires or lease.valid or lease.lease_time,
        })
      end
    end
  end

  local function collect_assoc(map, origin, iface)
    if type(map) ~= "table" then return end
    for mac, info in pairs(map) do
      if type(info) == "table" then
        local derived_iface = iface or info.ifname
        if (not derived_iface or derived_iface == "") and type(origin) == "string" then
          local hint = origin:match("%.([^.]+)$")
          if hint and hint ~= "" then derived_iface = hint end
        end
        add(mac, {
          hostname = info.hostname or info.name,
          ip = info.ipaddr or info.ip,
          interface = derived_iface,
          source = origin,
          signal = info.signal or info.signal_avg or info.rssi,
        })
      elseif type(info) == "string" and type(mac) == "string" then
        add(mac, { source = origin, interface = iface })
      end
    end
  end

  local status = decode_json(sh("ubus call network.interface.lan status"))
  if status then
    track_iface(status.ifname)
    track_iface(status.l3_device)
    track_iface(status.device)
    collect_neighbors(status.neighbors or status.neighbor, "lan", status.ifname)
    local dhcp = status["dhcp-server"]
    if type(dhcp) == "table" then
      collect_dhcp(dhcp.clients, "dhcp")
    end
  end

  local dump = decode_json(sh("ubus call network.interface dump"))
  if dump and type(dump.interface) == "table" then
    for _, iface in ipairs(dump.interface) do
      if type(iface) == "table" then
        track_iface(iface.device)
        track_iface(iface.l3_device)
        collect_neighbors(iface.neighbor or iface.neighbors, iface.interface or iface.device, iface.device)
      end
    end
  end

  local device_list = {}
  for name, _ in pairs(lan_ifaces) do
    table.insert(device_list, name)
  end
  if #device_list == 0 then
    device_list = { "br-lan", "lan" }
  end

  for _, dev in ipairs(device_list) do
    local payload = string.format("'{\"name\":\"%s\"}'", dev)
    local info = decode_json(sh(string.format("ubus call network.device status %s", payload)))
    if info then
      collect_neighbors(info.neighbor or info.neighbors, dev, info.ifname or dev)
    end
  end

  local dhcp4 = decode_json(sh("ubus call dhcp ipv4leases"))
  if dhcp4 then
    collect_dhcp(dhcp4.leases or dhcp4.clients, "dhcpv4")
  end
  local dhcp6 = decode_json(sh("ubus call dhcp ipv6leases"))
  if dhcp6 then
    collect_dhcp(dhcp6.leases or dhcp6.clients, "dhcpv6")
  end

  local wireless = decode_json(sh("ubus call network.wireless status"))
  if wireless then
    local ifaces = wireless.interfaces or wireless["radio0"] or wireless["interface"]
    if type(ifaces) == "table" then
      for _, iface in pairs(ifaces) do
        if type(iface) == "table" then
          track_iface(iface.ifname)
          collect_assoc(iface.assoclist or iface.stations, iface.ifname or "wireless", iface.ifname)
        end
      end
    end
  end

  local hostapd_list = sh("ubus -S list hostapd.* 2>/dev/null")
  for line in hostapd_list:gmatch("[^\n]+") do
    local obj = trim(line)
    if obj ~= "" then
      local res = decode_json(sh(string.format("ubus call %s get_clients", obj)))
      if res then
        if type(res.clients) == "table" then
          collect_assoc(res.clients, obj, res.ifname)
        end
        if type(res.stations) == "table" then
          collect_assoc(res.stations, obj, res.ifname)
        end
      end
    end
  end

  local iwinfo_list = sh("ubus -S list iwinfo.* 2>/dev/null")
  for line in iwinfo_list:gmatch("[^\n]+") do
    local obj = trim(line)
    if obj ~= "" then
      local res = decode_json(sh(string.format("ubus call %s assoclist", obj)))
      if res and type(res.results) == "table" then
        for _, station in pairs(res.results) do
          if type(station) == "table" then
            add(station.mac, {
              signal = station.signal or station.rssi,
              interface = station.ifname or res.ifname,
              source = obj,
            })
          end
        end
      end
    end
  end

  local ip_now = os.time and os.time() or nil
  for _, dev in ipairs(device_list) do
    local raw = sh(string.format("ip neigh show dev %s 2>/dev/null", dev))
    for line in raw:gmatch("[^\n]+") do
      local ip = line:match("^(%S+)")
      local mac = line:match("lladdr (%S+)")
      if mac then
        add(mac, { ip = ip, interface = dev, source = "ip", last_seen = ip_now })
      end
    end
  end

  local leases = io.open("/tmp/dhcp.leases", "r")
  if leases then
    for line in leases:lines() do
      local _, mac, ip, host = line:match("^(%S+)%s+(%S+)%s+(%S+)%s+(%S+)")
      add(mac, {
        ip = ip,
        hostname = host ~= "*" and host or nil,
        source = "dhcp",
      })
    end
    leases:close()
  end

  if type(managed_clients) == "table" then
    for _, client in ipairs(managed_clients) do
      if type(client) == "table" then
        add(client.mac, {
          hostname = client.name,
          group = client.group,
          source = "configured",
        })
      end
    end
  end

  table.sort(discovered, function(a, b)
    local ah = trim(a.hostname or ""):lower()
    local bh = trim(b.hostname or ""):lower()
    if ah ~= bh then
      if ah == "" then return false end
      if bh == "" then return true end
      return ah < bh
    end
    return (a.mac or "") < (b.mac or "")
  end)

  return discovered
end

local function uci_quote(v)
  if v == nil then
    return '""'
  end
  return string.format("%q", tostring(v))
end

local function run_batch(commands)
  local pipe = io.popen("uci batch", "w")
  if not pipe then return false end
  for _, cmd in ipairs(commands) do
    pipe:write(cmd)
    pipe:write("\n")
  end
  pipe:write("commit parental\n")
  pipe:close()
  return true
end

local function save_config(args)
  local globals = {}
  if type(args.globals) == "table" then globals = args.globals end
  local groups = {}
  if type(args.groups) == "table" then groups = args.groups end
  local clients = {}
  if type(args.clients) == "table" then clients = args.clients end

  local function norm_key(v)
    return (tostring(v or ""):lower())
  end

  local used_alias = {}
  local alias_for_index = {}
  local alias_lookup = {}

  local function map_alias(value, alias)
    local k = norm_key(value)
    if k and k ~= "" and not alias_lookup[k] then
      alias_lookup[k] = alias
    end
  end

  for idx, group in ipairs(groups) do
    if type(group) ~= "table" then group = {} end
    local raw = group.section or group.id or group.name or string.format("group%d", idx)
    raw = tostring(raw)
    raw = raw:gsub("%s+", "-")
    local candidate = raw:lower():gsub("[^a-z0-9_%-]", "")
    if candidate == "" then
      candidate = string.format("group%d", idx)
    end
    local final = candidate
    local n = 1
    while used_alias[final] do
      n = n + 1
      final = string.format("%s%d", candidate, n)
    end
    used_alias[final] = true
    alias_for_index[idx] = final
    map_alias(group.section, final)
    map_alias(group.id, final)
    map_alias(group.name, final)
    map_alias(candidate, final)
    map_alias(final, final)
    groups[idx] = group
    group.section = final
  end

  local group_clients = {}
  for _, client in ipairs(clients) do
    if type(client) == "table" then
      local gk = alias_lookup[norm_key(client.group)] or norm_key(client.group)
      local mac = client.mac and client.mac:upper() or ""
      if gk and gk ~= "" and mac ~= "" then
        group_clients[gk] = group_clients[gk] or {}
        table.insert(group_clients[gk], mac)
      end
    end
  end

  local commands = { "delete parental", "set parental.settings=global" }

  for key, value in pairs(globals) do
    if value ~= nil then
      table.insert(commands, string.format("set parental.settings.%s=%s", key, uci_quote(value)))
    end
  end

  for idx, group in ipairs(groups) do
    if type(group) == "table" then
      local alias = alias_for_index[idx] or group.section or string.format("group%d", idx)
      local prefix = string.format("parental.%s", alias)
      table.insert(commands, string.format("set %s=group", prefix))
      if group.name then
        table.insert(commands, string.format("set %s.name=%s", prefix, uci_quote(group.name)))
      end
      if group.dns_profile then
        table.insert(commands, string.format("set %s.dns_profile=%s", prefix, uci_quote(group.dns_profile)))
      end
      if group.quota_daily_min then
        table.insert(commands, string.format("set %s.quota_daily_min=%s", prefix, uci_quote(group.quota_daily_min)))
      end
      if type(group.schedule) == "table" then
        for _, sched in ipairs(group.schedule) do
          if sched and sched ~= "" then
            table.insert(commands, string.format("add_list %s.schedule=%s", prefix, uci_quote(sched)))
          end
        end
      end
      local assigned = group_clients[alias]
      if type(assigned) == "table" then
        for _, mac in ipairs(assigned) do
          if mac and mac ~= "" then
            table.insert(commands, string.format("add_list %s.clients=%s", prefix, uci_quote(mac)))
          end
        end
      end
    end
  end

  for _, client in ipairs(clients) do
    if type(client) == "table" then
      local mac = client.mac and client.mac:upper() or ""
      if mac ~= "" then
        table.insert(commands, "add parental client")
        table.insert(commands, string.format("set parental.@client[-1].mac=%s", uci_quote(mac)))
        if client.name then
          table.insert(commands, string.format("set parental.@client[-1].name=%s", uci_quote(client.name)))
        end
        local galias = alias_lookup[norm_key(client.group)] or client.group
        if galias and galias ~= "" then
          table.insert(commands, string.format("set parental.@client[-1].group=%s", uci_quote(galias)))
        end
        if client.pause_until then
          table.insert(commands, string.format("set parental.@client[-1].pause_until=%s", uci_quote(client.pause_until)))
        end
      end
    end
  end

  if not run_batch(commands) then
    return false, "uci batch failed"
  end
  return true
end

local M, methods = {}, {}

methods.get_overview = {
  args = {},
  call = function()
    local data = parse_uci()
    data.discovered = gather_discovered(data.clients_list)
    return 0, data
  end
}

methods.apply = {
  args = {},
  call = function()
    return 0, { out = sh("/usr/share/parental/scripts/apply.sh reload") }
  end
}

methods.health = {
  args = {},
  call = function()
    local raw = sh("/usr/share/parental/scripts/health.sh")
    local ok, parsed = pcall(json.parse, raw)
    if ok and parsed then return 0, parsed end
    return 0, { raw = raw }
  end
}

methods.sync_adguard = {
  args = {},
  call = function()
    return 0, { out = sh("/usr/share/parental/scripts/adguard_sync.sh") }
  end
}

methods.pause_client = {
  args = { mac = "string", duration = "integer" },
  call = function(a)
    local mac = trim(a.mac or "")
    local dur = tonumber(a.duration or 0) or 0
    if mac == "" or dur <= 0 then return 1 end
    local out = sh(string.format("/usr/share/parental/scripts/pause.sh %s %d", mac, dur))
    return 0, { out = out }
  end
}

methods.block_client = {
  args = { mac = "string" },
  call = function(a)
    local mac = trim(a.mac or "")
    if mac == "" then return 1 end
    local out = sh(string.format("/usr/share/parental/scripts/block_now.sh %s", mac))
    return 0, { out = out }
  end
}

methods.unblock_client = {
  args = { mac = "string" },
  call = function(a)
    local mac = trim(a.mac or "")
    if mac == "" then return 1 end
    local out = sh(string.format("/usr/share/parental/scripts/unblock_now.sh %s", mac))
    return 0, { out = out }
  end
}

methods.debug_report = {
  args = {},
  call = function()
    local out = sh("/usr/share/parental/scripts/debug.sh")
    return 0, { report = out }
  end
}

methods.adguard_querylog = {
  args = { limit = "integer" },
  call = function(a)
    local limit = tonumber(a.limit or 200) or 200
    local url = sh("uci -q get parental.settings.adguard_url"):gsub("\n$", "")
    local tok = sh("uci -q get parental.settings.adguard_token"):gsub("\n$", "")
    if url == "" then return 0, { entries = {} } end
    local cmd = string.format("/usr/bin/curl -sS -H 'Authorization: Bearer %s' '%s/control/querylog?offset=0&limit=%d'", tok, url, limit)
    local raw = sh(cmd)
    local ok, parsed = pcall(json.parse, raw)
    if ok and parsed and parsed.data then return 0, { entries = parsed.data } end
    return 0, { raw = raw }
  end
}

methods.save_config = {
  args = { globals = "table", groups = "table", clients = "table" },
  call = function(a)
    local ok, err = save_config(a)
    if not ok then
      return 1, { error = err or "failed" }
    end
    if a.apply_now == 1 or a.apply_now == true then
      sh("/usr/share/parental/scripts/apply.sh reload")
    end
    return 0, { status = "ok" }
  end
}

function M.list(t)
  for k, _ in pairs(methods) do table.insert(t, k) end
  return 0
end

function M.call(method, args)
  local fn = methods[method]
  if not fn then return 1 end
  return fn.call(args or {})
end

return M
