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
local get_actions = module:require("acdf_aux").get_actions;
local os_time, ripairs, t_insert, t_remove = os.time, ripairs, table.insert, table.remove;

local hints_xmlns = "urn:xmpp:hints";
local labels_xmlns = "urn:xmpp:sec-label:0";
local lmc_xmlns = "urn:xmpp:message-correct:0";
local sid_xmlns = "urn:xmpp:sid:0";
local omemo_xmlns = "eu.siacs.conversations.axolotl";
local openpgp_xmlns = "urn:xmpp:openpgp:0";
local xhtml_xmlns = "http://www.w3.org/1999/xhtml";

local mod_host = module:get_host();
local host_object = module:get_host_session();

local store_elements = module:get_option_set("muc_log_allowed_elements", {});

store_elements:add("acknowledged");
store_elements:add("apply-to");
store_elements:add("displayed");
store_elements:add("encrypted");
store_elements:add("encryption");
store_elements:add("markable");
store_elements:add("openpgp");
store_elements:add("securitylabel");
store_elements:add("received");
store_elements:remove("body");
store_elements:remove("html");
store_elements:remove("origin-id");
store_elements:remove("replace");

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
			
			local apply_to, body, subject, omemo, html, openpgp =
				stanza:child_with_name("apply-to"),
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
			muc_from = room._jid_nick[from_room];

			if muc_from or (apply_to and from_room == room.jid) then
				local data = data_load(node, mod_host, datastore .. "/" .. today) or {};
				local replace = stanza:get_child("replace", lmc_xmlns);
				local oid = stanza:get_child("origin-id", sid_xmlns);
				local id = stanza.attr.id;
				
				if replace then -- implements XEP-308
					local count = 0;
					local rid = replace.attr.id;
					if rid and id ~= rid then
						for i, entry in ripairs(data) do
							count = count + 1; -- don't go back more then 100 entries, *sorry*.
							if count <= 100 and entry.resource == from_room and entry.id == rid then
								entry.oid = nil;
								entry.body = nil;
								entry.tags = nil;
								break; 
							end
							if count == 100 then break; end
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

				-- store elements

				local tags = {};
				local elements = stanza.tags;
				for i = 1, #elements do
					local element = elements[i];
					if store_elements:contains(element.name) or (element.name == "html" and html) then
						if element.name == "securitylabel" and element.attr.xmlns == labels_xmlns then
							local text = element:get_child_text("displaymarking");
							data_entry.label_actions = get_actions(mod_host, text);
							data_entry.label_name = text;
						end
						t_insert(tags, deserialize(element));
					end
				end
				if not next(tags) then
					tags = nil;
				else
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

function tombstone_entry(event)
	local node = jid_section(event.room.jid, "node");
	local today = os.date("!%Y%m%d");
	local data = data_load(node, mod_host, datastore .. "/" .. today) or {};
	for i, entry in ripairs(data) do
		if entry.uid == event.moderation_id then
			entry.oid = nil;
			entry.body = nil;
			entry.tags = nil;
			module:fire_event("muc-log-remove-from-mamcache", event.room, entry.from, entry.id);
			break; 
		end
	end
	data_store(node, mod_host, datastore .. "/" .. today, data);
	return true;
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
