-- Imported from prosody-modules, mod_muc_log

local metronome = metronome;
local tostring = _G.tostring;
local splitJid = require "util.jid".split;
local config_get = require "core.configmanager".get;
local datamanager = require "util.datamanager";
local data_load, data_store, data_getpath = datamanager.load, datamanager.store, datamanager.getpath;
local datastore = "muc_log";
local mod_host = module:get_host();
local config = nil;

local lfs = require "lfs";

local function checkDatastorePathExists(node, host, today, create)
	create = create or false;
	local path = data_getpath(node, host, datastore, "dat", true);
	path = path:gsub("/[^/]*$", "");

	-- check existance
	local attributes, err = lfs.attributes(path);
	if (attributes == nil or attributes.mode ~= "directory") and not create then
		module:log("warn", "muc_log folder isn't a folder: %s", path);
		return false;
	elseif attributes == nil and create then
		lfs.mkdir(path);
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

function logIfNeeded(e)
	local stanza, origin = e.stanza, e.origin;
	
	if	(stanza.name == "presence") or
		(stanza.name == "iq") or
	   	(stanza.name == "message" and tostring(stanza.attr.type) == "groupchat")
	then
		local node, host, resource = splitJid(stanza.attr.to);
		if node ~= nil and host ~= nil then
			local bare = node .. "@" .. host;
			if host == mod_host and metronome.hosts[host] ~= nil and metronome.hosts[host].muc ~= nil and metronome.hosts[host].muc.rooms[bare] ~= nil then
				local room = metronome.hosts[host].muc.rooms[bare]
				local today = os.date("%y%m%d");
				local now = os.date("%X")
				local mucTo = nil
				local mucFrom = nil;
				local alreadyJoined = false;
				
				if room._data.hidden then -- do not log any data of private rooms
					return;
				end
				if not room._data.logging then -- do not log where logging is not enabled
					return;
				end
				
				if stanza.name == "presence" and stanza.attr.type == nil then
					mucFrom = stanza.attr.to;
					if room._occupants ~= nil and room._occupants[stanza.attr.to] ~= nil then -- if true, the user has already joined the room
						alreadyJoined = true;
						stanza:tag("alreadyJoined"):text("true"); -- we need to log the information that the user has already joined, so add this and remove after logging
					end
				elseif stanza.name == "iq" and stanza.attr.type == "set" then -- kick, to is the room, from is the admin, nick who is kicked is attr of iq->query->item
					if stanza.tags[1] ~= nil and stanza.tags[1].name == "query" then
						local tmp = stanza.tags[1];
						if tmp.tags[1] ~= nil and tmp.tags[1].name == "item" and tmp.tags[1].attr.nick ~= nil then
							tmp = tmp.tags[1];
							for jid, nick in pairs(room._jid_nick) do
								if nick == stanza.attr.to .. "/" .. tmp.attr.nick then
									mucTo = nick;
									break;
								end
							end
						end
					end
				else
					for jid, nick in pairs(room._jid_nick) do
						if jid == stanza.attr.from then
							mucFrom = nick;
							break;
						end
					end
				end

				if (mucFrom ~= nil or mucTo ~= nil) and checkDatastorePathExists(node, host, today, true) then
					local data = data_load(node, host, datastore .. "/" .. today);
					local realFrom = stanza.attr.from;
					local realTo = stanza.attr.to;
					
					if data == nil then
						data = {};
					end
					
					stanza.attr.from = mucFrom;
					stanza.attr.to = mucTo;
					data[#data + 1] = "<stanza time=\"".. now .. "\">" .. tostring(stanza) .. "</stanza>\n";
					stanza.attr.from = realFrom;
					stanza.attr.to = realTo;
					if alreadyJoined == true then
						if stanza[#stanza].name == "alreadyJoined" then  -- normaly the faked element should be the last, remove it when it is the last
							stanza[#stanza] = nil;
						else
							for i = 1, #stanza, 1 do
								if stanza[i].name == "alreadyJoined" then  -- remove the faked element
									stanza[i] = nil;
									break;
								end
							end
						end
					end
					data_store(node, host, datastore .. "/" .. today, data);
				end
			end
		end
	end
end

module:hook("message/bare", logIfNeeded, 500);
module:hook("iq/bare", logIfNeeded, 500);
module:hook("presence/full", logIfNeeded, 500);

module:log("debug", "module mod_muc_log loaded!");
