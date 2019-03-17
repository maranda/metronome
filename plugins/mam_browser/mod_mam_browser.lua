-- * Metronome IM *
--
-- This file is part of the Metronome XMPP server and is released under the
-- ISC License, please see the LICENSE file in this source package for more
-- information about copyright and licensing.

module:depends("mam");

local http_event = require "net.http.server".fire_server_event;
local ipairs, pairs, open, setmetatable, tonumber, tostring =
	ipairs, pairs, io.open, setmetatable, tonumber, tostring;
local jid_join = require "util.jid".join;
local urldecode = http.urldecode;
local generate = require "util.auxiliary".generate_secret;
local test_password = require "core.usermanager".test_password;
local dt = require "util.datetime".datetime;

module:depends("http");

authenticated_tokens = {};
params_cache = setmetatable({}, { __mode = "v" });

local bare_sessions = bare_sessions;
local full_sessions = full_sessions;
local hosts = metronome.hosts;

local base_path = module:get_option_string("mam_browser_base", "mam");
local http_host = module:get_option_string("mam_browser_host");
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

local function generate_secret()
	local secret = generate(18);
	if secret then
		return secret;
	else
		module:log("warn", "Failed to generate the authentication cookie");
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

local form = {
	header = "<form action='/mam/browser' method='post' accept-charset='UTF-8' id='login'>\n",
	options_label = "    <div><label for='with_jid'>Select a recipient:</label><br /></div>\n",
	options_header = "    <div><select name='with_jid'>\n",
	options_el = "        <option value='%s'>%s</option>\n",
	options_el_selected = "        <option value='%s' selected>%s</option>\n",
	options_fin = "    </select></div>\n",
	index_label = "    <div><label for='index'>Choose index (0 for start):</label><br /></div>\n",
	index_input = "    <div><input type='number' name='index' id='index' value='%d' /></div>\n",
	search_label = "    <div><label for='search'>Search for a specific word (Lua patterns are allowed):</label><br /></div>\n",
	search_input = "    <div><input type='text' name='search' id='search' value='%s' /></div>\n",
	send_input = "    <div><br /><input type='submit' id='get' value='Retrieve messages' class='btn' /></div>\n",
	fin = "</form>\n"
};

local entry = "(%s) <strong>%s</strong>: %s<br />\n";

local function r_template(event, type, params)
	local data = open_file(files_base..type..".html");
	if data then
		event.response.headers["Content-Type"] = "text/html";
		if type == "login" then
			data = data:gsub("%%HOST", "<strong>"..module.host.."</strong>");
			data = data:gsub("%%LOGIN%-URL", not base_path:find("^/") and "/"..base_path or base_path);
		elseif type == "browser" then
			local logs_amount = #params.logs;
			data = data:gsub("%%CAPTION", logs_amount > 0 and 
				"Please select the conversation recipient and the eventual message index" or
				"Archive is empty"
			);
			data = data:gsub("%%LOGOUT%-URL", (not base_path:find("^/") and "/"..base_path or base_path).."logout");
			if logs_amount > 0 then
				local index, last_jid, search = params.last.threshold or 0, params.last.with, params.last.search;
				if index < 0 then index = 0; end
				if search == "" then
					search = nil;
				elseif search ~= nil then
					search = search:gsub("%%", "%%%%");
				end

				local str = form.header .. form.options_label .. form.options_header;
				for jid in pairs(params.users) do
					str = str .. (params.last.with == jid and
						form.options_el_selected:format(jid, jid) or form.options_el:format(jid, jid));
				end
				str = str .. form.options_fin .. form.index_label .. form.index_input:format(index) ..
					form.search_label .. form.search_input:format(search or "") .. form.send_input .. form.fin;
				data = data:gsub("%%FORM", str);

				if not last_jid then
					data = data:gsub("%%FL", ""); data = data:gsub("%%ENTRIES", "");
				else
					local count, entries, last_body, last_to, trunked = 0, "";
					for i, _entry in ipairs(params.logs) do
						local negate;
						if not _entry.body or (search and not _entry.body:find(search)) then
							negate = true;
						end
						if not negate and (_entry.to == last_jid or _entry.from == last_jid) then
							count = count + 1;
							if not trunked and count - index >= 301 then trunked = count - 1; end
							if not trunked and count >= index then
								entries = entries .. entry:format(dt(_entry.timestamp), 
									(last_body == _entry.body and last_to ~= _entry.to) and _entry.from.." (to ".._entry.to..")" or _entry.from,
									_entry.body
								);
								last_body, last_to = _entry.body, _entry.to;
							end
						end
					end
					entries = entries:gsub("%%", "%%%%");
					data = data:gsub("%%FL", "Returning archive entries from " ..
						(index == 0 and "the beginning" or "message number "..tostring(index))
						.. (not trunked and "" or " to message number "..tostring(trunked))
						.. " (" .. tostring(count) .. " total messages)."
					);
					data = data:gsub("%%ENTRIES", entries);
				end
			end
		end
		return data;
	else return http_error_reply(event, 500, "Failed to obtain template."); end
