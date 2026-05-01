-- Copyright (C) 2017 yushi studio <ywb94@qq.com>
-- Licensed to the public under the GNU General Public License v3.
module("luci.controller.shadowsocksr", package.seeall)
require "nixio"
require "nixio.fs"
require "luci.util"
require "luci.template"
local json = require "luci.jsonc"
local uci = require "luci.model.uci".cursor()

local CLASH_API_PORT = "16756"
local COMPONENT_HELPER = "/usr/share/shadowsocksr/update_components.sh"
local SUPPORTED_COMPONENTS = {
	xray = true,
	mihomo = true
}

local function urlencode(str)
	if not str then return "" end
	return tostring(str):gsub("[^%w%-_%.~]", function(c)
		return string.format("%%%02X", string.byte(c))
	end)
end

local function get_clash_secret(sid)
	return sid .. "_ssrplus_clash"
end

local function get_clash_cache_file(sid)
	return "/etc/ssrplus/clash/" .. sid .. ".yaml"
end

local function clash_process_running()
	return luci.sys.call("(busybox ps -w 2>/dev/null || busybox ps) | grep ssr-retcp | grep -v grep >/dev/null") == 0
end

local function is_active_clash_node(sid)
	if not sid then return false end
	if uci:get("shadowsocksr", sid) ~= "servers" then return false end
	if uci:get("shadowsocksr", sid, "type") ~= "clash" then return false end
	if uci:get_first("shadowsocksr", "global", "global_server") ~= sid then return false end
	return clash_process_running()
end

local function resolve_active_clash_sid(sid)
	if is_active_clash_node(sid) then
		return sid
	end

	local current_sid = uci:get_first("shadowsocksr", "global", "global_server")
	if is_active_clash_node(current_sid) then
		return current_sid
	end

	return nil
end

local function clash_api_request(sid, method, path, body)
	sid = resolve_active_clash_sid(sid)
	if not sid then
		return nil
	end
	local secret = get_clash_secret(sid)
	local cmd = string.format(
		"curl -sL -m 5 --retry 1 -w '\n__CURL_STATUS__:%%{http_code}' -H %s -H %s -X %s http://127.0.0.1:%s%s %s",
		luci.util.shellquote("Content-Type: application/json"),
		luci.util.shellquote("Authorization: Bearer " .. secret),
		method,
		CLASH_API_PORT,
		path,
		body and ("-d " .. luci.util.shellquote(body)) or ""
	)
	local output = luci.sys.exec(cmd)
	if not output or output == "" then
		return nil
	end
	local body_output = output:gsub("\n__CURL_STATUS__:%d%d%d%s*$", "")
	local code = output:match("__CURL_STATUS__:(%d%d%d)")
	return {
		code = tonumber(code),
		body = body_output
	}
end

local function clash_delay_ok(sid, candidates, probe_url)
	local raw = clash_api_request(sid, "GET", "/proxies")
	local parsed = raw and json.parse(raw.body or "") or nil
	local proxies = parsed and parsed.proxies or nil
	local tried = {}

	if type(proxies) ~= "table" then
		return false
	end

	local function test_proxy(name)
		if not name or name == "" or tried[name] or not proxies[name] then
			return false
		end
		tried[name] = true
		local delay_raw = clash_api_request(
			sid,
			"GET",
			"/proxies/" .. urlencode(name) .. "/delay?timeout=5000&url=" .. urlencode(probe_url)
		)
		local delay_data = delay_raw and json.parse(delay_raw.body or "") or nil
		return delay_data and tonumber(delay_data.delay or 0) and tonumber(delay_data.delay or 0) > 0
	end

	for _, name in ipairs(candidates or {}) do
		if test_proxy(name) then
			return true
		end

		local info = proxies[name]
		if type(info) == "table" and type(info.now) == "string" and info.now ~= "" then
			if test_proxy(info.now) then
				return true
			end
		end
	end

	return false
end

local function parse_clash_groups(raw)
	local info = json.parse(raw or "")
	local proxies = info and info.proxies or nil
	local groups = {}
	if type(proxies) ~= "table" then
		return groups
	end
	for name, value in pairs(proxies) do
		if type(value) == "table" and type(value.all) == "table" and #value.all > 0 then
			groups[#groups + 1] = {
				name = name,
				type = value.type or "",
				now = value.now or "",
				all = value.all
			}
		end
	end
	table.sort(groups, function(a, b) return tostring(a.name) < tostring(b.name) end)
	return groups
