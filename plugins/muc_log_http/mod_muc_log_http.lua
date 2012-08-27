-- Ported from prosody's http muc log module (into prosody modules).

module:depends("http");

local metronome = metronome;
local my_host = module:get_host();
local tabSort = table.sort;
local tonumber = _G.tonumber;
local tostring = _G.tostring;
local strchar = string.char;
local strformat = string.format;
local splitJid = require "util.jid".split;
local config_get = require "core.configmanager".get;
local urlencode = require "net.http".urlencode;
local urldecode = require "net.http".urldecode;
local http_event = require "net.http.server".fire_server_event;
local datamanager = require "util.datamanager";
local data_load, data_getpath = datamanager.load, datamanager.getpath;
local datastore = "muc_log";
local urlBase = "muc_log";
local config = nil;
local tostring = _G.tostring;
local tonumber = _G.tonumber;
local os_date, os_time = os.date, os.time;
local str_format = string.format;
local io_open = io.open;
local themesParent = (module.path and module.path:gsub("[/\\][^/\\]*$", "")  or (metronome.paths.plugins or "./plugins") .. "/muc_log_http") .. "/themes";

local lom = require "lxp.lom";
local lfs = require "lfs";
local html = {};
local theme;

-- encoding function
local p_encode = datamanager.path_encode;

local function checkDatastorePathExists(node, host, today, create)
	create = create or false;
	local path = data_getpath(node, host, datastore, "dat", true);
	path = path:gsub("/[^/]*$", "");

	-- check existance
	local attributes, err = lfs.attributes(path);
	if attributes == nil or attributes.mode ~= "directory" then
		module:log("warn", "muc_log folder isn't a folder: %s", path);
		return false;
	end

	attributes, err = lfs.attributes(path .. "/" .. today);
	if attributes == nil then
		if create then
			return lfs.mkdir(path .. "/" .. today);
		else
			return false;
		end
	elseif attributes.mode == "directory" then
		return true;
	end
	return false;
end

local function htmlEscape(t)
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

function createDoc(body, title)
	if not body then return "" end
	body = body:gsub("%%", "%%%%");
	return html.doc:gsub("###BODY_STUFF###", body)
		:gsub("<title>muc_log</title>", "<title>"..(title and htmlEscape(title) or "Chatroom logs").."</title>");
end

function urlunescape (escapedUrl)
	escapedUrl = escapedUrl:gsub("+", " ")
	escapedUrl = escapedUrl:gsub("%%(%x%x)", function(h) return strchar(tonumber(h,16)) end)
	escapedUrl = escapedUrl:gsub("\r\n", "\n")
	return escapedUrl
end

local function generateRoomListSiteContent(component)
	local rooms = "";
	if metronome.hosts[component] and metronome.hosts[component].muc ~= nil then
		for jid, room in pairs(metronome.hosts[component].muc.rooms) do
			local node = splitJid(jid);
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

