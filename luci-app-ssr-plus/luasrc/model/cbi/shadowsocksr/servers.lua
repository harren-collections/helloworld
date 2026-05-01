-- Licensed to the public under the GNU General Public License v3.
require "luci.http"
require "luci.sys"
require "nixio.fs"
require "luci.dispatcher"
require "luci.model.uci"
local json = require "luci.jsonc"
local cbi = require "luci.cbi"
local uci = require "luci.model.uci".cursor()
local URL = require "url"

local m, s, o, node
local server_count = 0
local server_cache = {}
local detect_cache = {}

local function clash_host_port(clash_url)
	if not clash_url or clash_url == "" then
		return nil, nil
	end
	local ok, parsed = pcall(URL.parse, clash_url)
	if not ok or not parsed then
		return nil, nil
	end
	local host = parsed.host
	local port = parsed.port
	if not port or port == "" then
		port = (parsed.scheme == "http") and "80" or "443"
	end
	return host, port
end

uci:foreach("shadowsocksr", "servers", function(s)
	server_count = server_count + 1
	server_cache[s[".name"]] = {
		type = s.type,
		v2ray_protocol = s.v2ray_protocol,
		alias = s.alias,
		server_port = s.server_port,
		server = s.server,
		transport = s.transport,
		ws_path = s.ws_path,
		tls = s.tls,
		clash_url = s.clash_url
	}
end)

local function get_server(section)
	return server_cache[section] or {}
end

do
	local raw = nixio.fs.readfile("/tmp/ssrplus_server_detect.json")
	if raw and raw ~= "" then
		local parsed = json.parse(raw)
		if type(parsed) == "table" then
			detect_cache = parsed
		end
	end
end

m = Map("shadowsocksr", translate("Servers subscription and manage"))

-- Server Subscribe
s = m:section(TypedSection, "server_subscribe")
s.anonymous = true

o = s:option(Flag, "auto_update", translate("Auto Update"))
o.rmempty = false
o.description = translate("Auto Update Server subscription, GFW list and CHN route")

o = s:option(ListValue, "auto_update_week_time", translate("Update cycle (Day/Week)"))
o:value('*', translate("Every Day"))
o:value("1", translate("Every Monday"))
o:value("2", translate("Every Tuesday"))
o:value("3", translate("Every Wednesday"))
o:value("4", translate("Every Thursday"))
o:value("5", translate("Every Friday"))
o:value("6", translate("Every Saturday"))
o:value("0", translate("Every Sunday"))
o.default = "*"
o.rmempty = true
o:depends("auto_update", "1")

o = s:option(ListValue, "auto_update_day_time", translate("Regular update (Hour)"))
for t = 0, 23 do
	o:value(t, t .. ":00")
end
o.default = 2
o.rmempty = true
o:depends("auto_update", "1")

o = s:option(ListValue, "auto_update_min_time", translate("Regular update (Min)"))
for i = 0, 59 do
	o:value(i, i .. ":00")
end
o.default = 30
o.rmempty = true
o:depends("auto_update", "1")

o = s:option(DynamicList, "subscribe_url", translate("Subscribe URL"))
o.rmempty = true

o = s:option(Flag, "subscribe_advanced", translate("Subscribe Advanced Settings"))
o.rmempty = false
o.default = "0"

o = s:option(Value, "filter_words", translate("Subscribe Filter Words"))
o.rmempty = true
o.description = translate("Filter Words splited by /")
o:depends("subscribe_advanced", "1")

o = s:option(Value, "save_words", translate("Subscribe Save Words"))
o.rmempty = true
o.description = translate("Save Words splited by /")
o:depends("subscribe_advanced", "1")

o = s:option(Button, "update_Sub", translate("Update Subscribe List"))
o.inputstyle = "reload"
o.description = translate("Update subscribe url list first")
o.write = function()
	uci:commit("shadowsocksr")
	luci.sys.exec("rm -rf /tmp/sub_md5_*")
	luci.http.redirect(luci.dispatcher.build_url("admin", "services", "shadowsocksr", "servers"))
end

o = s:option(Flag, "allow_insecure", translate("Allow subscribe Insecure nodes By default"))
o.rmempty = false
o.description = translate("Subscribe nodes allows insecure connection as TLS client (insecure)")
o.default = "0"
o:depends("subscribe_advanced", "1")

o = s:option(Flag, "switch", translate("Subscribe Default Auto-Switch"))
o.rmempty = false
o.description = translate("Subscribe new add server default Auto-Switch on")
o.default = "1"
o:depends("subscribe_advanced", "1")

o = s:option(Flag, "proxy", translate("Through proxy update"))
o.rmempty = false
o.description = translate("Through proxy update list, Not Recommended ")
o:depends("subscribe_advanced", "1")

o = s:option(Button, "subscribe", translate("Update All Subscribe Servers"))
o.rawhtml = true
o.template = "shadowsocksr/subscribe"

