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
	module:log("error", "mod_muc_limits can only be loaded on a muc component!")
	return;
end

local st = require "util.stanza";
local new_throttle = require "util.throttle".create;
local jid_bare = require "util.jid".bare;
local jid_section = require "util.jid".section;
local jid_split = require "util.jid".split;
local math, tonumber = math, tonumber;

local xmlns_muc = "http://jabber.org/protocol/muc";

local period = math.max(module:get_option_number("muc_event_rate", 0.5), 0);
local burst = math.max(module:get_option_number("muc_burst_factor", 6), 1);
local exclusion_list = module:get_option_set("muc_throttle_host_exclusion");
local parent_host = module:get_option_boolean("muc_whitelist_parent_peers") == true and module.host:match("%.(.*)");

local rooms = metronome.hosts[module.host].modules.muc.rooms;
local hosts = metronome.hosts;

-- Handlers

local function handle_stanza(event)
	local origin, stanza = event.origin, event.stanza;

	if stanza.name == "presence" and stanza.attr.type == "unavailable" then -- Don't limit room leaving
		return;
	end

	local domain = jid_section(stanza.attr.from, "host");
	if exclusion_list and exclusion_list:contains(domain) then
		return;
	end
	if parent_host and hosts[parent_host].events.fire_event("peer-is-subscribed", domain) then
		return;
	end

	local dest_room, dest_host, dest_nick = jid_split(stanza.attr.to);
	local room = rooms[dest_room.."@"..dest_host];
	if not room or not room:get_option("limits_enabled") then return; end
	local from_jid = stanza.attr.from;
	local occupant = room._occupants[room._jid_nick[from_jid]];
	if (occupant and occupant.affiliation) or (not(occupant) and room._affiliations[jid_bare(from_jid)]) then
		module:log("debug", "Skipping stanza from affiliated user...");
		return;
	end
	local throttle = room.throttle;
	if not room.throttle then
		local _period, _burst = room:get_option("limits_seconds") or period, room:get_option("limits_stanzas") or burst;
		throttle = new_throttle(_period*_burst, _burst);
		room.throttle = throttle;
	end
	if not throttle:poll(1) then
		module:log("warn", "Dropping stanza for %s@%s from %s, over rate limit", dest_room, dest_host, from_jid);
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

local function le_field(self)
	local field = {
		name = "muc#roomconfig_limits_enabled",
		type = "boolean",
		label = "Enable stanza limits?",
		value = self:get_option("limits_enabled");
	};
	return field;
end

local function lstanzas_field(self)
	local value = self:get_option("limits_stanzas") or burst;
	local field = {
		name = "muc#roomconfig_limits_stanzas",
		type = "text-single",
		label = "Number of Stanzas",
		value = tostring(value)
	};
	return field;
end
local function lseconds_field(self)
	local value = self:get_option("limits_seconds") or period;
	local field = {
		name = "muc#roomconfig_limits_seconds",
		type = "text-single",
		label = "Per how many seconds",
		value = tostring(value)
	};
	return field;
end

local function check(self, stanza, config)
	local reply;
	if not tonumber(config) then
		reply = error_reply(stanza, "cancel", "forbidden", "You need to submit valid number values for muc_limits fields.");
	end
	self.throttle = nil;
	return reply;
end
local function stanzas(self, value) return math.max(tonumber(value), 1); end
local function seconds(self, value) return math.max(tonumber(value), 0); end

-- Module Hooks

function module.load()
	module:fire_event("muc-config-handler", {
		xmlns = "muc#roomconfig_limits_enabled",
		params = {
			name = "limits_enabled",
			field = le_field,
		},
		action = "register",
		caller = "muc_limits"
	});
	module:fire_event("muc-config-handler", {
		xmlns = "muc#roomconfig_limits_stanzas",
		params = {
			name = "limits_stanzas",
			field = lstanzas_field,
			check = check,
			process = stanzas
		},
		action = "register",
		caller = "muc_limits"
	});
	module:fire_event("muc-config-handler", {
		xmlns = "muc#roomconfig_limits_seconds",
		params = {
			name = "limits_seconds",
			field = lseconds_field,
			check = check,
			process = seconds
		},
		action = "register",
		caller = "muc_limits"
	});
end

function module.unload()
	for room_jid, room in pairs(rooms) do
		room.throttle = nil;
	end
	module:fire_event("muc-config-handler", { xmlns = "muc#roomconfig_limits_enabled", caller = "muc_limits" });
	module:fire_event("muc-config-handler", { xmlns = "muc#roomconfig_limits_stanzas", caller = "muc_limits" });
	module:fire_event("muc-config-handler", { xmlns = "muc#roomconfig_limits_seconds", caller = "muc_limits" });
end

module:hook("message/bare", handle_stanza, 100);
module:hook("message/full", handle_stanza, 100);
module:hook("presence/bare", handle_stanza, 100);
module:hook("presence/full", handle_stanza, 100);