end

local function parse_kv_output(raw)
	local data = {}
	for line in tostring(raw or ""):gmatch("[^\r\n]+") do
		local key, value = line:match("^([%w_]+)=(.*)$")
		if key then
			data[key] = value
		end
	end
	return data
end

local function read_component_state(component, action)
	if not SUPPORTED_COMPONENTS[component] then
		return nil, 400, "unsupported_component"
	end

	local mirror = luci.http.formvalue("mirror") or ""
	local cmd = string.format(
		"COMPONENT_MIRROR=%s /bin/sh %s %s 2>/dev/null",
		luci.util.shellquote(mirror),
		luci.util.shellquote(COMPONENT_HELPER),
		luci.util.shellquote(component .. "_" .. action)
	)
	return parse_kv_output(luci.sys.exec(cmd))
end

local function write_component_json(data)
	luci.http.prepare_content("application/json")
	luci.http.write_json({
		component = data.component or "xray",
		installed = data.installed == "1",
		current_version = data.current_version or "",
		latest_version = data.latest_version or "",
		previous_version = data.previous_version or "",
		arch = data.arch or "",
		asset = data.asset or "",
		can_upgrade = data.can_upgrade == "1",
		success = data.success == "1",
		error = data.error or "",
		message = data.message or ""
	})
end

function index()
	if not nixio.fs.access("/etc/config/shadowsocksr") then
		call("act_reset")
	end
	local page
	page = entry({"admin", "services", "shadowsocksr"}, alias("admin", "services", "shadowsocksr", "client"), _("ShadowSocksR Plus+"), 10)
	page.dependent = true
	page.acl_depends = { "luci-app-ssr-plus" }
	entry({"admin", "services", "shadowsocksr", "client"}, cbi("shadowsocksr/client"), _("SSR Client"), 10).leaf = true
	entry({"admin", "services", "shadowsocksr", "servers"}, arcombine(cbi("shadowsocksr/servers", {autoapply = true}), cbi("shadowsocksr/client-config")), _("Servers Nodes"), 20).leaf = true
	entry({"admin", "services", "shadowsocksr", "control"}, cbi("shadowsocksr/control"), _("Access Control"), 30).leaf = true
	entry({"admin", "services", "shadowsocksr", "advanced"}, cbi("shadowsocksr/advanced"), _("Advanced Settings"), 50).leaf = true
	entry({"admin", "services", "shadowsocksr", "server"}, arcombine(cbi("shadowsocksr/server"), cbi("shadowsocksr/server-config")), _("SSR Server"), 60).leaf = true
	entry({"admin", "services", "shadowsocksr", "component"}, cbi("shadowsocksr/component"), _("Component Update"), 65).leaf = true
	entry({"admin", "services", "shadowsocksr", "status"}, form("shadowsocksr/status"), _("Status"), 70).leaf = true
	entry({"admin", "services", "shadowsocksr", "check"}, call("check_status"))
	entry({"admin", "services", "shadowsocksr", "refresh"}, call("refresh_data"))
	entry({"admin", "services", "shadowsocksr", "subscribe"}, call("subscribe"))
	entry({"admin", "services", "shadowsocksr", "component_local_status"}, call("component_local_status")).leaf = true
	entry({"admin", "services", "shadowsocksr", "component_set_mirror"}, call("component_set_mirror")).leaf = true
	entry({"admin", "services", "shadowsocksr", "component_status"}, call("component_status")).leaf = true
	entry({"admin", "services", "shadowsocksr", "component_upgrade"}, call("component_upgrade")).leaf = true
	entry({"admin", "services", "shadowsocksr", "checkport"}, call("check_port"))
	entry({"admin", "services", "shadowsocksr", "log"}, form("shadowsocksr/log"), _("Log"), 80).leaf = true
	entry({"admin", "services", "shadowsocksr", "get_log"}, call("get_log")).leaf = true
	entry({"admin", "services", "shadowsocksr", "clear_log"}, call("clear_log")).leaf = true
	entry({"admin", "services", "shadowsocksr", "run"}, call("act_status"))
	entry({"admin", "services", "shadowsocksr", "ping"}, call("act_ping"))
	entry({"admin", "services", "shadowsocksr", "save_order"}, call("save_order")).leaf = true
	entry({"admin", "services", "shadowsocksr", "reset"}, call("act_reset"))
	entry({"admin", "services", "shadowsocksr", "restart"}, call("act_restart"))
	entry({"admin", "services", "shadowsocksr", "delete"}, call("act_delete"))
	entry({"admin", "services", "shadowsocksr", "clash_panel"}, call("clash_panel")).leaf = true
	entry({"admin", "services", "shadowsocksr", "clash_groups"}, call("clash_groups")).leaf = true
	entry({"admin", "services", "shadowsocksr", "clash_switch"}, call("clash_switch")).leaf = true
	entry({"admin", "services", "shadowsocksr", "clash_refresh"}, call("clash_refresh")).leaf = true
	--[[Backup]]
	entry({"admin", "services", "shadowsocksr", "backup"}, call("create_backup")).leaf = true