o = s:option(Button, "delete", translate("Delete All Subscribe Servers"))
o.inputstyle = "reset"
o.description = string.format(translate("Server Count") .. ": %d", server_count)
o.write = function()
	uci:delete_all("shadowsocksr", "servers", function(s)
		if s.hashkey or s.isSubscribe then
			return true
		else
			return false
		end
	end)
	uci:save("shadowsocksr")
	uci:commit("shadowsocksr")
	for file in nixio.fs.glob("/tmp/sub_md5_*") do
		nixio.fs.remove(file)
	end
	luci.http.redirect(luci.dispatcher.build_url("admin", "services", "shadowsocksr", "delete"))
	return
end

o = s:option(Value, "url_test_url", translate("URL Test Address"))
o:value("https://cp.cloudflare.com/", "Cloudflare")
o:value("https://www.gstatic.com/generate_204", "Gstatic")
o:value("https://www.google.com/generate_204", "Google")
o:value("https://www.youtube.com/generate_204", "YouTube")
o:value("https://connect.rom.miui.com/generate_204", "MIUI (CN)")
o:value("https://connectivitycheck.platform.hicloud.com/generate_204", "HiCloud (CN)")
o.default = o.keylist[3]


o = s:option(Value, "user_agent", translate("User-Agent"))
o.default = "v2rayN/9.99"
o:value("curl", "Curl")
o:value("Mozilla/5.0 (X11; Linux x86_64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/122.0.0.0 Safari/537.36 Edg/122.0.0.0", "Edge for Linux")
o:value("Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/122.0.0.0 Safari/537.36 Edg/122.0.0.0", "Edge for Windows")
o:value("v2rayN/9.99", "v2rayN")
o:depends("subscribe_advanced", "1")

s:append(cbi.Template("shadowsocksr/subscribe_schedule_compact"))

-- [[ Servers Manage ]]--
s = m:section(TypedSection, "servers")
s.anonymous = true
s.addremove = true
s.description = translate("Node order can be dragged with the mouse and takes effect immediately. The automatic switch order of server nodes is consistent with the node order in the table.")
s.template = "cbi/tblsection"
s:append(cbi.Template("shadowsocksr/optimize_cbi_ui"))
s.sortable = true
s.extedit = luci.dispatcher.build_url("admin", "services", "shadowsocksr", "servers", "%s")
function s.create(...)
	local sid = TypedSection.create(...)
	if sid then
		luci.http.redirect(s.extedit % sid)
		return
	end
end

o = s:option(DummyValue, "type", translate("Type"))
function o.cfgvalue(self, section)
	local cfg = get_server(section)
	return cfg.v2ray_protocol or cfg.type or translate("None")
end

o = s:option(DummyValue, "alias", translate("Alias"))
function o.cfgvalue(self, section)
	return get_server(section).alias or translate("None")
end

o = s:option(DummyValue, "server_port", translate("Socket Connected"))
o.template = "shadowsocksr/socket"
o.width = "10%"
function o.cfgvalue(self, section)
	self.detect_cache = detect_cache[section]
	local cfg = get_server(section)
	local stype = cfg.type
	if stype == "clash" then
		return "N/A"
	end
	return cfg.server_port
end
o.render = function(self, section, scope)
	local cfg = get_server(section)
	local stype = cfg.type
	self.type = stype or ""
	self.proto = cfg.v2ray_protocol or ""
	if stype == "clash" then
		self.transport = ""
		self.ws_path = ""
		self.tls = ""
	else
		self.transport = cfg.transport or ""
		if self.transport == 'ws' then
			self.ws_path = cfg.ws_path or ""
			self.tls = cfg.tls or ""
		else
			self.ws_path = ""
			self.tls = ""
		end
	end
	DummyValue.render(self, section, scope)
end

o = s:option(DummyValue, "server", translate("Ping Latency"))
o.template = "shadowsocksr/ping"
o.width = "10%"
function o.cfgvalue(self, section)
	self.detect_cache = detect_cache[section]
	return get_server(section).server or "N/A"
end

local global_server = uci:get_first('shadowsocksr', 'global', 'global_server') 

node = s:option(Button, "apply_node", translate("Apply"))
node.inputstyle = "apply"
node.render = function(self, section, scope)
	if section == global_server then
		self.title = translate("Reapply")
	else
		self.title = translate("Apply")
	end
	Button.render(self, section, scope)
end
node.write = function(self, section)
	uci:set("shadowsocksr", '@global[0]', 'global_server', section)
	uci:save("shadowsocksr")
	uci:commit("shadowsocksr")
	luci.http.redirect(luci.dispatcher.build_url("admin", "services", "shadowsocksr", "restart"))
end

o = s:option(Flag, "switch_enable", translate("Auto Switch"))
o.rmempty = false
function o.cfgvalue(...)
	return Value.cfgvalue(...) or 1
end

m:append(cbi.Template("shadowsocksr/server_list"))

return m
