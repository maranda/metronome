-- * Metronome IM *
--
-- This file is part of the Metronome XMPP server and is released under the
-- ISC License, please see the LICENSE file in this source package for more
-- information about copyright and licensing.
--
-- Additional Contributors: John Regan, Oscar Padilla

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
local datamanager = require "util.datamanager";
local data_load, data_store, data_stores = datamanager.load, datamanager.store, datamanager.stores;
local datastore = "muc_log";
local error_reply = require "util.stanza".error_reply;
local deserialize = require "util.stanza".deserialize;
local uuid = require "util.uuid".generate;
local os_time, ripairs, t_insert, t_remove = os.time, ripairs, table.insert, table.remove;

local hints_xmlns = "urn:xmpp:hints";
local labels_xmlns = "urn:xmpp:sec-label:0";
local lmc_xmlns = "urn:xmpp:message-correct:0";
local sid_xmlns = "urn:xmpp:sid:0";

local mod_host = module:get_host();
local host_object = hosts[mod_host];

-- Module Definitions

function log_if_needed(e)
	local stanza, origin = e.stanza, e.origin;
	
	if (stanza.name == "message" and stanza.attr.type == "groupchat") then
		local to_room = stanza.attr.to;
		local from_room = stanza.attr.from;
		local node = jid_section(to_room, "node");
		
		if not node then return; end

		local bare = jid_bare(to_room);
		local room = host_object.muc and host_object.muc.rooms[bare];

		if room then
			local today = os.date("!%Y%m%d");
			local now = os.date("!%X");
			local muc_from = nil;
			
			if not room._data.logging then -- do not log where logging is not enabled
				return;
			end
			
			local body, subject = stanza:child_with_name("body"), stanza:child_with_name("subject");
			
			if (not body and not subject) or
				stanza:get_child("no-store", hints_xmlns) or
				stanza:get_child("no-permanent-storage", hints_xmlns) then
				return;
			end
			muc_from = room._jid_nick[from_room];

			if muc_from then
				local data = data_load(node, mod_host, datastore .. "/" .. today) or {};
				local label = stanza:get_child("securitylabel", labels_xmlns);
				local replace = stanza:get_child("replace", lmc_xmlns);
				local oid = stanza:get_child("origin-id", sid_xmlns);
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
						module:fire_event("muc-log-remove-from-mamcache", room, from_room, rid);
					end
				end
				
				local uid = uuid();
				local data_entry = {
					time = now,
					timestamp = os_time(),
					from = muc_from,
					resource = from_room,
					id = stanza.attr.id,
					oid = oid and oid.attr.id, -- needed for mod_muc_log_mam
					uid = uid,
					type = stanza.attr.type, -- needed for mod_muc_log_mam
					body = body and body:get_text(),
					subject = subject and subject:get_text()
				};
				data[#data + 1] = data_entry;

				if label then
					local tags, host = {}, jid_section(resource, "host");
					local text = label:get_child_text("displaymarking");
					t_insert(tags, deserialize(label));
					data_entry.label_actions = hosts[host] and hosts[host].events.fire_event("sec-labels-fetch-actions", text);
					data_entry.label_name = text;
					data_entry.tags = tags;
				end
				
				data_store(node, mod_host, datastore .. "/" .. today, data);
				module:fire_event("muc-log-add-to-mamcache", room, data_entry);
				stanza:tag("stanza-id", { xmlns = sid_xmlns, by = bare, id = uid }):up();
			end
		end
	end
end

function disco_features(room, reply)
	reply:tag("feature", { var = sid_xmlns }):up()
end

function clear_logs(event) -- clear logs from disk
	local node = jid_section(event.room.jid, "node");
	for store in data_stores(node, mod_host, "keyval", datastore) do
		data_store(node, mod_host, store, nil);
	end
end

module:hook("muc-disco-info-features", disco_features, -99);
module:hook("message/bare", log_if_needed, 50);
module:hook("muc-room-destroyed", clear_logs);

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
module:hook("muc-fields-process", function(room, fields, stanza, changed)
	local config = fields[field_xmlns];
	if not room:get_option("persistent") and config then
		return error_reply(stanza, "cancel", "forbidden", "You can enable logging only into persistent rooms!");
	elseif not config then
		clear_logs({ room = room });
	end
	room:set_option("logging", config, changed);
end, -100);
module:hook("muc-fields-submitted", function(room, message)
	if room:get_option("logging") then
		message.tags[1]:tag("status", {code = "170"}):up();
	else
		message.tags[1]:tag("status", {code = "171"}):up();
	end
	return message;
end, -100);
module:hook("muc-occupant-join-presence", function(room, presence)
	if room:get_option("logging") then presence:tag("status", {code = "170"}):up(); end
end, -100);

module.storage = { muc_log = "internal" };

module:log("debug", "module mod_muc_log loaded!");