end

function subscribe()
	luci.sys.call("/usr/bin/lua /usr/share/shadowsocksr/subscribe.lua >>/var/log/ssrplus.log")
	luci.http.prepare_content("application/json")
	luci.http.write_json({ret = 1})
end

function save_order()
	local order = luci.http.formvalue("order") or ""
	local sids = {}

	for sid in order:gmatch("%S+") do
		if uci:get("shadowsocksr", sid) == "servers" then
			sids[#sids + 1] = sid
		end
	end

	if #sids > 0 then
		uci:reorder("shadowsocksr", sids)
		uci:commit("shadowsocksr")
	end

	luci.http.prepare_content("application/json")
	luci.http.write_json({
		ret = (#sids > 0) and 1 or 0,
		count = #sids
	})
end

function component_status()
	local component = luci.http.formvalue("component")
	local data, status, err = read_component_state(component, "info")
	if not data then
		luci.http.status(status or 500, "Bad Request")
		write_component_json({component = component, error = err or "bad_request"})
		return
	end
	write_component_json(data)
end

function component_local_status()
	local component = luci.http.formvalue("component")
	local data, status, err = read_component_state(component, "local_info")
	if not data then
		luci.http.status(status or 500, "Bad Request")
		write_component_json({component = component, error = err or "bad_request"})
		return
	end
	write_component_json(data)
end

function component_set_mirror()
	local mirror = luci.http.formvalue("mirror") or "direct"
	local allowed = {
		direct = true,
		ghproxy = true,
		ghproxy_cc = true,
		ghfast = true,
		jsdelivr = true
	}

	if not allowed[mirror] then
		mirror = "direct"
	end

	uci:set("shadowsocksr", "@global[0]", "component_mirror", mirror)
	uci:commit("shadowsocksr")

	luci.http.prepare_content("application/json")
	luci.http.write_json({ ret = 1, mirror = mirror })
end

function component_upgrade()
	local component = luci.http.formvalue("component")
	local data, status, err = read_component_state(component, "upgrade")
	if not data then
		luci.http.status(status or 500, "Bad Request")
		write_component_json({component = component, error = err or "bad_request", success = "0"})
		return
	end

	local info = read_component_state(component, "info")
	if info then
		for key, value in pairs(info) do
			if data[key] == nil or data[key] == "" then
				data[key] = value
			end
		end
		if data.success == "1" then
			data.can_upgrade = info.can_upgrade
		end
	end

	write_component_json(data)
end

function act_status()
	local e = {}
	e.running = clash_process_running()
	luci.http.prepare_content("application/json")
	luci.http.write_json(e)
end

function clash_panel()
	local sid = luci.http.formvalue("sid")
	if uci:get("shadowsocksr", sid) ~= "servers" or uci:get("shadowsocksr", sid, "type") ~= "clash" then
		luci.http.status(404, "Not Found")
		return
	end
	luci.template.render("shadowsocksr/clash_panel", {
		sid = sid,
		alias = uci:get("shadowsocksr", sid, "alias") or sid
	})
end

function clash_groups()
	local sid = luci.http.formvalue("sid")
	local groups = {}
	local active_sid = resolve_active_clash_sid(sid)
	local active = active_sid ~= nil
	if active then
		local raw = clash_api_request(active_sid, "GET", "/proxies")
		if raw then
			groups = parse_clash_groups(raw.body)
		end
	end
	luci.http.prepare_content("application/json")
	luci.http.write_json({
		active = active,
		sid = active_sid,
		groups = groups
	})
end

function clash_switch()
	local sid = luci.http.formvalue("sid")
	local group = luci.http.formvalue("group")
	local name = luci.http.formvalue("name")
	if not sid or not group or not name then
		luci.http.status(400, "Bad Request")
		return
	end
	local active_sid = resolve_active_clash_sid(sid)
	if not active_sid then
		luci.http.status(409, "Conflict")
		luci.http.prepare_content("application/json")
		luci.http.write_json({success = false, message = "inactive"})
		return
	end
	local body = string.format('{"name":"%s"}', tostring(name):gsub('"', '\\"'))
	local path = "/proxies/" .. urlencode(group)
	local ret = clash_api_request(active_sid, "PUT", path, body)
	luci.http.prepare_content("application/json")
	luci.http.write_json({success = ret ~= nil and ret.code and ret.code >= 200 and ret.code < 300, sid = active_sid})
end

function clash_refresh()
	local sid = luci.http.formvalue("sid")
	if not sid or uci:get("shadowsocksr", sid) ~= "servers" or uci:get("shadowsocksr", sid, "type") ~= "clash" then
		luci.http.status(400, "Bad Request")
		luci.http.prepare_content("application/json")
		luci.http.write_json({success = false})
		return
	end
	local cmd = string.format("/etc/init.d/shadowsocksr clash_cache %s >/dev/null 2>&1", luci.util.shellquote(sid))
	local ok = luci.sys.call(cmd) == 0
	local reapplied = false
	if ok and is_active_clash_node(sid) then
		luci.sys.call("/etc/init.d/shadowsocksr restart >/dev/null 2>&1 &")
		reapplied = true
	end
	luci.http.prepare_content("application/json")
	luci.http.write_json({
		success = ok,
		cached = nixio.fs.access(get_clash_cache_file(sid)),
		reapplied = reapplied
	})
end

function act_ping()
	local e = {}
	local domain = luci.http.formvalue("domain")
	local port = tonumber(luci.http.formvalue("port") or 0)
	local transport = (luci.http.formvalue("transport") or ""):lower()
	local wsPath = luci.http.formvalue("wsPath") or ""
	local tls = luci.http.formvalue("tls")
	local host = luci.http.formvalue("host")
	local type = (luci.http.formvalue("type") or ""):lower()
	local proto = (luci.http.formvalue("proto") or ""):lower()
	e.index = luci.http.formvalue("index")

	local is_ip = domain and domain:match("^%d+%.%d+%.%d+%.%d+$")

	-- 临时放行防火墙逻辑
	local use_nft = luci.sys.call("command -v nft >/dev/null") == 0
	local iret = false
	if domain then
		if use_nft then
			iret = luci.sys.call("nft add element inet ss_spec ss_spec_wan_ac { " .. domain .. " } 2>/dev/null") == 0
		else
			iret = luci.sys.call("ipset add ss_spec_wan_ac " .. domain .. " 2>/dev/null") == 0
		end
	end
	-- Hysteria2 节点检测
	if proto:find("hysteria2") or type:find("hysteria2") then
		local node_id = e.index    
		-- 调用Shell测试脚本
		local cmd = string.format(
			"/usr/share/shadowsocksr/hy2_test.sh url_test_hy2 %s",
			node_id
		)
		local res = luci.sys.exec(cmd) or ""    
		-- 解析结果
		local http_code, time_pre = string.match(res, "(%d+):([%d%.]+)")    
		if http_code == "200" or http_code == "204" then
			e.socket = true
			e.ping = math.floor(tonumber(time_pre or 0) * 1000)
		else
			e.socket = false
			e.ping = 0
		end
	elseif transport == "ws" then
		-- WebSocket 探测
		local result = ""
		local success = false
		-- WebSocket 探测 (适用于域名，或带 SNI 的 IP)
		if not is_ip or (host and host ~= "") then
			local resolve_arg = ""
			local final_domain = domain
			if is_ip and host and host ~= "" then
				-- IP 模式下使用 --resolve 强制指定 SNI，解决 TLS 握手失败
				resolve_arg = string.format("--resolve '%s:%d:%s' ", host, port, domain)
				final_domain = host
			end
			local prefix = (tls == '1') and "https://" or "http://"
			local address = prefix .. final_domain .. ':' .. port .. wsPath
			local cmd = string.format(
				"curl --http1.1 -m 2 -ksN -o /dev/null %s" ..
				"-w 'time_connect=%%{time_connect}\\nhttp_code=%%{http_code}' " ..
				"-H 'Connection: Upgrade' -H 'Upgrade: websocket' " ..
				"-H 'Sec-WebSocket-Key: SGVsbG8sIHdvcmxkIQ==' " ..
				"-H 'Sec-WebSocket-Version: 13' '%s'",
				resolve_arg, address
			)
			result = luci.sys.exec(cmd) or ""
			success = (string.match(result, "http_code=(%d+)") == "101")
		end
		-- 如果深度探测失败，或是不支持深测的纯 IP
		if not success then
			local socket = nixio.socket("inet", "stream")
			if socket then
				socket:setopt("socket", "rcvtimeo", 3)
				socket:setopt("socket", "sndtimeo", 3)
				success = socket:connect(domain, port)
				socket:close()
			end
			--luci.sys.exec(string.format("echo 'Node %s (ws) failed deep test, using TCP fallback' >> /tmp/ping.log", domain))
		end
		e.socket = success
		-- 解析延迟 (优先用 curl 数据，失败则回退到 tcping)
		local ping_time = tonumber(string.match(result, "time_connect=(%d+.%d%d%d)"))
		if ping_time and ping_time > 0 then
			e.ping = math.floor(ping_time * 1000)
		else
			local tcping_cmd = string.format("tcping -q -c 1 -t 1 -p %d %s 2>/dev/null | grep -o 'time=[0-9]*' | cut -d= -f2", port, domain)
			e.ping = tonumber(luci.sys.exec(tcping_cmd)) or 0
		end
	else
		-- 3. 非 WebSocket 节点的探测逻辑 (TCP / ICMP / UDP)
		local socket = nixio.socket("inet", "stream")
		if socket then
			socket:setopt("socket", "rcvtimeo", 3)
			socket:setopt("socket", "sndtimeo", 3)
			e.socket = socket:connect(domain, port)
			socket:close()
		end

		-- 延迟：tcping -> ping -> nping(udp)
		local tcping_cmd = string.format("tcping -q -c 1 -t 1 -p %d %s 2>/dev/null | grep -o 'time=[0-9]*' | cut -d= -f2", port, domain)
		e.ping = tonumber(luci.sys.exec(tcping_cmd))
		if not e.ping then
			local icmp_cmd = string.format("ping -c 1 -W 1 %s 2>/dev/null | grep -o 'time=[0-9.]*' | cut -d= -f2", domain)
			e.ping = tonumber(luci.sys.exec(icmp_cmd))
		end

		if not e.ping then
			local udp_cmd = string.format("nping --udp -c 1 -p %d %s 2>/dev/null | grep -o 'Avg rtt: [0-9.]*ms' | awk '{print $3}' | sed 's/ms//' | head -1", port, domain)
			local udp_res = luci.sys.exec(udp_cmd)
			if udp_res and udp_res ~= "" then
				local ping_num = tonumber(udp_res)
				if ping_num then e.ping = math.floor(ping_num) end
			end
		end
	end

	-- 4. 清理防火墙规则
	if iret then
		if use_nft then
			luci.sys.call("nft delete element inet ss_spec ss_spec_wan_ac { " .. domain .. " } 2>/dev/null")
		else
			luci.sys.call("ipset del ss_spec_wan_ac " .. domain .. " 2>/dev/null")
		end
	end

	luci.http.prepare_content("application/json")
	luci.http.write_json(e)
end

function check_status()
	local e = {}
	local target = luci.http.formvalue("set") or ""
	local sid = uci:get_first("shadowsocksr", "global", "global_server", "nil")
	local stype = sid ~= "nil" and (uci:get("shadowsocksr", sid, "type") or "") or ""

	if stype == "clash" and is_active_clash_node(sid) then
		if target == "baidu" then
			e.ret = luci.sys.call("curl -I -m 5 http://www.baidu.com >/dev/null 2>&1")
			luci.http.prepare_content("application/json")
			luci.http.write_json(e)
			return
		end

		if target == "google" then
			e.ret = luci.sys.call("curl -I -m 5 http://www.gstatic.com/generate_204 >/dev/null 2>&1")
			luci.http.prepare_content("application/json")
			luci.http.write_json(e)
			return
		end

		local profile_map = {
			google = {
				url = "http://www.gstatic.com/generate_204",
				candidates = { "自动选择", "故障转移", "Proxy", "GLOBAL" }
			},
			baidu = {
				url = "http://www.baidu.com",
				candidates = { "Domestic", "DIRECT", "GLOBAL" }
			}
		}
		local profile = profile_map[target] or {
			url = "http://www." .. target .. ".com",
			candidates = { "自动选择", "故障转移", "Proxy", "Domestic", "DIRECT", "GLOBAL" }
		}
		e.ret = clash_delay_ok(sid, profile.candidates, profile.url) and 0 or 1
	else
		e.ret = luci.sys.call("/usr/bin/ssr-check www." .. target .. ".com 80 3 1")
	end
	luci.http.prepare_content("application/json")
	luci.http.write_json(e)
end

function refresh_data()
	local set = luci.http.formvalue("set")
	local retstring = loadstring("return " .. luci.sys.exec("/usr/bin/lua /usr/share/shadowsocksr/update.lua " .. set))()
	luci.http.prepare_content("application/json")
	luci.http.write_json(retstring)
end

function check_port()
	local retstring = "<br /><br />"
	local s
	local server_name = ""
	local uci = require "luci.model.uci".cursor()
	local use_nft = luci.sys.call("command -v nft >/dev/null") == 0

	uci:foreach("shadowsocksr", "servers", function(s)
		if s.type == "clash" then
			retstring = retstring .. string.format("<font><b style='color:gray'>[%s] Clash panel node.</b></font><br />", s.alias or s[".name"])
			return
		end
		if s.alias then
			server_name = s.alias
		elseif s.server and s.server_port then
			server_name = s.server .. ":" .. s.server_port
		end

		-- 临时加入 set
		local iret = false
		if use_nft then
			iret = luci.sys.call("nft add element inet ss_spec ss_spec_wan_ac { " .. s.server .. " } 2>/dev/null") == 0
		else
			iret = luci.sys.call("ipset add ss_spec_wan_ac " .. s.server .. " 2>/dev/null") == 0
		end

		-- TCP 测试
		local socket = nixio.socket("inet", "stream")
		socket:setopt("socket", "rcvtimeo", 3)
		socket:setopt("socket", "sndtimeo", 3)
		local ret = socket:connect(s.server, s.server_port)
		socket:close()

		if ret then
			retstring = retstring .. string.format("<font><b style='color:green'>[%s] OK.</b></font><br />", server_name)
		else
			retstring = retstring .. string.format("<font><b style='color:red'>[%s] Error.</b></font><br />", server_name)
		end

		-- 删除临时 set
		if iret then
			if use_nft then
				luci.sys.call("nft delete element inet ss_spec ss_spec_wan_ac { " .. s.server .. " } 2>/dev/null")
			else
				luci.sys.call("ipset del ss_spec_wan_ac " .. s.server)
			end
		end
	end)

	luci.http.prepare_content("application/json")
	luci.http.write_json({ret = retstring})
end

function act_reset()
	luci.sys.call("/etc/init.d/shadowsocksr reset >/dev/null 2>&1")
	luci.http.redirect(luci.dispatcher.build_url("admin", "services", "shadowsocksr"))
end

function act_restart()
	luci.http.redirect(luci.dispatcher.build_url("admin", "services", "shadowsocksr"))
end

function act_delete()
	luci.sys.call("/etc/init.d/shadowsocksr restart &")
	luci.http.redirect(luci.dispatcher.build_url("admin", "services", "shadowsocksr", "servers"))
end

function get_log()
	luci.http.write(luci.sys.exec("[ -f '/var/log/ssrplus.log' ] && cat /var/log/ssrplus.log"))
end
	
function clear_log()
	luci.sys.call("echo '' > /var/log/ssrplus.log")
end

function create_backup()
	local backup_files = {
		"/etc/config/shadowsocksr",
		"/etc/ssrplus/*"
	}
	local date = os.date("%Y-%m-%d-%H-%M-%S")
	local tar_file = "/tmp/shadowsocksr-" .. date .. "-backup.tar.gz"
	nixio.fs.remove(tar_file)
	local cmd = "tar -czf " .. tar_file .. " " .. table.concat(backup_files, " ")
	luci.sys.call(cmd)
	luci.http.header("Content-Disposition", "attachment; filename=shadowsocksr-" .. date .. "-backup.tar.gz")
	luci.http.header("X-Backup-Filename", "shadowsocksr-" .. date .. "-backup.tar.gz")
	luci.http.prepare_content("application/octet-stream")
	luci.http.write(nixio.fs.readfile(tar_file))
	nixio.fs.remove(tar_file)
end
