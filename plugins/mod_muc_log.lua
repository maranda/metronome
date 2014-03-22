-- * Metronome IM *
--
-- This file is part of the Metronome XMPP server and is released under the
-- ISC License, please see the LICENSE file in this source package for more
-- information about copyright and licensing.
--
-- Additional Contributors: John Regan

-- Imported from prosody-modules, mod_muc_log

local modulemanager = modulemanager;
if not modulemanager.is_loaded(module.host, "muc") then
	module:log("error", "mod_muc_log can only be loaded on a muc component!")
	return;
end

local metronome = metronome;
local hosts = metronome.hosts;
local tostring = tostring;
local jid_bare = require "util.jid".bare;
local jid_section = require "util.jid".section;
local cm = require "core.configmanager";
local datamanager = require "util.datamanager";
local data_load, data_store, data_getpath = datamanager.load, datamanager.store, datamanager.getpath;
local datastore = "muc_log";
local error_reply = require "util.stanza".error_reply;
local storagemanager = storagemanager;
local ripairs, t_insert, t_remove = ripairs, table.insert, table.remove;

local mod_host = module:get_host();
local muc = hosts[mod_host].muc;

-- Helper Functions

local function inject_storage_config()
	local _storage = cm.getconfig()[mod_host].storage;

	module:log("debug", "injecting storage config...");
	if type(_storage) == "string" then cm.getconfig()[mod_host].default_storage = _storage; end
	if type(_storage) == "table" then -- append
		_storage.muc_log = "internal";
	else
		cm.getconfig()[mod_host].storage = { muc_log = "internal" };
	end

	storagemanager.get_driver(mod_host, "muc_log"); -- init
end

-- Module Definitions

function log_if_needed(e)
	local stanza, origin = e.stanza, e.origin;
	
	if (stanza.name == "message" and stanza.attr.type == "groupchat") then
		local to_room = stanza.attr.to;
		local from_room = stanza.attr.from;
		local node = jid_section(to_room, "node");
		
		if not node then return; end

		local bare = jid_bare(to_room);
		if muc.rooms[bare] then
			local room = muc.rooms[bare];
			local today = os.date("!%y%m%d");
			local now = os.date("!%X");
			local muc_from = nil;
			
			if room._data.hidden then -- do not log any data of private rooms
				return;
			end
			if not room._data.logging then -- do not log where logging is not enabled
				return;
			end
			
			local body, subject = stanza:child_with_name("body"), stanza:child_with_name("subject");
			
			if not body and not subject then return; end
			muc_from = room._jid_nick[from_room];

			if muc_from then
				local data = data_load(node, mod_host, datastore .. "/" .. today) or {};
				local replace = stanza:child_with_name("replace");
				local id = stanza.attr.id;
				
				if replace then -- implements XEP-308
					local count = 0;
					local rid = replace.attr.id;
					if rid and id ~= rid then
						for i, entry in ripairs(data) do
							count = count + 1; -- don't go back more then 100 entries, *sorry*.
							if count < 100 and entry.resource == from_room and entry.id == rid then
								t_remove(data, i); break; 
							end
						end
					end
				end
				
				data[#data + 1] = {
					time = now,
					from = muc_from,
					resource = from_room,
					id = stanza.attr.id,
					body = body and body:get_text(),
					subject = subject and subject:get_text()
				};
				
				data_store(node, mod_host, datastore .. "/" .. today, data);
			end
		end
	end
end

module:hook("message/bare", log_if_needed, 50);

-- Define config methods

local field_xmlns = "muc#roomconfig_enablelogging";

module:hook("muc-fields", function(room, layout)
	t_insert(layout, {
		name = field_xmlns,
		type = "boolean",
		label = "Enable room logging?",
		value = room:get_option("logging");
	});
end, -100);
module:hook("muc-fields-process", function(room, fields, stanza, changed, submitted)
	local config = fields[field_xmlns];	
	if room:get_option("hidden") and config then
		return error_reply(stanza, "cancel", "forbidden", "You can enable logging only into public rooms!");
	end
	room:set_option(field_xmlns, config, changed);
end, -100);
module:hook("muc-fields-submitted", function(room, message)
	if room:get_option("logging") then
		message.tags[1]:tag("status", {code = "170"}):up();
	else
		message.tags[1]:tag("status", {code = "171"}):up();
	end
	return message;
end, -100);
module:hook("muc-occupant-joined", function(room, presence)
	if room:get_option("logging") then presence:tag("status", {code = "170"}):up(); end
end, -100);

module:hook("config-reloaded", inject_storage_config);
function module.load() inject_storage_config(); end

module:log("debug", "module mod_muc_log loaded!");
