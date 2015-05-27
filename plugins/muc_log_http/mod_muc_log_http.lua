-- * Metronome IM *
--
-- This file is part of the Metronome XMPP server and is released under the
-- ISC License, please see the LICENSE file in this source package for more
-- information about copyright and licensing.
--
-- Additional Contributors: John Regan

-- Ported from prosody's http muc log module (into prosody modules).

local modulemanager = modulemanager;
if not modulemanager.is_loaded(module.host, "muc") then
	module:log("error", "mod_muc_log_http can only be loaded on a muc component!")
	return;
end

module:depends("http");

local metronome = metronome;
local hosts = metronome.hosts;
local my_host = module:get_host();
local strformat = string.format;
local section_jid = require "util.jid".section;
local split_jid = require "util.jid".split;
local config_get = require "core.configmanager".get;
local urldecode = require "net.http".urldecode;
local html_escape = require "util.auxiliary".html_escape;
local http_event = require "net.http.server".fire_server_event;
local data_load, data_getpath, data_stores, data_store_exists = 
	datamanager.load, datamanager.getpath, datamanager.stores, datamanager.store_exists;
local datastore = "muc_log";
local url_base = "muc_log";
local config = nil;
local tostring, tonumber = tostring, tonumber;
local t_insert, t_sort = table.insert, table.sort;
local os_date, os_time = os.date, os.time;
local str_format = string.format;
local io_open = io.open;
local open_pipe = io.popen;

local module_path = (module.path and module.path:gsub("[/\\][^/\\]*$", "") or (metronome.paths.plugins or "./plugins") .. "/muc_log_http");
local themes_parent = module_path .. "/themes";
local metronome_paths = metronome.paths;

local lfs = require "lfs";
local html = {};
local theme, theme_path;

local muc_rooms = hosts[my_host].muc.rooms;

-- Module Definitions

function create_doc(body, title)
	if not body then return "" end
	body = body:gsub("%%", "%%%%");
	return html.doc:gsub("###BODY_STUFF###", body)
		:gsub("<title>muc_log</title>", "<title>"..(title and html_escape(title) or "Chatroom logs").."</title>");
end

local function generate_room_list()
	local rooms = "";
	local html_rooms = html.rooms;
	for jid, room in pairs(muc_rooms) do
		local node = section_jid(jid, "node");
		if not room._data.hidden and room._data.logging and node then
			rooms = rooms .. html_rooms.bit:gsub("###ROOM###", node):gsub("###COMPONENT###", my_host);
		end
	end
	return html_rooms.body:gsub("###ROOMS_STUFF###", rooms):gsub("###COMPONENT###", my_host), "Chatroom logs for "..my_host;
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
				tmp = callback.callback(callback.path, i, month, year, callback.host, callback.room, callback.webpath);
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

local function day_callback(path, day, month, year, host, room, webpath)
	local webpath = webpath or ""
	local year = year;
	local bare_day = str_format("%.02d-%.02d-%.02d", year, month, day);
	if(data_store_exists(room, host, datastore .. "/" .. str_format("%.02d%.02d%.02d", year, month, day))) then
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
	local html_days = html.days;

	path = path:gsub("/[^/]*$", "");
	do
		local found = 0;
		for jid, room in pairs(muc_rooms) do
			local node = section_jid(jid, "node");
			if not room._data.hidden and room._data.logging and node then
				if found == 0 then
					previous_room = node;
				elseif found == 1 then
					next_room = node;
					found = -1;
				end
				if jid == bare_room_jid then
					found = 1;
				end

				rooms = rooms .. html_days.rooms.bit:gsub("###ROOM###", node);
			end
		end

		room = muc_rooms[bare_room_jid];
		if room._data.hidden or not room._data.logging then
			room = nil;
		end
	end
	if room then
		local already_done_years = {};
		topic = room._data.subject or "(no subject)";
		if topic:find("%%") then topic = topic:gsub("%%", "%%%%") end
		if topic:len() > 135 then
			topic = topic:sub(1, topic:find(" ", 120)) .. " ...";
		end

		local stores = {};
		for store in data_stores(node, host, "keyval", datastore) do t_insert(stores, store); end
		t_sort(stores);
		
		for _, store in ipairs(stores) do
			local year, month, day = store:match("^"..datastore.."/(%d%d%d%d)(%d%d)(%d%d)");
			if year then
				to = tostring(os_date("%B %Y", os_time({ day=tonumber(day), month=tonumber(month), year=tonumber(year) })));
				if since == "" then since = to; end
				if not already_done_years[year] then
					module:log("debug", "creating overview for: %s", to);
					days = create_year(year, {callback=day_callback, path=path, host=host, room=node}) .. days;
					already_done_years[year] = true;
				end
			end
		end
	end

	tmp = html_days.body:gsub("###DAYS_STUFF###", days);
	tmp = tmp:gsub("###PREVIOUS_ROOM###", previous_room == "" and node or previous_room);
	tmp = tmp:gsub("###NEXT_ROOM###", next_room == "" and node or next_room);
	tmp = tmp:gsub("###ROOMS###", rooms);
	tmp = tmp:gsub("###ROOMTOPIC###", topic);
	tmp = tmp:gsub("###SINCE###", since);
	tmp = tmp:gsub("###TO###", to);
	return tmp:gsub("###JID###", bare_room_jid), "Chatroom logs for "..bare_room_jid;
