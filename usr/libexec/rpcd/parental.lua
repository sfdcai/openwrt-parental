#!/usr/bin/lua
-- rpcd plugin providing parental.* methods

local uci = require "luci.model.uci".cursor()
local function sh(c) local f=io.popen(c.." 2>&1");local o=f:read("*a");f:close();return o end

local M,methods={},{}

methods.get_overview = {
  args={},
  call=function()
    local data = {
      settings = {},
      groups = {},
      clients = {}
    }
    uci:foreach("parental", "global", function(s)
      data.settings[s['.name']] = s
    end)
    uci:foreach("parental", "group", function(s)
      data.groups[s['.name']] = s
    end)
    uci:foreach("parental", "client", function(s)
      data.clients[s['.name']] = s
    end)
    return 0, data
  end
}

methods.apply={args={},call=function()return 0,{out=sh("/usr/share/parental/scripts/apply.sh reload") }end}
methods.health={args={},call=function()return 0,{out=sh("/usr/share/parental/scripts/health.sh") }end}
methods.sync_adguard={args={},call=function()return 0,{out=sh("/usr/share/parental/scripts/adguard_sync.sh") }end}

methods.pause_client = {
  args={mac="string", duration="int"},
  call=function(params)
    return 0, {out=sh("/usr/share/parental/scripts/pause.sh " .. params.mac .. " " .. params.duration) }
  end
}

methods.block_client = {
  args={mac="string"},
  call=function(params)
    return 0, {out=sh("/usr/share/parental/scripts/block_now.sh " .. params.mac) }
  end
}

methods.unblock_client = {
  args={mac="string"},
  call=function(params)
    return 0, {out=sh("/usr/share/parental/scripts/unblock_now.sh " .. params.mac) }
  end
}

function M.list(t)for k,_ in pairs(methods)do table.insert(t,k)end;return 0 end
function M.call(m,a)local f=methods[m];if not f then return 1 end;return f.call(a or {}) end
return M
