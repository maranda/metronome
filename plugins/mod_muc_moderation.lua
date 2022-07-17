-- * Metronome IM *
--
-- This file is part of the Metronome XMPP server and is released under the
-- ISC License, please see the LICENSE file in this source package for more
-- information about copyright and licensing.
--
-- As per the sublicensing clause, this file is also MIT/X11 Licensed.
-- ** Copyright (c) 2015-2021, Kim Alvefur

-- Implements: XEP-0425: Message Moderation
-- This is a backport of the module from Prosody Modules

if not module:host_is_muc() then
	error("mod_muc_moderation can only be loaded on a muc component!", 0);
end

-- Imports
local dt = require "util.datetime";
local id = require "util.uuid".generate;
local jid = require "util.jid";
local st = require "util.stanza";

local valid_roles = {
	none = 0,
	visitor = 1,
	member = 2,
	moderator = 3,
}

-- Namespaces
local xmlns_fasten = "urn:xmpp:fasten:0";
local xmlns_moderate = "urn:xmpp:message-moderate:0";
local xmlns_retract = "urn:xmpp:message-retract:0";

-- Discovering support
module:hook("muc-disco-info-features", function(room, reply)
	reply:tag("feature", { var = xmlns_moderate }):up();
end, -102);

-- Main handling
module:hook("iq-set/bare/" .. xmlns_fasten .. ":apply-to", function (event)
	local stanza, origin = event.stanza, event.origin;

	-- Collect info we need
	local apply_to = stanza.tags[1];
	local moderate_tag = apply_to:get_child("moderate", xmlns_moderate);
	if not moderate_tag then return; end -- some other kind of fastening?

	local reason = moderate_tag:get_child_text("reason");
	local retract = moderate_tag:get_child("retract", xmlns_retract);

	local room_jid = stanza.attr.to;
	local room_node = jid.split(room_jid);
	local room = module:get_host_session().muc.rooms[room_jid];

	local stanza_id = apply_to.attr.id;

	-- Permissions
	local actor = stanza.attr.from;
	local actor_nick = room._jid_nick[actor];
	local affiliation = room:get_affiliation(actor);
	-- Retrieve their current role, if they are in the room, otherwise what they
	-- would have based on affiliation.
	local role = room:get_role(actor_nick) or room:get_default_role(affiliation);
	if valid_roles[role or "none"] < valid_roles.moderator then
		origin.send(st.error_reply(stanza, "auth", "forbidden", "You need a role of at least Moderator'"));
		return true;
	end

	local announcement = st.message({ from = room_jid, type = "groupchat", id = id(), })
		:tag("apply-to", { xmlns = xmlns_fasten, id = stanza_id })
			:tag("moderated", { xmlns = xmlns_moderate, by = actor_nick })

	if retract then
		announcement:tag("retract", { xmlns = xmlns_retract }):up();
		module:fire_event("muc-tombstone-entry", { room = room, moderation_id = stanza_id });
	end

	if reason then
		announcement:tag("reason"):text(reason);
	end

	-- Done, tell people about it
	module:log("info", "Message with id '%s' in room %s moderated by %s, reason: %s", stanza_id, room_jid, actor, reason);
	room:broadcast_message(announcement);

	origin.send(st.reply(stanza));
	return true;
end);