local function createMonth(month, year, dayCallback)
	local htmlStr = html.month.header;
	local days = get_days_for_month(month, year);
	local time = os_time{year=year, month=month, day=1};
	local dow = tostring(os_date("%a", time))
	local title = tostring(os_date("%B", time));
	local weekDays = {"Mon", "Tue", "Wed", "Thu", "Fri", "Sat", "Sun"};
	local weekDay = 0;
	local weeks = 1;
	local logAvailableForMinimumOneDay = false;

	local weekDaysHtml = "";
	for _, tmp in ipairs(weekDays) do
		weekDaysHtml = weekDaysHtml .. html.month.weekDay:gsub("###DAY###", tmp) .. "\n";
	end

	htmlStr = htmlStr:gsub("###TITLE###", title):gsub("###WEEKDAYS###", weekDaysHtml);

	for i = 1, 31 do
		weekDay = weekDay + 1;
		if weekDay == 1 then htmlStr = htmlStr .. "<tr>\n"; end
		if i == 1 then
			for _, tmp in ipairs(weekDays) do
				if dow ~= tmp then
					htmlStr = htmlStr .. html.month.emptyDay .. "\n";
					weekDay = weekDay + 1;
				else
					break;
				end
			end
		end
		if i < days + 1 then
			local tmp = tostring(i);
			if dayCallback ~= nil and dayCallback.callback ~= nil then
				tmp = dayCallback.callback(dayCallback.path, i, month, year, dayCallback.room, dayCallback.webPath);
			end
			if tmp == nil then
				tmp = tostring(i);
			else
				logAvailableForMinimumOneDay = true;
			end
			htmlStr = htmlStr .. html.month.day:gsub("###DAY###", tmp) .. "\n";
		end

		if i >= days then
			break;
		end

		if weekDay == 7 then
			weekDay = 0;
			weeks = weeks + 1;
			htmlStr = htmlStr .. "</tr>\n";
		end
	end

	if weekDay + 1 < 8 or weeks < 6 then
		weekDay = weekDay + 1;
		if weekDay > 7 then
			weekDay = 1;
		end
		if weekDay == 1 then
			weeks = weeks + 1;
		end
		for y = weeks, 6 do
			if weekDay == 1 then
				htmlStr = htmlStr .. "<tr>\n";
			end
			for i = weekDay, 7 do
				htmlStr = htmlStr .. html.month.emptyDay .. "\n";
			end
			weekDay = 1
			htmlStr = htmlStr .. "</tr>\n";
		end
	end
	htmlStr = htmlStr .. html.month.footer;
	if logAvailableForMinimumOneDay then
		return htmlStr;
	end
end

local function createYear(year, dayCallback)
	local year = year;
	local tmp;
	if tonumber(year) <= 99 then
		year = year + 2000;
	end
	local htmlStr = "";
	for i=1, 12 do
		tmp = createMonth(i, year, dayCallback);
		if tmp then
			htmlStr = htmlStr .. "<div style='float: left; padding: 5px;'>\n" .. tmp .. "</div>\n";
		end
	end
	if htmlStr ~= "" then
		return "<div name='yearDiv' style='padding: 40px; text-align: center;'>" .. html.year.title:gsub("###YEAR###", tostring(year)) .. htmlStr .. "</div><br style='clear:both;'/> \n";
	end
	return "";
end

local function perDayCallback(path, day, month, year, room, webPath)
	local webPath = webPath or ""
	local year = year;
	if year > 2000 then
		year = year - 2000;
	end
	local bareDay = str_format("20%.02d-%.02d-%.02d", year, month, day);
	room = p_encode(room);
	local attributes, err = lfs.attributes(path.."/"..str_format("%.02d%.02d%.02d", year, month, day).."/"..room..".dat")
	if attributes ~= nil and attributes.mode == "file" then
		local s = html.days.bit;
		s = s:gsub("###BARE_DAY###", webPath .. bareDay);
		s = s:gsub("###DAY###", day);
		return s;
	end
	return;
end

local function generateDayListSiteContentByRoom(bareRoomJid)
	local days = "";
	local arrDays = {};
	local tmp;
	local node, host, resource = splitJid(bareRoomJid);
	local path = data_getpath(node, host, datastore);
	local room = nil;
	local nextRoom = "";
	local previousRoom = "";
	local rooms = "";
	local attributes = nil;
	local since = "";
	local to = "";
	local topic = "";

	if not(metronome.hosts[host] and metronome.hosts[host].muc and metronome.hosts[host].muc.rooms[bareRoomJid]) then
		return;
	end

	path = path:gsub("/[^/]*$", "");
	attributes = lfs.attributes(path);
	do
		local found = 0;
		for jid, room in pairs(metronome.hosts[host].muc.rooms) do
			local node = splitJid(jid)
			if not room._data.hidden and room._data.logging and node then
				if found == 0 then
					previousRoom = node
				elseif found == 1 then
					nextRoom = node
					found = -1
				end
				if jid == bareRoomJid then
					found = 1
				end

				rooms = rooms .. html.days.rooms.bit:gsub("###ROOM###", node);
			end
		end

		room = metronome.hosts[host].muc.rooms[bareRoomJid];
		if room._data.hidden or not room._data.logging then
			room = nil;
		end
	end
	if attributes ~= nil and room ~= nil then
		local alreadyDoneYears = {};
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
				if not alreadyDoneYears[year] then
					module:log("debug", "creating overview for: %s", to);
					days = createYear(year, {callback=perDayCallback, path=path, room=node}) .. days;
					alreadyDoneYears[year] = true;
				end
			end
		end
	end

	tmp = html.days.body:gsub("###DAYS_STUFF###", days);
	tmp = tmp:gsub("###PREVIOUS_ROOM###", previousRoom == "" and node or previousRoom);
	tmp = tmp:gsub("###NEXT_ROOM###", nextRoom == "" and node or nextRoom);
	tmp = tmp:gsub("###ROOMS###", rooms);
	tmp = tmp:gsub("###ROOMTOPIC###", topic);
	tmp = tmp:gsub("###SINCE###", since);
	tmp = tmp:gsub("###TO###", to);
	return tmp:gsub("###JID###", bareRoomJid), "Chatroom logs for "..bareRoomJid;