end

local function http_file_get(event, path)
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

local function redirect_to(event, path)
	event.response.headers["Location"] = "/" .. base_path .. (path or "");
	return 301;
end

local function initialize_params_cache(user)
	local jid = jid_join(user, module.host);
	local archive = module:fire_event("mam-get-store", user);
	local params = { users = {}, logs = archive.logs, last = {} };
	for i, entry in ipairs(archive.logs) do
		if entry.bare_from ~= jid and not params.users[entry.from] then params.users[entry.from] = true; end
	end
	params_cache[user] = params;
	return params;
end

-- HTTP Handlers

local function handle_request(event, path)
	local request, response = event.request, event.response;
	local body = request.body;
	local ip = request.conn:ip();
	
	if not request.secure and (path == "" or path == "browser") then
		return r_template(event, "unsecure");
	end

	local cookie, token = request.headers.cookie;
	if cookie then token = cookie:match("^MAM_SESSID=([%w/%+]+[^;])"); end
	
	if request.method == "GET" then
		if path == "" then -- login
			return r_template(event, "login");
		elseif path == "logout" then -- logout
			if token then
				authenticated_tokens[token] = nil;
				response.headers["Set-Cookie"] = "MAM_SESSID=";
			end
			return redirect_to(event);
		elseif path == "browser" then -- browser
			if authenticated_tokens[token] then
				local username = authenticated_tokens[token];
				local params = params_cache[username] or initialize_params_cache(username);
				return r_template(event, "browser", params);
			else
				return redirect_to(event);
			end
		else
			return http_file_get(event, path);
		end
	elseif request.method == "POST" then
		if path == "" then
			if not body then return http_error_reply(event, 400, "Bad Request."); end
			local username, password = body:match("^username=(.*)&password=(.*)$");
			if username and password then
				username, password = urldecode(username), urldecode(password);
				if test_password(username, module.host, password) then
					local token = generate_secret();
					if token then
						response.headers["Set-Cookie"] =
							"MAM_SESSID="..token.."; Path=/"..base_path.."browser; Max-Age=600; SameSite=Strict; Secure; HttpOnly"
						authenticated_tokens[token] = username;
						module:add_timer(600, function() authenticated_tokens[token] = nil; end);
						return redirect_to(event, "browser");
					else
						return http_error_reply(event, 500, "Failed to generate cookie authentication token.");
					end
				else
					return r_template(event, "fail");
				end
			else
				return http_error_reply(event, 400, "Invalid Request.");
			end
		elseif path == "browser" then
			if not body then return http_error_reply(event, 400, "Bad Request."); end
			local username = authenticated_tokens[token];
			if username then
				local with_jid, threshold, search = body:match("^with_jid=(.*)&index=(.*)&search=(.*)$");
				with_jid, threshold, search = urldecode(with_jid), urldecode(threshold), urldecode(search);
				threshold = tonumber(threshold);
				local params = params_cache[username] or initialize_params_cache(username);
				params.last.with, params.last.threshold, params.last.search = with_jid, threshold, search;
				return r_template(event, "browser", params);
			else
				return redirect_to(event);
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
		["GET /*"] = handle_request,
		["POST /*"] = handle_request
	}
});

-- Reloadability

module.save = function()
	return { authenticated_tokens = authenticated_tokens };
end
module.restore = function(data)
	authenticated_tokens = data.authenticated_tokens or {};
end
