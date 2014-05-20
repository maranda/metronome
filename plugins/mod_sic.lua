-- * Metronome IM *
--
-- This file is part of the Metronome XMPP server and is released under the
-- ISC License, please see the LICENSE file in this source package for more
-- information about copyright and licensing.

local st_reply = require "util.stanza".reply;
local tostring = tostring;
local xmlns = "urn:xmpp:sic:1";
local attr = { xmlns = xmlns };

module:add_feature(xmlns);

module:hook("iq-get/self/"..xmlns..":address", function(event)
	local origin, stanza = event.origin, event.stanza;
	local ip = origin.conn:ip();
	local port = origin.conn:port();
	local reply = st_reply(stanza):tag("address", attr);
	reply:tag("ip"):text(ip):up();
	if port then reply:tag("port"):text(tostring(port)):up(); end
	return origin.send(reply);
end);
