-- * Metronome IM *
--
-- This file is part of the Metronome XMPP server and is released under the
-- ISC License, please see the LICENSE file in this source package for more
-- information about copyright and licensing.

-- Ported from prosody's http muc log module (into prosody modules).

module:depends("http");

local metronome = metronome;
local hosts = metronome.hosts;
local my_host = module:get_host();
local strchar = string.char;
local strformat = string.format;
local split_jid = require "util.jid".split;
local config_get = require "core.configmanager".get;
local urldecode = require "net.http".urldecode;
local http_event = require "net.http.server".fire_server_event;
local data_load, data_getpath = datamanager.load, datamanager.getpath;
local datastore = "muc_log";
local url_base = "muc_log";
local config = nil;
local table, tostring, tonumber = table, tostring, tonumber;
local os_date, os_time = os.date, os.time;
local str_format = string.format;
local io_open = io.open;
local themes_parent = (module.path and module.path:gsub("[/\\][^/\\]*$", "")  or (metronome.paths.plugins or "./plugins") .. "/muc_log_http") .. "/themes";

local lom = require "lxp.lom";
local lfs = require "lfs";
local html = {};
local theme;

-- Helper Functions

local p_encode = datamanager.path_encode;
local function store_exists(node, host, today)
	if lfs.attributes(data_getpath(node, host, datastore .. "/" .. today), "mode") then return true; else return false; end
end

-- Module Definitions

local function html_escape(t)
	if t then
		t = t:gsub("<", "&lt;");
		t = t:gsub(">", "&gt;");
		t = t:gsub("(http://[%a%d@%.:/&%?=%-_#%%~]+)", function(h)
			h = urlunescape(h)
			return "<a href='" .. h .. "'>" .. h .. "</a>";
		end);
		t = t:gsub("\n", "<br />");
		t = t:gsub("%%", "%%%%");
	else
		t = "";
	end
	return t;
end

function create_doc(body, title)
	if not body then return "" end
	body = body:gsub("%%", "%%%%");
	return html.doc:gsub("###BODY_STUFF###", body)
		:gsub("<title>muc_log</title>", "<title>"..(title and html_escape(title) or "Chatroom logs").."</title>");
end

function urlunescape (url)
	url = url:gsub("+", " ")
	url = url:gsub("%%(%x%x)", function(h) return strchar(tonumber(h,16)) end)
	url = url:gsub("\r\n", "\n")
	return url
end

local function generate_room_list(component)
	local rooms = "";
	local component_host = hosts[component];
	if component_host and component_host.muc ~= nil then
		for jid, room in pairs(component_host.muc.rooms) do
			local node = split_jid(jid);
			if not room._data.hidden and room._data.logging and node then
				rooms = rooms .. html.rooms.bit:gsub("###ROOM###", node):gsub("###COMPONENT###", component);
			end
		end
		return html.rooms.body:gsub("###ROOMS_STUFF###", rooms):gsub("###COMPONENT###", component), "Chatroom logs for "..component;
	end
end

-- Calendar stuff
local function get_days_for_month(month, year)
	if month == 2 then
		local is_leap_year = (year % 4 == 0 and year % 100 ~= 0) or year % 400 == 0;
		return is_leap_year and 29 or 28;
	elseif (month < 8 and month%2 == 1) or (month >= 8 and month%2 == 0) then
		return 31;
	end
	return 30;
end

