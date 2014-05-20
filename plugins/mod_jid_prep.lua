-- * Metronome IM *
--
-- This file is part of the Metronome XMPP server and is released under the
-- ISC License, please see the LICENSE file in this source package for more
-- information about copyright and licensing.

local st_reply = require "util.stanza".reply;
local jid_prep = require "util.jid".prep;
local xmlns = "urn:xmpp:jidprep:0";

module:add_feature(xmlns);

module:hook("iq-get/self/"..xmlns..":jid", function(event)
	local origin, stanza = event.origin, event.stanza;
	local jid = stanza:get_child_text("jid", xmlns);
	local prepped_jid = jid_prep(jid);
	if prepped_jid then
		return st_reply(stanza):tag("jid", xmlns):text(jid);
	else
		local reply = st_reply(stanza):tag("jid", xmlns):text(jid):up();
		reply:tag("error", { type = "modify" }):tag("jid-malformed", "urn:ietf:params:xml:ns:xmpp-stanzas"):up():up();
		reply.attr.type = "error";
		return reply;
	end
end);
