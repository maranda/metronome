-- * Metronome IM *
--
-- This file is part of the Metronome XMPP server and is released under the
-- ISC License, please see the LICENSE file in this source package for more
-- information about copyright and licensing.

-- This module implements a minimal part of XEP-273 to block incoming presences
-- particularly useful for Mobile Clients.

local NULL = {};
local pairs = pairs;
	
module:add_feature("urn:xmpp:sift:2");
module:add_feature("urn:xmpp:sift:stanzas:presence");
	
module:hook("iq-set/self/urn:xmpp:sift:2:sift", function(event)
	local stanza, session = event.stanza, event.origin;

	local sift = stanza.tags[1];
	local message = sift:child_with_name("message");
	local presence = sift:child_with_name("presence");
	local iq = sift:child_with_name("iq");

	if message or iq then
		return session.send(st.error_reply(stanza, "cancel", "feature-not-implemented", "Only sifting presences is currently supported"));
	elseif #sift.tags == 0 then
		session.presence_block = nil;
		session.to_block = nil;
		return session.send(st.reply(stanza));
	end
	
	if #presence.tags ~= 0 then
		return session.send(st.error_reply(stanza, "cancel", "feature-not-implemented", "Only blocking all presences is supported not granular filtering"));
	else
		session.presence_block = true;
		session.to_block = {};
		return session.send(st.reply(stanza));
	end
end);

module:hook("presence/bare", function(event)
	local stanza = event.stanza;
	if stanza.attr.type == "probe" then -- do not drop probes, these will never reach the client
		return;
	end

	local to_bare = bare_sessions[stanza.attr.to];
	if not to_bare then
		return;
	else
		for _, resource in pairs(to_bare.sessions or NULL) do
			if resource.presence_block then resource.to_block[stanza] = true; end
		end
	end
end, 100);

module:hook("presence/full", function(event)
	local stanza = event.stanza;
	local to_full = full_sessions[stanza.attr.to];
	if to_full and to_full.presence_block then return true; end
end, 100);