local function create_month(month, year, callback)
	local html_str = html.month.header;
	local days = get_days_for_month(month, year);
	local time = os_time{year=year, month=month, day=1};
	local dow = tostring(os_date("%a", time))
	local title = tostring(os_date("%B", time));
	local week_days = {"Mon", "Tue", "Wed", "Thu", "Fri", "Sat", "Sun"};
	local week_day = 0;
	local weeks = 1;
	local _available_for_one_day = false;

	local week_days_html = "";
	for _, tmp in ipairs(week_days) do
		week_days_html = week_days_html .. html.month.weekDay:gsub("###DAY###", tmp) .. "\n";
	end

	html_str = html_str:gsub("###TITLE###", title):gsub("###WEEKDAYS###", week_days_html);

	for i = 1, 31 do
		week_day = week_day + 1;
		if week_day == 1 then html_str = html_str .. "<tr>\n"; end
		if i == 1 then
			for _, tmp in ipairs(week_days) do
				if dow ~= tmp then
					html_str = html_str .. html.month.emptyDay .. "\n";
					week_day = week_day + 1;
				else
					break;
				end
			end
		end
		if i < days + 1 then
			local tmp = tostring(i);
			if callback and callback.callback then
				tmp = callback.callback(callback.path, i, month, year, callback.room, callback.webpath);
			end
			if tmp == nil then
				tmp = tostring(i);
			else
				_available_for_one_day = true;
			end
			html_str = html_str .. html.month.day:gsub("###DAY###", tmp) .. "\n";
		end

		if i >= days then
			break;
		end

		if week_day == 7 then
			week_day = 0;
			weeks = weeks + 1;
			html_str = html_str .. "</tr>\n";
		end
	end

	if week_day + 1 < 8 or weeks < 6 then
		week_day = week_day + 1;
		if week_day > 7 then
			week_day = 1;
		end
		if week_day == 1 then
			weeks = weeks + 1;
		end
		for y = weeks, 6 do
			if week_day == 1 then
				html_str = html_str .. "<tr>\n";
			end
			for i = week_day, 7 do
				html_str = html_str .. html.month.emptyDay .. "\n";
			end
			week_day = 1
			html_str = html_str .. "</tr>\n";
		end
	end
	html_str = html_str .. html.month.footer;
	if _available_for_one_day then
		return html_str;
	end
end

local function create_year(year, callback)
	local year = year;
	local tmp;
	if tonumber(year) <= 99 then
		year = year + 2000;
	end
	local html_str = "";
	for i=1, 12 do
		tmp = create_month(i, year, callback);
		if tmp then
			html_str = html_str .. "<div style='float: left; padding: 5px;'>\n" .. tmp .. "</div>\n";
		end
	end
	if html_str ~= "" then
		return "<div name='yearDiv' style='padding: 40px; text-align: center;'>" .. html.year.title:gsub("###YEAR###", tostring(year)) .. html_str .. "</div><br style='clear:both;'/> \n";
	end
	return "";
end

local function day_callback(path, day, month, year, room, webpath)
	local webpath = webpath or ""
	local year = year;
	if year > 2000 then
		year = year - 2000;
	end
	local bare_day = str_format("20%.02d-%.02d-%.02d", year, month, day);
	room = p_encode(room);
	local attributes, err = lfs.attributes(path.."/"..str_format("%.02d%.02d%.02d", year, month, day).."/"..room..".dat");
	if attributes ~= nil and attributes.mode == "file" then
		local s = html.days.bit;
		s = s:gsub("###BARE_DAY###", webpath .. bare_day);
		s = s:gsub("###DAY###", day);
		return s;
	end
	return;
end

