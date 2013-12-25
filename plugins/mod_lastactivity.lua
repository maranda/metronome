-- * Metronome IM *
--
-- This file is part of the Metronome XMPP server and is released under the
-- ISC License, please see the LICENSE file in this source package for more
-- information about copyright and licensing.
--
-- As per the sublicensing clause, this file is also MIT/X11 Licensed.
-- ** Copyright (c) 2009-2010, Matthew Wild, Waqas Hussain

local st = require "util.stanza";
local is_contact_subscribed = require "util.rostermanager".is_contact_subscribed;
local jid_bare = require "util.jid".bare;
local jid_section = require "util.jid".section;
local dm_load = require "util.datamanager".load;
local dm_store = require "util.datamanager".store;
local module_host = module.host;

local os_difftime, os_time, tostring = os.difftime, os.time, tostring;

module:add_feature("jabber:iq:last");

module:hook("pre-presence/bare", function(event)
	local origin, stanza = event.origin, event.stanza;
	if not(stanza.attr.to) and stanza.attr.type == "unavailable" then
		local t = os_time();
		local s = stanza:child_with_name("status");
		s = s and #s.tags == 0 and s[1] or "";
		dm_store(origin.username, origin.host, "last_activity", { status = s, time = t });
	end
end, 10);

module:hook("iq/bare/jabber:iq:last:query", function(event)
	local origin, stanza = event.origin, event.stanza;
	if stanza.attr.type == "get" then
		local username = jid_section(stanza.attr.to, "node") or origin.username;
		if not stanza.attr.to or is_contact_subscribed(username, module_host, jid_bare(stanza.attr.from)) then
			local seconds, text, data = "0", "", dm_load(username, module_host, "last_activity");
			if data then
				seconds = tostring(os_difftime(os_time(), data.time));
				text = data.status;
			end
			origin.send(st.reply(stanza):tag("query", {xmlns = "jabber:iq:last", seconds = seconds}):text(text));
		else
			origin.send(st.error_reply(stanza, "auth", "forbidden"));
		end
		return true;
	end
end);