end

local function parseIqStanza(stanza, timeStuff, nick)
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
		if victim ~= nil then
			if text ~= nil then
				text = html.day.reason:gsub("###REASON###", htmlEscape(text));
			else
				text = "";
			end
			return html.day.kick:gsub("###TIME_STUFF###", timeStuff):gsub("###VICTIM###", victim):gsub("###REASON_STUFF###", text);
		end
	end
	return;
end

local function parsePresenceStanza(stanza, timeStuff, nick)
	local ret = "";
	local showJoin = "block"

	if config and not config.showJoin then
		showJoin = "none";
	end

	if stanza.attr.type == nil then
		local showStatus = "block"
		if config and not config.showStatus then
			showStatus = "none";
		end
		local show, status = nil, "";
		local alreadyJoined = false;
		for _, tag in ipairs(stanza) do
			if tag.tag == "alreadyJoined" then
				alreadyJoined = true;
			elseif tag.tag == "show" then
				show = tag[1];
			elseif tag.tag == "status" and tag[1] ~= nil then
				status = tag[1];
			end
		end
		if alreadyJoined == true then
			if show == nil then
				show = "online";
			end
			ret = html.day.presence.statusChange:gsub("###TIME_STUFF###", timeStuff);
			if status ~= "" then
				status = html.day.presence.statusText:gsub("###STATUS###", htmlEscape(status));
			end
			ret = ret:gsub("###SHOW###", show):gsub("###NICK###", nick):gsub("###SHOWHIDE###", showStatus):gsub("###STATUS_STUFF###", status);
		else
			ret = html.day.presence.join:gsub("###TIME_STUFF###", timeStuff):gsub("###SHOWHIDE###", showJoin):gsub("###NICK###", nick);
		end
	elseif stanza.attr.type ~= nil and stanza.attr.type == "unavailable" then

		ret = html.day.presence.leave:gsub("###TIME_STUFF###", timeStuff):gsub("###SHOWHIDE###", showJoin):gsub("###NICK###", nick);
	end
	return ret;
end

local function parseMessageStanza(stanza, timeStuff, nick)
	local body, title, ret = nil, nil, "";

	for _,tag in ipairs(stanza) do
		if tag.tag == "body" then
			body = tag[1];
			if nick ~= nil then
				break;
			end
		elseif tag.tag == "nick" and nick == nil then
			nick = htmlEscape(tag[1]);
			if body ~= nil or title ~= nil then
				break;
			end
		elseif tag.tag == "subject" then
			title = tag[1];
			if nick ~= nil then
				break;
			end
		end
	end
	if nick ~= nil and body ~= nil then
		body = htmlEscape(body);
		local me = body:find("^/me");
		local template = "";
		if not me then
			template = html.day.message;
		else
			template = html.day.messageMe;
			body = body:gsub("^/me ", "");
		end
		ret = template:gsub("###TIME_STUFF###", timeStuff):gsub("###NICK###", nick):gsub("###MSG###", body);
	elseif nick ~= nil and title ~= nil then
		title = htmlEscape(title);
		ret = html.day.titleChange:gsub("###TIME_STUFF###", timeStuff):gsub("###NICK###", nick):gsub("###TITLE###", title);
	end
	return ret;
