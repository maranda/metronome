-- * Metronome IM *
--
-- This file is part of the Metronome XMPP server and is released under the
-- ISC License, please see the LICENSE file in this source package for more
-- information about copyright and licensing.

local http_event = require "net.http.server".fire_server_event;
local http_request = require "net.http".request;
local pairs, next, open, os_time, random, tonumber, tostring =
	pairs, next, io.open, os.time, math.random, tonumber, tostring;
local jid_bare, jid_join, jid_section, jid_split =
	require "util.jid".bare, require "util.jid".join,
	require "util.jid".section, require "util.jid".split;
local urldecode = http.urldecode;
local is_contact_pending_out = require "util.rostermanager".is_contact_pending_out;
local is_contact_subscribed = require "util.rostermanager".is_contact_subscribed;
local generate = require "util.auxiliary".generate_secret;
local new_uuid = require "util.uuid".generate;
local st = require "util.stanza";
local timer = require "util.timer";
local user_exists = usermanager.user_exists;

module:depends("http");

disabled_list = {};
auth_list = {};
block_list = {};
allow_list = {};
challenge_list = setmetatable({}, { __mode = "v" });
count = 0;

local bare_sessions = bare_sessions;
local full_sessions = full_sessions;
local hosts = metronome.hosts;

local exceptions = module:get_option_set("spim_exceptions", {});
local secure = module:get_option_boolean("spim_secure", true);
local base_path = module:get_option_string("spim_base", "spim");
local http_host = module:get_option_string("spim_http_host");
local reset_count = module:get_option_number("spim_reset_count", 2000);
local ban_time = module:get_option_number("spim_s2s_ban_time", 3600);
if not base_path:match(".*/$") then base_path = base_path:gsub("^[/]+", "/") .. "/"; end
base_url = module:http_url(nil, base_path:gsub("[^%w][/\\]+[^/\\]*$", "/"), http_host);

local files_base = module.path:gsub("[/\\][^/\\]*$","") .. "/template/";

local valid_files = {
	["css/style.css"] = files_base.."css/style.css",
	["images/tile.png"] = files_base.."images/tile.png",
	["images/header.png"] = files_base.."images/header.png"
};
local mime_types = {
	css = "text/css",
	png = "image/png"
};

-- Utility functions

local function generate_secret(bytes)
	local secret = generate(bytes);
	if secret then
		return secret;
	else
		module:log("warn", "Failed to generate secret for SPIM token, the stanza will be allowed through");
		return nil;
	end
end

local function open_file(file)
	local f, err = open(file, "rb");
	if not f then return nil; end

	local data = f:read("*a"); f:close();
	return data;
end

local function http_error_reply(event, code, message, headers)
	local response = event.response;

	if headers then
		for header, data in pairs(headers) do response.headers[header] = data; end
	end

	response.status_code = code;
	response:send(http_event("http-error", { code = code, message = message, response = response }));

	return true;
end

local operands = { "plus", "minus", "multiplicated by" };
local function generate_challenge()
	local operand_string = operands[random(3)];
	local first, second, result = random(30), random(30);
	if operand_string == "plus" then
		result = first + second;
	elseif operand_string == "minus" then
		result = first - second;
	elseif operand_string == "multiplicated by" then
		result = first * second;
	end

	return tostring(first).." "..operand_string.." "..tostring(second), result;
end

local function r_template(event, type, jid)
	local data = open_file(files_base..type..".html");
	if data then
		event.response.headers["Content-Type"] = "application/xhtml+xml";
		data = data:gsub("%%REG%-URL", not base_path:find("^/") and "/"..base_path or base_path);
		if type == "form" then
			local challenge, result = generate_challenge();
			data = data:gsub("%%MATH%-CHALLENGE", challenge);
			challenge_list[event.request.conn:ip()] = result;
		end
		if jid then data = data:gsub("%%USER%%", jid); end
		return data;
	else return http_error_reply(event, 500, "Failed to obtain template."); end
end

