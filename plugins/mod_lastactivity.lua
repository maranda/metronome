-- * Metronome IM *
--
-- This file is part of the Metronome XMPP server and is released under the
-- ISC License, please see the LICENSE file in this source package for more
-- information about copyright and licensing.
--
-- As per the sublicensing clause, this file is also MIT/X11 Licensed.
-- ** Copyright (c) 2009-2010, Matthew Wild, Waqas Hussain

local st = require "util.stanza";
local is_contact_subscribed = require "core.rostermanager".is_contact_subscribed;
local jid_bare = require "util.jid".bare;
local jid_split = require "util.jid".split;

module:add_feature("jabber:iq:last");

local map = {};

module:hook("pre-presence/bare", function(event)
	local stanza = event.stanza;
	if not(stanza.attr.to) and stanza.attr.type == "unavailable" then
		local t = os.time();
		local s = stanza:child_with_name("status");
		s = s and #s.tags == 0 and s[1] or "";
		map[event.origin.username] = {s = s, t = t};
	end
end, 10);

module:hook("iq/bare/jabber:iq:last:query", function(event)
	local origin, stanza = event.origin, event.stanza;
	if stanza.attr.type == "get" then
		local username = jid_split(stanza.attr.to) or origin.username;
		if not stanza.attr.to or is_contact_subscribed(username, module.host, jid_bare(stanza.attr.from)) then
			local seconds, text = "0", "";
			if map[username] then
				seconds = tostring(os.difftime(os.time(), map[username].t));
				text = map[username].s;
			end
			origin.send(st.reply(stanza):tag("query", {xmlns = "jabber:iq:last", seconds = seconds}):text(text));
		else
			origin.send(st.error_reply(stanza, "auth", "forbidden"));
		end
		return true;
	end
end);

module.save = function()
	return {map = map};
end
module.restore = function(data)
	map = data.map or {};
end
