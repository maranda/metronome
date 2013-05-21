-- * Metronome IM *
--
-- This file is part of the Metronome XMPP server and is released under the
-- ISC License, please see the LICENSE file in this source package for more
-- information about copyright and licensing.
--
-- As per the sublicensing clause, this file is also MIT/X11 Licensed.
-- ** Copyright (c) 2012, Matthew Wild

local st = require "util.stanza";
local new_throttle = require "util.throttle".create;
local jid_split = require "util.jid".split;

local xmlns_muc = "http://jabber.org/protocol/muc";

local period = math.max(module:get_option_number("muc_event_rate", 0.5), 0);
local burst = math.max(module:get_option_number("muc_burst_factor", 6), 1);
local exclusion_list = module:get_option_set("muc_throttle_host_exclusion");

local function handle_stanza(event)
	local origin, stanza = event.origin, event.stanza;

	if stanza.name == "presence" and stanza.attr.type == "unavailable" then -- Don't limit room leaving
		return;
	end

	local node, domain = jid_split(stanza.attr.from);
	if exclusion_list and exclusion_list:contains(domain) then
		return;
	end

	local dest_room, dest_host, dest_nick = jid.split(stanza.attr.to);
	local room = hosts[module.host].modules.muc.rooms[dest_room.."@"..dest_host];
	if not room then return; end
	local from_jid = stanza.attr.from;
	local occupant = room._occupants[room._jid_nick[from_jid]];
	if occupant and occupant.affiliation then
		module:log("debug", "Skipping stanza from affiliated user...");
		return;
	end
	local throttle = room.throttle;
	if not room.throttle then
		throttle = new_throttle(period*burst, burst);
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

function module.unload()
	for room_jid, room in pairs(hosts[module.host].modules.muc.rooms) do
		room.throttle = nil;
	end
end

module:hook("message/bare", handle_stanza, 10);
module:hook("message/full", handle_stanza, 10);
module:hook("presence/bare", handle_stanza, 10);
module:hook("presence/full", handle_stanza, 10);
