-- * Metronome IM *
--
-- This file is part of the Metronome XMPP server and is released under the
-- ISC License, please see the LICENSE file in this source package for more
-- information about copyright and licensing.
--
-- As per the sublicensing clause, this file is also MIT/X11 Licensed.
-- ** Copyright (c) 2009, Waqas Hussain

local st = require "util.stanza";

local result_query = st.stanza("query", {xmlns = "http://jabber.org/protocol/disco#items"});
for _, item in ipairs(module:get_option("disco_items") or {}) do
	result_query:tag("item", {jid = item[1], name = item[2]}):up();
end

module:hook("iq/host/http://jabber.org/protocol/disco#items:query", function(event)
	local stanza = event.stanza;
	local query = stanza.tags[1];
	if stanza.attr.type == "get" and not query.attr.node then
		event.origin.send(st.reply(stanza):add_child(result_query));
		return true;
	end
end, 100);
