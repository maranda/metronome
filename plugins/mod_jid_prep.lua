-- * Metronome IM *
--
-- This file is part of the Metronome XMPP server and is released under the
-- ISC License, please see the LICENSE file in this source package for more
-- information about copyright and licensing.

local st_reply = require "util.stanza".reply;
local st_error_reply = require "util.stanza".error_reply;
local jid_prep = require "util.jid".prep;
local xmlns = "urn:xmpp:jidprep:0";
local attr = { xmlns = xmlns };

module:add_feature(xmlns);

module:hook("iq-get/host/"..xmlns..":jid", function(event)
	local origin, stanza = event.origin, event.stanza;
	if origin.type ~= "c2s" then return origin.send(st_error_reply(stanza, "cancel", "forbidden")); end

	local jid = stanza:get_child_text("jid", xmlns);
	local prepped_jid = jid_prep(jid);
	if prepped_jid then
		return origin.send(st_reply(stanza):tag("jid", attr):text(prepped_jid));
	else
		local reply = st_reply(stanza):tag("jid", attr):text(jid):up();
		reply:tag("error", { type = "modify" })
			:tag("jid-malformed", { xmlns = "urn:ietf:params:xml:ns:xmpp-stanzas" }):up():up();
		reply.attr.type = "error";
		return origin.send(reply);
	end
end);
