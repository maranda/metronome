-- * Metronome IM *
--
-- This file is part of the Metronome XMPP server and is released under the
-- ISC License, please see the LICENSE file in this source package for more
-- information about copyright and licensing.

local base_url = module:get_option_string("spim_url");
if not base_url then
	module:log("error", "Please specify the SPIM Base URL into the configuration, before loading this module.");
	return;
end

local http_event = require "net.http.server".fire_server_event;
local http_request = require "net.http".request;
local pairs, next, open, os_time = pairs, next, io.open, os.time;
local jid_bare, jid_join, jid_section, jid_split =
	require "util.jid".bare, require "util.jid".join,
	require "util.jid".section, require "util.jid".split;
local urldecode = http.urldecode;
local is_contact_subscribed = require "util.rostermanager".is_contact_subscribed;
local generate = require "util.auxiliary".generate_secret;
local new_uuid = require "util.uuid".generate;
local st = require "util.stanza";
local timer = require "util.timer";
local user_exists = usermanager.user_exists;

module:depends("http");

auth_list = {};
block_list = {};
allow_list = {};
count = 0;

local bare_sessions = bare_sessions;
local full_sessions = full_sessions;
local hosts = metronome.hosts;

local secure = module:get_option_boolean("spim_secure", true);
local base_path = module:get_option_string("spim_base", "/spim/");
local reset_count = module:get_option_number("spim_reset_count", 10000);
base_url = base_url..base_path;

local files_base = module.path:gsub("/[^/]+$","").."/template/";

local valid_files = {
	["css/style.css"] = files_base.."css/style.css",
	["images/tile.png"] = files_base.."images/tile.png",
	["images/header.png"] = files_base.."images/header.png"
};

-- Utility functions

local function generate_secret(bytes)
	local secret = generate(bytes);
	if secret then
		return secret;
	else
		module:log("warn", "Failed to generate secret for SPIM token, the stanza will be allowed through.");
		return nil;
	end
end

local function open_file(file)
	local f, err = open(file, "rb");
	if not f then return nil; end

	local data = f:read("*a"); f:close();
	return data;
end

local function r_template(event, type, jid)
	local data = open_file(files_base..type..".html");
	if data then
		event.response.headers["Content-Type"] = "application/xhtml+xml";
		data = data:gsub("%%REG%-URL", base_path);
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
		if data then return data;
		else return http_error_reply(event, 404, "Not found."); end
	end
end

local function http_error_reply(event, code, message, headers)
	local response = event.response;

	if headers then
		for header, data in pairs(headers) do response.headers[header] = data; end
	end

	response.status_code = code
	response.headers["Content-Type"] = "text/html";
	response:send(http_event("http-error", { code = code, message = message }));
end

local function send_message(origin, to, from, token)
	module:log("info", "requiring authentication for message directed to %s from %s", to, from);
	local message = st.message({ id = new_uuid(), type = "chat", from = to, to = from }, 
		"Greetings, this is the "..module.host.." server before sending a message to this user, please visit "..
		base_url.." and input the following code in the form: "..token);
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

-- XMPP Handlers

local function handle_incoming(event)
	local origin, stanza = event.origin, event.stanza;
		
	if origin.type == "s2sin" or origin.bidirectional then -- don't handle local traffic.
		local to, from, type = stanza.attr.to, stanza.attr.from, stanza.attr.type;
		
		if type == "error" or type == "groupchat" then return; end
		if stanza:child_with_name("result") and	not stanza:child_with_name("body") then
			return; -- probable MAM archive result, still a hack.
		end

		local from_bare, to_bare = jid_bare(from), jid_bare(to);
		local user, host, resource = jid_split(to);

		if not jid_section(from_bare, "node") then return; end -- allow (PubSub) components.
		
		if is_contact_subscribed(user, host, from_bare) then return; end
		
		if module:fire_event("peer-is-subscribed", jid_section(from, "host")) then return; end
		
		local to_allow_list = allow_list[to_bare];
		if to_allow_list and to_allow_list[from_bare] then return; end
		
		if block_list[to_bare] and block_list[to_bare][from_bare] then
			module:log("info", "blocking unsolicited message to %s from %s", to_bare, from_bare);
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
				if full_session.joined_mucs and full_session.joined_mucs[from_bare] then return; end
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
		if not to_bare or (origin.joined_mucs and origin.joined_mucs[to_bare]) or
			hosts[jid_section(to_bare, "host")] then
			return;
		end
		
		local user, host = origin.username, origin.host;
		local from_bare = jid_join(user, host);
		local from_allow_list = allow_list[from_bare];
		
		if from_allow_list and from_allow_list[to_bare] then return; end
		
		if not is_contact_subscribed(user, host, to_bare) then
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
	
	if secure and not request.secure then return nil; end
	
	if request.method == "GET" then
		return http_file_get(event, "form", path);
	elseif request.method == "POST" then
		if path == "" then
			if not body then return http_error_reply(event, 400, "Bad Request."); end
			local spim_token = body:match("^spim_token=(.*)$");
			if spim_token then
				local has_auth = auth_list[urldecode(spim_token)];
				if has_auth then
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
					module:log("info", "%s (%s) is now allowed to send messages to %s", from, request.conn:ip(), to);
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

-- Reloadability

module.save = function() return { auth_list = auth_list, block_list = block_list, allow_list = allow_list, count = count }; end
module.restore = function(data)
	auth_list, block_list, allow_list, count = data.auth_list, data.block_list, data.allow_list, data.count;
end