local function generate_day_room_content(bare_room_jid)
	local days = "";
	local days_array = {};
	local tmp;
	local node, host = split_jid(bare_room_jid);
	local path = data_getpath(node, host, datastore);
	local room = nil;
	local next_room = "";
	local previous_room = "";
	local rooms = "";
	local attributes = nil;
	local since = "";
	local to = "";
	local topic = "";
	local component = hosts[host];

	if not(component and component.muc and component.muc.rooms[bare_room_jid]) then
		return;
	end

	path = path:gsub("/[^/]*$", "");
	attributes = lfs.attributes(path);
	do
		local found = 0;
		for jid, room in pairs(component.muc.rooms) do
			local node = split_jid(jid)
			if not room._data.hidden and room._data.logging and node then
				if found == 0 then
					previous_room = node
				elseif found == 1 then
					next_room = node
					found = -1
				end
				if jid == bare_room_jid then
					found = 1
				end

				rooms = rooms .. html.days.rooms.bit:gsub("###ROOM###", node);
			end
		end

		room = component.muc.rooms[bare_room_jid];
		if room._data.hidden or not room._data.logging then
			room = nil;
		end
	end
	if attributes and room then
		local already_done_years = {};
		topic = room._data.subject or "(no subject)"
		if topic:len() > 135 then
			topic = topic:sub(1, topic:find(" ", 120)) .. " ..."
		end
		local folders = {};
		for folder in lfs.dir(path) do table.insert(folders, folder); end
		table.sort(folders);
		for _, folder in ipairs(folders) do
			local year, month, day = folder:match("^(%d%d)(%d%d)(%d%d)");
			if year then
				to = tostring(os_date("%B %Y", os_time({ day=tonumber(day), month=tonumber(month), year=2000+tonumber(year) })));
				if since == "" then since = to; end
				if not already_done_years[year] then
					module:log("debug", "creating overview for: %s", to);
					days = create_year(year, {callback=day_callback, path=path, room=node}) .. days;
					already_done_years[year] = true;
				end
			end
		end
	end

	tmp = html.days.body:gsub("###DAYS_STUFF###", days);
	tmp = tmp:gsub("###PREVIOUS_ROOM###", previous_room == "" and node or previous_room);
	tmp = tmp:gsub("###NEXT_ROOM###", next_room == "" and node or next_room);
	tmp = tmp:gsub("###ROOMS###", rooms);
	tmp = tmp:gsub("###ROOMTOPIC###", topic);
	tmp = tmp:gsub("###SINCE###", since);
	tmp = tmp:gsub("###TO###", to);
	return tmp:gsub("###JID###", bare_room_jid), "Chatroom logs for "..bare_room_jid;
end

local function parse_iq(stanza, time, nick)
	local text = nil;
	local victim = nil;
	if(stanza.attr.type == "set") then
		for _,tag in ipairs(stanza) do
			if tag.tag == "query" then
				for _,item in ipairs(tag) do
					if item.tag == "item" and item.attr.nick ~= nil and item.attr.role == 'none' then
						victim = item.attr.nick;
						for _,reason in ipairs(item) do
							if reason.tag == "reason" then
								text = reason[1];
								break;
							end
						end
						break;
					end
				end
				break;
			end
		end
		if victim then
			if text then
				text = html.day.reason:gsub("###REASON###", html_escape(text));
			else
				text = "";
			end
			return html.day.kick:gsub("###TIME_STUFF###", time):gsub("###VICTIM###", victim):gsub("###REASON_STUFF###", text);
		end
	end
	return;
end

local function parse_presence(stanza, time, nick)
	local ret = "";
	local show_join = "block"

	if config and not config.show_join then
		show_join = "none";
	end

	if stanza.attr.type == nil then
		local show_status = "block"
		if config and not config.show_status then
			show_status = "none";
		end
		local show, status = nil, "";
		local already_joined = false;
		for _, tag in ipairs(stanza) do
			if tag.tag == "alreadyJoined" then
				already_joined = true;
			elseif tag.tag == "show" then
				show = tag[1];
			elseif tag.tag == "status" and tag[1] ~= nil then
				status = tag[1];
			end
		end
		if already_joined == true then
			if show == nil then
				show = "online";
			end
			ret = html.day.presence.statusChange:gsub("###TIME_STUFF###", time);
			if status ~= "" then
				status = html.day.presence.statusText:gsub("###STATUS###", html_escape(status));
			end
			ret = ret:gsub("###SHOW###", show):gsub("###NICK###", nick):gsub("###SHOWHIDE###", show_status):gsub("###STATUS_STUFF###", status);
		else
			ret = html.day.presence.join:gsub("###TIME_STUFF###", time):gsub("###SHOWHIDE###", show_join):gsub("###NICK###", nick);
		end
	elseif stanza.attr.type == "unavailable" then

		ret = html.day.presence.leave:gsub("###TIME_STUFF###", time):gsub("###SHOWHIDE###", show_join):gsub("###NICK###", nick);
	end
	return ret;