local function http_file_get(event, type, path)
	if path == "" then
		return r_template(event, type);
	end		

	if valid_files[path] then
		local data = open_file(valid_files[path]);
		if data then
			event.response.headers["Content-Type"] = mime_types[path:match("%.([^%.]*)$")];
			return data;
		else
			return http_error_reply(event, 404, "Not found.");
		end
	end
end

local function send_message(origin, to, from, token)
	module:log("info", "requiring authentication for message directed to %s from %s", to, from);
	local message = st.message({ id = new_uuid(), type = "chat", from = to, to = from }, 
		"Greetings, this is the "..module.host.." server before sending a message or presence subscription to this user, "..
		"please visit "..base_url.." and input the following code in the form: "..token);
	origin.send(message);
	return true;
end

local function set_block(token, to, from)
	auth_list[token] = { user = to, from = from };
	if block_list[to] then
		block_list[to][from] = true;
	else
		block_list[to] = { [from] = true };
	end
	count = count + 1;
end

local function reset_tables()
	module:log("debug", "module reached iterations threshold, cleaning up data");
	auth_list = {};
	block_list = {};
	allow_list = {};
	count = 0;
end

-- Adhoc Handlers

module:depends("adhoc");
local adhoc_new = module:require "adhoc".new;

local function enable_spim(self, data, state)
	local bare_from = jid_bare(data.from);
	if not disabled_list[bare_from] then
		return { status = "completed", info = "SPIM protection is already enabled" };
	else
		disabled_list[bare_from] = nil;
		return { status = "completed", info = "Enabled SPIM protection for unsollicited messages from people not in your contacts" };
	end
end

local function disable_spim(self, data, state)
	local bare_from = jid_bare(data.from);
	if disabled_list[bare_from] then
		return { status = "completed", info = "SPIM protection is already disabled" };
	else
		disabled_list[bare_from] = true;
		return { status = "completed", info = "Disabled SPIM protection, you will now receive all messages from people not in your contacts" };
	end
end

local enable_spim_descriptor = adhoc_new("Enable SPIM protection", "enable_spim", enable_spim, "local_user");
local disable_spim_descriptor = adhoc_new("Disable SPIM protection", "disable_spim", disable_spim, "local_user");
module:provides("adhoc", enable_spim_descriptor);
module:provides("adhoc", disable_spim_descriptor);

-- XMPP Handlers

local function handle_incoming(event)
	local origin, stanza = event.origin, event.stanza;
		
	if origin.type == "s2sin" or origin.bidirectional then -- don't handle local traffic.
		local to, from, type, name = stanza.attr.to, stanza.attr.from, stanza.attr.type, stanza.name;

		if (name == "presence" and type ~= "subscribe") or type == "error" or type == "groupchat" then return; end
		if name == "message" and stanza:child_with_name("result") and not stanza:child_with_name("body") then
			return; -- probable MAM archive result
		end

		local from_bare, from_host, to_bare = jid_bare(from), jid_section(from, "host"), jid_bare(to);
		local user, host, resource = jid_split(to);

		if disabled_list[to_bare] then return; end
		if not jid_section(from, "node") or exceptions:contains(from_host) or module:fire_event("peer-is-subscribed", from_host) then
			return;
		end -- allow hosts, components, peers traffic and exceptions.
		if is_contact_subscribed(user, host, from_bare) or is_contact_pending_out(user, host, from_bare) then return; end
		
		local to_allow_list = allow_list[to_bare];
		if to_allow_list and to_allow_list[from_bare] then return; end
		
		if block_list[to_bare] and block_list[to_bare][from_bare] then
			module:log("info", "blocking unsolicited %s to %s from %s", name, to_bare, from_bare);
			module:fire_event("call-gate-guard", { origin = origin, from = from, reason = "SPIM", ban_time = ban_time });
			return true; 
		end

		if not resource then
			if user_exists(user, host) then
				local token = generate_secret(20);
				if not token then return; end
				set_block(token, to, from_bare);
				return send_message(origin, to, from, token);
			end
		else
			local full_session = full_sessions[to];
			if full_session then
				if full_session.directed_bare[from_bare] then return; end
				local token = generate_secret(20);
				if not token then return; end
				set_block(token, to_bare, from_bare);
				return send_message(origin, to, from, token);
			end
		end
		
		if count >= reset_count then reset_tables(); end
	end
