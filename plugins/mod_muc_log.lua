-- * Metronome IM *
--
-- This file is part of the Metronome XMPP server and is released under the
-- ISC License, please see the LICENSE file in this source package for more
-- information about copyright and licensing.
--
-- Additional Contributors: John Regan, Oscar Padilla

-- Imported from prosody-modules, mod_muc_log

if not module:host_is_muc() then
	error("mod_muc_log can only be loaded on a muc component!", 0)
end

module:depends("stanza_log");

local metronome = metronome;
local hosts = metronome.hosts;
local tostring = tostring;
local jid_bare = require "util.jid".bare;
local jid_section = require "util.jid".section;
local datamanager = require "util.datamanager";
local data_load, data_store, data_stores = datamanager.load, datamanager.store, datamanager.stores;
local datastore = "muc_log";
local error_reply = require "util.stanza".error_reply;

local ripairs, t_insert, t_remove = ripairs, table.insert, table.remove;

local xmlns_fasten = "urn:xmpp:fasten:0";
local hints_xmlns = "urn:xmpp:hints";
local labels_xmlns = "urn:xmpp:sec-label:0";
local lmc_xmlns = "urn:xmpp:message-correct:0";
local sid_xmlns = "urn:xmpp:sid:0";
local omemo_xmlns = "eu.siacs.conversations.axolotl";
local openpgp_xmlns = "urn:xmpp:openpgp:0";
local xhtml_xmlns = "http://www.w3.org/1999/xhtml";

local mod_host = module:get_host();
local host_object = module:get_host_session();

local stanzalog_lib = module:require("stanzalog", "auxlibs");

-- Module Definitions

function log_if_needed(e)
	local stanza = e.stanza;
	
	if (stanza.name == "message" and stanza.attr.type == "groupchat") then
		local to_room = stanza.attr.to;
		local from_room = stanza.attr.from;
		local node = jid_section(to_room, "node");
		
		if not node then return; end

		local bare = jid_bare(to_room);
		local room = host_object.muc and host_object.muc.rooms[bare];

		if room then
			local now = os.time();
			
			if not room._data.logging then -- do not log where logging is not enabled
				return;
			end

 			local apply_to, body, subject, omemo, html, openpgp =
				stanza:get_child("apply-to", xmlns_fasten),
				stanza:child_with_name("body"),
				stanza:child_with_name("subject"),
				stanza:get_child("encrypted", omemo_xmlns),
				stanza:get_child("html", xhtml_xmlns),
				stanza:get_child("openpgp", omemo_xmlns);
			
			if (not apply_to and not body and not subject and not omemo and not html and not openpgp) or
				stanza:get_child("no-store", hints_xmlns) or
				stanza:get_child("no-permanent-storage", hints_xmlns) then
				return;
			end
			
			local muc_from = room._jid_nick[from_room];
			if muc_from or (apply_to and from_room == room.jid) then
				local data, data_entry = module:fire_event("load-stanza-log", node, mod_host) or {};
				local replace = stanza:get_child("replace", lmc_xmlns);

				if replace then -- implements XEP-308
					local rid = replace.attr.id;
					if rid and id ~= rid then
						for i, entry in ripairs(data) do
							if entry.resource == from_room and entry.id == rid then
								entry.oid = nil;
								entry.body = nil;
								entry.tags = nil;
								break; 
							end
						end
					end
				end

				data, data_entry = stanzalog_lib.process_stanza(muc_from or room.jid, stanza, data);
				module:fire_event("store-stanza-log", node, mod_host, data, data_entry);
				stanza:tag("stanza-id", { xmlns = sid_xmlns, by = bare, id = data_entry.uid }):up();
			end
		end
	end
end

function disco_features(room, reply)
	reply:tag("feature", { var = sid_xmlns }):up()
end

function tombstone_entry(event)
	local node = jid_section(event.room.jid, "node");
	local now = os.time();
	local data = module:fire_event("load-stanza-log", node, mod_host, now - 2630000, now) or {};
	for i, entry in ripairs(data) do
		if entry.uid == event.moderation_id then
			entry.oid = nil;
			entry.body = nil;
			entry.tags = nil;
			break; 
		end
	end
	module:fire_event("store-stanza-log", node, mod_host, data);
	event.announcement.attr.to = event.room.jid;
	log_if_needed({ stanza = event.announcement });
	return true;
end

function clear_logs(event) -- clear logs from disk
	local node = jid_section(event.room.jid, "node");
	module:fire_event("purge-stanza-log", node, mod_host);
end

module:hook("muc-disco-info-features", disco_features, -99);
module:hook("message/bare", log_if_needed, 50);
module:hook("muc-room-destroyed", clear_logs);
module:hook("muc-tombstone-entry", tombstone_entry);

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