end

local function incrementDay(bare_day)
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

local function findNextDay(bareRoomJid, bare_day)
	local node, host, resource = splitJid(bareRoomJid);
	local day = incrementDay(bare_day);
	local max_trys = 7;

	module:log("debug", day);
	while(not checkDatastorePathExists(node, host, day, false)) do
		max_trys = max_trys - 1;
		if max_trys == 0 then
			break;
		end
		day = incrementDay(day);
	end
	if max_trys == 0 then
		return nil;
	else
		return day;
	end
end

local function decrementDay(bare_day)
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

local function findPreviousDay(bareRoomJid, bare_day)
	local node, host, resource = splitJid(bareRoomJid);
	local day = decrementDay(bare_day);
	local max_trys = 7;
	module:log("debug", day);
	while(not checkDatastorePathExists(node, host, day, false)) do
		max_trys = max_trys - 1;
		if max_trys == 0 then
			break;
		end
		day = decrementDay(day);
	end
	if max_trys == 0 then
		return nil;
	else
		return day;
	end
end

local function parseDay(bareRoomJid, roomSubject, bare_day)
	local ret = "";
	local year;
	local month;
	local day;
	local tmp;
	local node, host, resource = splitJid(bareRoomJid);
	local year, month, day = bare_day:match("^20(%d%d)-(%d%d)-(%d%d)$");
	local previousDay = findPreviousDay(bareRoomJid, bare_day);
	local nextDay = findNextDay(bareRoomJid, bare_day);
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
	calendar = createMonth(temptime.month, temptime.year, {callback=perDayCallback, path=path, room=node, webPath="../"}) or ""

	if bare_day ~= nil then
		local data = data_load(node, host, datastore .. "/" .. bare_day:match("^20(.*)"):gsub("-", ""));
		if data ~= nil then
			for i=1, #data, 1 do
				local stanza = lom.parse(data[i]);
				if stanza ~= nil and stanza.attr ~= nil and stanza.attr.time ~= nil then
					local timeStuff = html.day.time:gsub("###TIME###", stanza.attr.time):gsub("###UTC###", stanza.attr.utc or stanza.attr.time);
					if stanza[1] ~= nil then
						local nick;
						local tmp;

						-- grep nick from "from" resource
						if stanza[1].attr.from ~= nil then -- presence and messages
							nick = htmlEscape(stanza[1].attr.from:match("/(.+)$"));
						elseif stanza[1].attr.to ~= nil then -- iq
							nick = htmlEscape(stanza[1].attr.to:match("/(.+)$"));
						end

						if stanza[1].tag == "presence" and nick ~= nil then
							tmp = parsePresenceStanza(stanza[1], timeStuff, nick);
						elseif stanza[1].tag == "message" then
							tmp = parseMessageStanza(stanza[1], timeStuff, nick);
						elseif stanza[1].tag == "iq" then
							tmp = parseIqStanza(stanza[1], timeStuff, nick);
						else
							module:log("info", "unknown stanza subtag in log found. room: %s; day: %s", bareRoomJid, year .. "/" .. month .. "/" .. day);
						end
						if tmp ~= nil then
							ret = ret .. tmp
							tmp = nil;
						end
					end
				end
			end
		end
		if ret ~= "" then
			if nextDay then
				nextDay = html.day.dayLink:gsub("###DAY###", nextDay):gsub("###TEXT###", "&gt;")
			end
			if previousDay then
				previousDay = html.day.dayLink:gsub("###DAY###", previousDay):gsub("###TEXT###", "&lt;");
			end
			ret = ret:gsub("%%", "%%%%");
			tmp = html.day.body:gsub("###DAY_STUFF###", ret):gsub("###JID###", bareRoomJid);
			tmp = tmp:gsub("###CALENDAR###", calendar);
			tmp = tmp:gsub("###DATE###", tostring(os_date("%A, %B %d, %Y", os_time(temptime))));
			tmp = tmp:gsub("###TITLE_STUFF###", html.day.title:gsub("###TITLE###", roomSubject));
			tmp = tmp:gsub("###STATUS_CHECKED###", config.showStatus and "checked='checked'" or "");
			tmp = tmp:gsub("###JOIN_CHECKED###", config.showJoin and "checked='checked'" or "");
			tmp = tmp:gsub("###NEXT_LINK###", nextDay or "");
			tmp = tmp:gsub("###PREVIOUS_LINK###", previousDay or "");

			return tmp, "Chatroom logs for "..bareRoomJid.." ("..tostring(os_date("%A, %B %d, %Y", os_time(temptime)))..")";
		end
	end