end

local function handle_outgoing(event)
	local origin, stanza = event.origin, event.stanza;
	
	if origin.type == "c2s" and stanza.attr.type == "chat" then
		local to_bare = jid_bare(stanza.attr.to);
		local host = to_bare and jid_section(to_bare, "host");
		if not to_bare or origin.directed_bare[to_bare] or hosts[host] or exceptions:contains(host) then
			return;
		end
		
		local user, host = origin.username, origin.host;
		local from_bare = jid_join(user, host);
		local from_allow_list = allow_list[from_bare];
		
		if from_allow_list and from_allow_list[to_bare] then return; end
		
		if not is_contact_subscribed(user, host, to_bare) or not is_contact_pending_out(user, host, to_bare) then
			if not from_allow_list then allow_list[from_bare] = {}; end
			module:log("debug", "adding exception for %s to message %s, since conversation was started locally",
				to_bare, from_bare);
			allow_list[from_bare][to_bare] = true;
		end
	end
end

module:hook("pre-message/bare", handle_outgoing, 100);
module:hook("pre-message/full", handle_outgoing, 100);
module:hook("message/bare", handle_incoming, 100);
module:hook("message/full", handle_incoming, 100);
module:hook("presence/bare", handle_incoming, 100);
module:hook("resource-unbind", function(event)
	local username, host = event.session.username, event.session.host;
	local jid = username.."@"..host;
	if not bare_sessions[jid] then
		module:log("debug", "removing SPIM exemptions of %s as all resources went offline", jid);
		block_list[jid] = nil;
		allow_list[jid] = nil;
	end
end);

-- HTTP Handlers

local function handle_spim(event, path)
	local request = event.request;
	local body = request.body;
	local ip = request.conn:ip();
	
	if secure and not request.secure then return nil; end
	
	if request.method == "GET" then
		return http_file_get(event, "form", path);
	elseif request.method == "POST" then
		if path == "" then
			if not body then return http_error_reply(event, 400, "Bad Request."); end
			local spim_token, challenge = body:match("^spim_token=(.*)&math_challenge=(.*)$");
			if spim_token and challenge then
				local has_auth = auth_list[urldecode(spim_token)];
				if has_auth and challenge_list[ip] == tonumber(challenge) then
					local from, to = has_auth.from, has_auth.user;
					local bare_session = bare_sessions[to];
					if not allow_list[to] then allow_list[to] = {}; end
					allow_list[to][from] = true;
					if not bare_session then
						timer.add_task(180, function()
							allow_list[to] = nil;
						end);
					end
					if block_list[to] then block_list[to][from] = nil; end
					if not next(block_list[to]) then block_list[to] = nil; end
					auth_list[spim_token] = nil;
					has_auth = nil;
					module:log("info", "%s (%s) is now allowed to send messages to %s", from, ip, to);
					return r_template(event, "success", to);
				else
					return r_template(event, "fail");
				end
			else
				return http_error_reply(event, 400, "Invalid Request.");
			end
		end
	else
		return http_error_reply(event, 405, "Invalid method.");
	end
end

-- Set it up!

module:provides("http", {
	default_path = base_path,
	route = {
		["GET /*"] = handle_spim,
		["POST /*"] = handle_spim
	}
});

module:log("info", "SPIM blocking module accepting challenges at: <%s>", base_url);

-- Reloadability

module.save = function()
	return { disabled_list = disabled_list, auth_list = auth_list, block_list = block_list, allow_list = allow_list, count = count };
end
module.restore = function(data)
	disabled_list, auth_list, block_list, allow_list, count = 
		data.disabled_list or {}, data.auth_list or {}, data.block_list or {}, data.allow_list or {}, data.count or 0;
end