end

local function parse_message(stanza, time, nick)
	local body, title, ret = nil, nil, "";

	for _,tag in ipairs(stanza) do
		if tag.tag == "body" then
			body = tag[1];
			if nick then
				break;
			end
		elseif tag.tag == "nick" and nick == nil then
			nick = html_escape(tag[1]);
			if body or title then
				break;
			end
		elseif tag.tag == "subject" then
			title = tag[1];
			if nick then
				break;
			end
		end
	end
	if nick and body then
		body = html_escape(body);
		local me = body:find("^/me");
		local template = "";
		if not me then
			template = html.day.message;
		else
			template = html.day.messageMe;
			body = body:gsub("^/me ", "");
		end
		ret = template:gsub("###TIME_STUFF###", time):gsub("###NICK###", nick):gsub("###MSG###", body);
	elseif nick and title then
		title = html_escape(title);
		ret = html.day.titleChange:gsub("###TIME_STUFF###", time):gsub("###NICK###", nick):gsub("###TITLE###", title);
	end
	return ret;
end

local function increment_day(bare_day)
	local year, month, day = bare_day:match("^20(%d%d)-(%d%d)-(%d%d)$");
	local leapyear = false;
	module:log("debug", tostring(day).."/"..tostring(month).."/"..tostring(year))

	day = tonumber(day);
	month = tonumber(month);
	year = tonumber(year);

	if year%4 == 0 and year%100 == 0 then
		if year%400 == 0 then
			leapyear = true;
		else
			leapyear = false; -- turn of the century but not a leapyear
		end
	elseif year%4 == 0 then
		leapyear = true;
	end

	if (month == 2 and leapyear and day + 1 > 29) or
		(month == 2 and not leapyear and day + 1 > 28) or
		(month < 8 and month%2 == 1 and day + 1 > 31) or
		(month < 8 and month%2 == 0 and day + 1 > 30) or
		(month >= 8 and month%2 == 0 and day + 1 > 31) or
		(month >= 8 and month%2 == 1 and day + 1 > 30)
	then
		if month + 1 > 12 then
			year = year + 1;
			month = 1;
			day = 1;
		else
			month = month + 1;
			day = 1;
		end
	else
		day = day + 1;
	end
	return strformat("20%.02d-%.02d-%.02d", year, month, day);
end

local function find_next_day(bare_room_jid, bare_day)
	local node, host = split_jid(bare_room_jid);
	local day = increment_day(bare_day);
	local max_trys = 7;

	module:log("debug", day);
	while(not store_exists(node, host, day)) do
		max_trys = max_trys - 1;
		if max_trys == 0 then
			break;
		end
		day = increment_day(day);
	end
	if max_trys == 0 then
		return nil;
	else
		return day;
	end
end

local function decrement_day(bare_day)
	local year, month, day = bare_day:match("^20(%d%d)-(%d%d)-(%d%d)$");
	local leapyear = false;
	module:log("debug", tostring(day).."/"..tostring(month).."/"..tostring(year))

	day = tonumber(day);
	month = tonumber(month);
	year = tonumber(year);

	if year%4 == 0 and year%100 == 0 then
		if year%400 == 0 then
			leapyear = true;
		else
			leapyear = false; -- turn of the century but not a leapyear
		end
	elseif year%4 == 0 then
		leapyear = true;
	end

	if day - 1 == 0 then
		if month - 1 == 0 then
			year = year - 1;
			month = 12;
			day = 31;
		else
			month = month - 1;
			if (month == 2 and leapyear) then day = 29
			elseif (month == 2 and not leapyear) then day = 28
			elseif (month < 8 and month%2 == 1) or (month >= 8 and month%2 == 0) then day = 31
			else day = 30
			end
		end
	else
		day = day - 1;
	end
	return strformat("20%.02d-%.02d-%.02d", year, month, day);
end