end

local function increment_day(bare_day)
	local year, month, day = bare_day:match("^(%d%d%d%d)-(%d%d)-(%d%d)$");
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
	return strformat("%.02d-%.02d-%.02d", year, month, day);
end

local function find_next_day(bare_room_jid, bare_day)
	local node, host = split_jid(bare_room_jid);
	local day = increment_day(bare_day);
	local max_trys = 7;

	module:log("debug", day);
	while(not data_store_exists(node, host, datastore .. "/" .. day)) do
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
	local year, month, day = bare_day:match("^(%d%d%d%d)-(%d%d)-(%d%d)$");
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
	return strformat("%.02d-%.02d-%.02d", year, month, day);
end

local function find_previous_day(bare_room_jid, bare_day)
	local node, host = split_jid(bare_room_jid);
	local day = decrement_day(bare_day);
	local max_trys = 7;
	module:log("debug", day);
	while(not data_store_exists(node, host, datastore .. "/" .. day)) do
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
	if bare_day then
		local ret;
		local node, host = split_jid(bare_room_jid);
		local year, month, day = bare_day:match("^(%d%d%d%d)-(%d%d)-(%d%d)$");
		local previous_day = find_previous_day(bare_room_jid, bare_day);
		local next_day = find_next_day(bare_room_jid, bare_day);
		local temptime = {day=0, month=0, year=0};
		local path = data_getpath(node, host, datastore);
		path = path:gsub("/[^/]*$", "");
		local calendar = "";
		local html_day = html.day;

		temptime.day = tonumber(day);
		temptime.month = tonumber(month);
		temptime.year = tonumber(year);
		calendar = create_month(temptime.month, temptime.year, {callback=day_callback, path=path, host=host, room=node, webpath="../"}) or "";
		
		local get_page = open_pipe(
			module_path.."/generate_log '"..metronome_paths.source.."' "..metronome_paths.data.." "..theme_path.." "..bare_room_jid.." "..year..month..day.." "..metronome.serialization
		);
		
		ret = get_page:read("*a"); get_page:close(); get_page = nil;
		if ret ~= "\n" then
			if next_day then
				next_day = html_day.dayLink:gsub("###DAY###", next_day):gsub("###TEXT###", "&gt;")
			end
			if previous_day then
				previous_day = html_day.dayLink:gsub("###DAY###", previous_day):gsub("###TEXT###", "&lt;");
			end
			local subject = room_subject:gsub("%%", "%%%%");
			subject = subject:gsub("\n", "<br />");
			ret = ret:gsub("%%", "%%%%");
			tmp = html_day.body:gsub("###DAY_STUFF###", ret):gsub("###JID###", bare_room_jid);
			tmp = tmp:gsub("###CALENDAR###", calendar);
			tmp = tmp:gsub("###DATE###", tostring(os_date("%A, %B %d, %Y", os_time(temptime))));
			tmp = tmp:gsub("###TITLE_STUFF###", subject);
			tmp = tmp:gsub("###NEXT_LINK###", next_day or "");
			tmp = tmp:gsub("###PREVIOUS_LINK###", previous_day or "");

			return tmp, "Chatroom logs for "..bare_room_jid.." ("..tostring(os_date("%A, %B %d, %Y", os_time(temptime)))..")";
		else
			ret = "";
		end
	end
end

local function handle_error(code, err) return http_event("http-error", { code = code, message = err }); end
function handle_request(event)
	local response = event.response;
	local request = event.request;
	local room;

	local request_path = request.url.path;
	if not request_path:match(".*/$") then
		response.status_code = 301;
		response.headers = { ["Location"] = request_path .. "/" };
		return response:send();
	end
	
	local node, day, more = request_path:match("^/"..url_base.."/+([^/]*)/*([^/]*)/*(.*)$");
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
	
	if node then room = muc_rooms[node.."@"..my_host]; end
	if node and not room then
		response.status_code = 404;
		return response:send(handle_error(response.status_code, "Room doesn't exist."));
	end
	if room and (room._data.hidden or not room._data.logging) then
		response.status_code = 404;
		return response:send(handle_error(response.status_code, "There're no logs for this room."));
	end

	if not node then -- room list for component
		return response:send(create_doc(generate_room_list())); 
	elseif not day then -- room's listing
		return response:send(create_doc(generate_day_room_content(node.."@"..my_host)));
	else
		if not day:match("^(%d%d%d%d)-(%d%d)-(%d%d)$") then
			local y,m,d = day:match("^(%d%d%d%d)(%d%d)(%d%d)$");
			if not y then
				response.status_code = 404;
				return response:send(handle_error(response.status_code, "No entries, or invalid year"));
			end
			response.status_code = 301;
			response.headers = { ["Location"] = request_path:match("^/"..url_base.."/+[^/]*").."/"..y.."-"..m.."-"..d.."/" };
			return response:send();
		end

		local body = create_doc(parse_day(node.."@"..my_host, room._data.subject or "", day));
		if body == "" then
			response.status_code = 404;
			return response:send(handle_error(response.status_code, "Specified entry doesn't exist."));
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
	if config.url_base and type(config.url_base) == "string" then url_base = config.url_base; end

	theme = config.theme or "metronome";
	theme_path = themes_parent .. "/" .. tostring(theme);
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
