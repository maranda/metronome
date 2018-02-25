-- * Metronome IM *
--
-- This file is part of the Metronome XMPP server and is released under the
-- ISC License, please see the LICENSE file in this source package for more
-- information about copyright and licensing.
--
-- As per the sublicensing clause, this file is also MIT/X11 Licensed.
-- ** Copyright (c) 2012, Matthew Wild

local modulemanager = modulemanager;
if not modulemanager.is_loaded(module.host, "muc") then
	module:log("error", "mod_muc_limits can only be loaded on a muc component!");
	modulemanager.unload(module.host, "muc_limits");
	return;
end

local st = require "util.stanza";
local new_throttle = require "util.throttle".create;
local jid_bare = require "util.jid".bare;
local jid_section = require "util.jid".section;
local jid_split = require "util.jid".split;
local math, tonumber, t_insert = math, tonumber, table.insert;

local xmlns_muc = "http://jabber.org/protocol/muc";

local period = math.max(module:get_option_number("muc_event_rate", 0.5), 0);
local burst = math.max(module:get_option_number("muc_burst_factor", 6), 1);
local exclusion_list = module:get_option_set("muc_throttle_host_exclusion");
local parent_host = module:get_option_boolean("muc_whitelist_parent_peers") == true and module.host:match("%.(.*)");
local disconnect_after = module:get_option_number("muc_disconnect_after_throttles", 20);

local rooms = metronome.hosts[module.host].modules.muc.rooms;
local hosts = metronome.hosts;
local _parent, _default_period, _default_burst = nil, period*2, burst*10;

-- Handlers

local function handle_stanza(event)
	local origin, stanza = event.origin, event.stanza;

	if stanza.name == "presence" and stanza.attr.type == "unavailable" then -- Don't limit room leaving
		return;
	end

	local domain = jid_section(stanza.attr.from, "host");
	if exclusion_list and exclusion_list:contains(domain) then
		module:log("debug", "Skipping stanza from excluded host %s...", domain);
		return;
	end
	if _parent and _parent.events.fire_event("peer-is-subscribed", domain) then
		module:log("debug", "Skipping stanza from server peer %s...", domain);
		return;
	end

	local dest_room, dest_host, dest_nick = jid_split(stanza.attr.to);
	local room = rooms[dest_room.."@"..dest_host];
	if not room then return; end
	local from_jid = stanza.attr.from;
	local occupant_jid = room._jid_nick[from_jid];
	local occupant = room._occupants[occupant_jid];
	if (occupant and occupant.affiliation) or (not(occupant) and room._affiliations[jid_bare(from_jid)]) then
		module:log("debug", "Skipping stanza from affiliated user...");
		return;
	end
	local throttle = room.throttle;
	if not room.throttle then
		local _period, _burst;
		if not room:get_option("limits_enabled") then
			_period, _burst = _default_period, _default_burst;
		else
			_period, _burst = room:get_option("limits_seconds") or period, room:get_option("limits_stanzas") or burst;
		end
		throttle = new_throttle(_period*_burst, _burst);
		room.throttle = throttle;
	end
	if not throttle:poll(1) then
		local trigger = origin.muc_limits_trigger;
		module:log("warn", "Dropping stanza for %s@%s from %s, over rate limit", dest_room, dest_host, from_jid);
		if stanza.attr.type == "error" then return true; end -- drop errors silently
		if trigger and trigger >= disconnect_after then
			room:set_role(true, occupant_jid, "none", nil, "Exceeded number of allowed throttled stanzas");
			origin:close{ condition = "policy-violation", text = "Exceeded number of allowed throttled stanzas" };
			return true;
		end

		origin.muc_limits_trigger = (not trigger and 1) or trigger + 1;
		local reply = st.error_reply(stanza, "wait", "policy-violation", "The room is currently overactive, please try again later");
		local body = stanza:get_child_text("body");
		if body then
			reply:up():tag("body"):text(body):up();
		end
		local x = stanza:get_child("x", xmlns_muc);
		if x then
			reply:add_child(st.clone(x));
		end
		origin.send(reply);
		return true;
	end
end

-- MUC Custom Form

local field_enabled = "muc#roomconfig_limits_enabled";
local field_stanzas = "muc#roomconfig_limits_stanzas";
local field_seconds = "muc#roomconfig_limits_seconds";

module:hook("muc-fields", function(room, layout)
	t_insert(layout, {
		name = field_enabled,
		type = "boolean",
		label = "Enable stanza limits?",
		value = room:get_option("limits_enabled");
	});
	t_insert(layout, {
		name = field_stanzas,
		type = "text-single",
		label = "Number of Stanzas",
		value = tostring(room:get_option("limits_stanzas") or burst);
	});
	t_insert(layout, {
		name = field_seconds,
		type = "text-single",
		label = "Per how many seconds",
		value = tostring(room:get_option("limits_seconds") or period);
	});
end, -101);

module:hook("muc-fields-process", function(room, fields, stanza, changed)
	room.throttle = nil;
	local stanzas, seconds = fields[field_stanzas], fields[field_seconds];
	if not tonumber(stanzas) or not tonumber(seconds) then
		return st.error_reply(stanza, "cancel", "forbidden", "You need to submit valid number values for muc_limits fields.");
	end
	stanzas, seconds = math.max(tonumber(stanzas), 1), math.max(tonumber(seconds), 0);
	room:set_option("limits_enabled", fields[field_enabled], changed);
	room:set_option("limits_stanzas", stanzas, changed);
	room:set_option("limits_seconds", seconds, changed);
end, -101);

function module.unload()
	for room_jid, room in pairs(rooms) do
		room.throttle = nil;
	end
end

module:hook("message/bare", handle_stanza, 100);
module:hook("message/full", handle_stanza, 100);
module:hook("presence/bare", handle_stanza, 100);
module:hook("presence/full", handle_stanza, 100);

if parent_host then
	_parent = hosts[parent_host];
	module:hook_global("host-activated", function(host)
		if host == parent_host then _parent = hosts[host]; end
	end);
	module:hook_global("host-deactivated", function(host)
		if host == parent_host then _parent = nil; end
	end);
end