local function find_previous_day(bare_room_jid, bare_day)
	local node, host = split_jid(bare_room_jid);
	local day = decrement_day(bare_day);
	local max_trys = 7;
	module:log("debug", day);
	while(not store_exists(node, host, day)) do
		max_trys = max_trys - 1;
		if max_trys == 0 then
			break;
		end
		day = decrement_day(day);
	end
	if max_trys == 0 then
		return nil;
	else
		return day;
	end
end

local function parse_day(bare_room_jid, room_subject, bare_day)
	local ret = "";
	local year;
	local month;
	local day;
	local tmp;
	local node, host = split_jid(bare_room_jid);
	local year, month, day = bare_day:match("^20(%d%d)-(%d%d)-(%d%d)$");
	local previous_day = find_previous_day(bare_room_jid, bare_day);
	local next_day = find_next_day(bare_room_jid, bare_day);
	local temptime = {day=0, month=0, year=0};
	local path = data_getpath(node, host, datastore);
	path = path:gsub("/[^/]*$", "");
	local calendar = ""

	if tonumber(year) <= 99 then
		year = year + 2000;
	end

	temptime.day = tonumber(day)
	temptime.month = tonumber(month)
	temptime.year = tonumber(year)
	calendar = create_month(temptime.month, temptime.year, {callback=day_callback, path=path, room=node, webpath="../"}) or ""

	if bare_day then
		local data = data_load(node, host, datastore .. "/" .. bare_day:match("^20(.*)"):gsub("-", ""));
		if data then
			for i=1, #data, 1 do
				local stanza = lom.parse(data[i]);
				if stanza and stanza.attr and stanza.attr.time then
					local timeStuff = html.day.time:gsub("###TIME###", stanza.attr.time):gsub("###UTC###", stanza.attr.utc or stanza.attr.time);
					if stanza[1] ~= nil then
						local nick;
						local tmp;

						-- grep nick from "from" resource
						if stanza[1].attr.from then -- presence and messages
							nick = html_escape(stanza[1].attr.from:match("/(.+)$"));
						elseif stanza[1].attr.to then -- iq
							nick = html_escape(stanza[1].attr.to:match("/(.+)$"));
						end

						if stanza[1].tag == "presence" and nick then
							tmp = parse_presence(stanza[1], timeStuff, nick);
						elseif stanza[1].tag == "message" then
							tmp = parse_message(stanza[1], timeStuff, nick);
						elseif stanza[1].tag == "iq" then
							tmp = parse_iq(stanza[1], timeStuff, nick);
						else
							module:log("info", "unknown stanza subtag in log found. room: %s; day: %s", bare_room_jid, year .. "/" .. month .. "/" .. day);
						end
						if tmp then
							ret = ret .. tmp
							tmp = nil;
						end
					end
				end
			end
		end
		if ret ~= "" then
			if next_day then
				next_day = html.day.dayLink:gsub("###DAY###", next_day):gsub("###TEXT###", "&gt;")
			end
			if previous_day then
				previous_day = html.day.dayLink:gsub("###DAY###", previous_day):gsub("###TEXT###", "&lt;");
			end
			ret = ret:gsub("%%", "%%%%");
			if config.show_presences then
				tmp = html.day.body:gsub("###DAY_STUFF###", ret):gsub("###JID###", bare_room_jid);
			else
				tmp = html.day.bodynp:gsub("###DAY_STUFF###", ret):gsub("###JID###", bare_room_jid);
			end
			tmp = tmp:gsub("###CALENDAR###", calendar);
			tmp = tmp:gsub("###DATE###", tostring(os_date("%A, %B %d, %Y", os_time(temptime))));
			tmp = tmp:gsub("###TITLE_STUFF###", html.day.title:gsub("###TITLE###", room_subject));
			tmp = tmp:gsub("###STATUS_CHECKED###", config.show_status and "checked='checked'" or "");
			tmp = tmp:gsub("###JOIN_CHECKED###", config.show_join and "checked='checked'" or "");
			tmp = tmp:gsub("###NEXT_LINK###", next_day or "");
			tmp = tmp:gsub("###PREVIOUS_LINK###", previous_day or "");

			return tmp, "Chatroom logs for "..bare_room_jid.." ("..tostring(os_date("%A, %B %d, %Y", os_time(temptime)))..")";
		end
	end
