-- * Metronome IM *
--
-- This file is part of the Metronome XMPP server and is released under the
-- ISC License, please see the LICENSE file in this source package for more
-- information about copyright and licensing.

-- This module implements a minimal part of XEP-273 and XEP-352 to block incoming
-- presences particularly useful for Mobile Clients.

local NULL = {};
local pairs, t_insert = pairs, table.insert;
local jid_join = require "util.jid".join;
local st = require "util.stanza";
	
module:add_feature("urn:xmpp:csi:0");
module:add_feature("urn:xmpp:sift:2");
module:add_feature("urn:xmpp:sift:stanzas:presence");

module:hook("stream-features", function(event)
	if event.origin.type == "c2s" then event.features:tag("csi", { xmlns = "urn:xmpp:csi:0" }):up(); end
end, 97);
	
module:hook("iq-set/self/urn:xmpp:sift:2:sift", function(event)
	local stanza, session = event.stanza, event.origin;

	if session.csi then
		session.send(st.error_reply(stanza, "cancel", "forbidden", "Can't handle filtering via SIFT when Client State Indication is used"));
		return true;
	end

	local sift = stanza.tags[1];
	local message = sift:child_with_name("message");
	local presence = sift:child_with_name("presence");
	local iq = sift:child_with_name("iq");

	if message or iq then
		session.send(st.error_reply(stanza, "cancel", "feature-not-implemented", "Only sifting presences is currently supported"));
		return true;
	elseif #sift.tags == 0 then
		module:log("info", "%s removing all SIFT filters", session.full_jid or jid_join(session.username, session.host));
		session.presence_block, session.to_block = nil, nil;
		session.send(st.reply(stanza));
		return true;
	end
	
	if #presence.tags ~= 0 then
		session.send(st.error_reply(stanza, "cancel", "feature-not-implemented", "Only blocking all presences is supported not granular filtering"));
		return true;
	else
		module:log("info", "%s enabling SIFT filtering of all incoming presences", session.full_jid or jid_join(session.username, session.host));
		session.presence_block, session.to_block = true, {};
		session.send(st.reply(stanza));
		return true;
	end
end);

module:hook("stanza/urn:xmpp:csi:0:active", function(event)
	local session = event.origin;
	if session.type == "c2s" and session.csi ~= "active" then
		local jid = session.full_jid or jid_join(session.username, session.host);
		module:log("info", "%s signaling client is active", jid);
		session.csi = "active";
		local send, queue = session.send, session.csi_queue;
		if queue and #queue > 0 then -- flush queue
			module:log("debug", "flushing queued stanzas to %s", jid);
			for i = 1, #queue do
				module:log("debug", "sending presence: %s", queue[i]:top_tag());
				send(queue[i]);
			end
		end
		session.csi_queue, session.presence_block, session.to_block, queue = nil, nil, nil, nil;
		module:fire_event("client-state-changed", { session = session, state = session.csi });
	end
	return true;
end);

module:hook("stanza/urn:xmpp:csi:0:inactive", function(event)
	local session = event.origin;
	if session.type == "c2s" and session.csi ~= "inactive" then
		module:log("info", "%s signaling client is inactive blocking and queuing incoming presences", 
			session.full_jid or jid_join(session.username, session.host));
		session.csi = "inactive";
		session.csi_queue, session.to_block, session.presence_block = {}, {}, true;
		module:fire_event("client-state-changed", { session = session, state = session.csi });
	end
	return true;
end);

module:hook("presence/bare", function(event)
	local stanza = event.stanza;
	local t = stanza.attr.type;
	if not (t == nil or t == "unavailable") then return; end

	local to_bare = bare_sessions[stanza.attr.to];
	if not to_bare then
		return;
	else
		for _, resource in pairs(to_bare.sessions or NULL) do
			if resource.presence_block then
				if resource.csi == "inactive" then
					module:log("debug", "queuing presence for %s: %s", resource.full_jid, stanza:top_tag());
					t_insert(resource.csi_queue, st.clone(stanza)); 
				end
				resource.to_block[stanza] = true; 
			end
		end
	end
end, 100);

module:hook("presence/full", function(event)
	local stanza = event.stanza;
	local t = stanza.attr.type;
	if not (t == nil or t == "unavailable") then return; end
	
	local to_full = full_sessions[stanza.attr.to];
	if to_full then
		if to_full.csi == "inactive" then
			module:log("debug", "queuing presence for %s: %s", to_full.full_jid, stanza:top_tag());
			t_insert(to_full.csi_queue, st.clone(stanza));
		end
		if to_full.presence_block then return true; end
	end
end, 100);