end

local function handle_error(code, err) return http_event("http-error", { code = code, message = err }); end
function handle_request(event)
	local response = event.response;
	local request = event.request;

	local node, day, more = request.url.path:match("^/"..urlBase.."/+([^/]*)/*([^/]*)/*(.*)$");
	if more ~= "" then
		response.status_code = 404;
		response:send();
	end
	if node == "" then node = nil; end
	if day  == "" then day  = nil; end

	node = urldecode(node);
	local code, err, room;

	if not html.doc then 
		code, err = 500, "Muc Theme is not loaded.";
		return response:send(handle_error(code, err));
	end

	
	if node then room = hosts[my_host].modules.muc.rooms[node.."@"..my_host]; end
	if node and not room then
		code, err = 404, "Room doesn't exist.";
		return response:send(handle_error(code, err));
	end
	if room and (room._data.hidden or not room._data.logging) then
		code, err = 404, "There're no logs for this room.";
		return response:send(handle_error(code, err));
	end


	if not node then -- room list for component
		return response:send(createDoc(generateRoomListSiteContent(my_host))); 
	elseif not day then -- room's listing
		return response:send(createDoc(generateDayListSiteContentByRoom(node.."@"..my_host)));
	else
		if not day:match("^20(%d%d)-(%d%d)-(%d%d)$") then
			local y,m,d = day:match("^(%d%d)(%d%d)(%d%d)$");
			if not y then
				code, err = 404, "No entries for that year.";
				return response:send(handle_error(code, err));
			end
			response.status_code = 301;
			response.headers = { ["Location"] = request.url.path:match("^/"..urlBase.."/+[^/]*").."/20"..y.."-"..m.."-"..d.."/" };
			return response:send();
		end

		local body = createDoc(parseDay(node.."@"..my_host, room._data.subject or "", day));
		if body == "" then
			code, err = 404, "Day entry doesn't exist.";
			return response:send(handle_error(code, err));
		end
		return response:send(body);
	end
end

local function readFile(filepath)
	local f,err = io_open(filepath, "r");
	if not f then return f,err; end
	local t = f:read("*all");
	f:close()
	return t;
end

local function loadTheme(path)
	for file in lfs.dir(path) do
		if file:match("%.html$") then
			module:log("debug", "opening theme file: " .. file);
			local content,err = readFile(path .. "/" .. file);
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
	if config.showStatus == nil then config.showStatus = true; end
	if config.showJoin == nil then config.showJoin = true; end
	if config.urlBase ~= nil and type(config.urlBase) then urlBase = config.urlBase; end

	theme = config.theme or "metronome";
	local themePath = themesParent .. "/" .. tostring(theme);
	local attributes, err = lfs.attributes(themePath);
	if attributes == nil or attributes.mode ~= "directory" then
		module:log("error", "Theme folder of theme \"".. tostring(theme) .. "\" isn't existing. expected Path: " .. themePath);
		return false;
	end

	local themeLoaded,err = loadTheme(themePath);
	if not themeLoaded then
		module:log("error", "Theme \"%s\" is missing something: %s", tostring(theme), err);
		return false;
	end

	module:provides("http", {
		default_path = urlBase,
	        route = {
                	["GET /*"] = handle_request;
        	}
	});
end