end

local function handle_error(code, err) return http_event("http-error", { code = code, message = err }); end
function handle_request(event)
	local response = event.response;
	local request = event.request;
	local room;

	local node, day, more = request.url.path:match("^/"..url_base.."/+([^/]*)/*([^/]*)/*(.*)$");
	if more ~= "" then
		response.status_code = 404;
		return response:send(handle_error(response.status_code, "Unknown URL."));
	end
	if node == "" then node = nil; end
	if day  == "" then day  = nil; end

	node = urldecode(node);

	if not html.doc then 
		response.status_code = 500;
		return response:send(handle_error(response.status_code, "Muc Theme is not loaded."));
	end

	
	if node then room = hosts[my_host].modules.muc.rooms[node.."@"..my_host]; end
	if node and not room then
		response.status_code = 404;
		return response:send(handle_error(response.status_code, "Room doesn't exist."));
	end
	if room and (room._data.hidden or not room._data.logging) then
		response.status_code = 404;
		return response:send(handle_error(response.status_code, "There're no logs for this room."));
	end


	if not node then -- room list for component
		return response:send(create_doc(generate_room_list(my_host))); 
	elseif not day then -- room's listing
		return response:send(create_doc(generate_day_room_content(node.."@"..my_host)));
	else
		if not day:match("^20(%d%d)-(%d%d)-(%d%d)$") then
			local y,m,d = day:match("^(%d%d)(%d%d)(%d%d)$");
			if not y then
				response.status_code = 404;
				return response:send(handle_error(response.status_code, "No entries for that year."));
			end
			response.status_code = 301;
			response.headers = { ["Location"] = request.url.path:match("^/"..url_base.."/+[^/]*").."/20"..y.."-"..m.."-"..d.."/" };
			return response:send();
		end

		local body = create_doc(parse_day(node.."@"..my_host, room._data.subject or "", day));
		if body == "" then
			response.status_code = 404;
			return response:send(handle_error(response.status_code, "Day entry doesn't exist."));
		end
		return response:send(body);
	end
end

local function read_file(filepath)
	local f,err = io_open(filepath, "r");
	if not f then return f,err; end
	local t = f:read("*all");
	f:close()
	return t;
end

local function load_theme(path)
	for file in lfs.dir(path) do
		if file:match("%.html$") then
			module:log("debug", "opening theme file: " .. file);
			local content,err = read_file(path .. "/" .. file);
			if not content then return content,err; end

			-- html.a.b.c = content of a_b_c.html
			local tmp = html;
			for idx in file:gmatch("([^_]*)_") do
				tmp[idx] = tmp[idx] or {};
				tmp = tmp[idx];
			end
			tmp[file:match("([^_]*)%.html$")] = content;
		end
	end
	return true;
end

function module.load()
	config = module:get_option_table("muc_log_http_config", {});
	if module:get_option_boolean("muc_log_presences", false) then config.show_presences = true end
	if config.show_status == nil then config.show_status = true; end
	if config.show_join == nil then config.show_join = true; end
	if config.url_base and type(config.url_base) == "string" then url_base = config.url_base; end

	theme = config.theme or "metronome";
	local theme_path = themes_parent .. "/" .. tostring(theme);
	local attributes, err = lfs.attributes(theme_path);
	if attributes == nil or attributes.mode ~= "directory" then
		module:log("error", "Theme folder of theme \"".. tostring(theme) .. "\" isn't existing. expected Path: " .. theme_path);
		return false;
	end

	local themeLoaded,err = load_theme(theme_path);
	if not themeLoaded then
		module:log("error", "Theme \"%s\" is missing something: %s", tostring(theme), err);
		return false;
	end

	module:provides("http", {
		default_path = url_base,
	        route = {
                	["GET /*"] = handle_request;
        	}
	});
end
