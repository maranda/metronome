-- * Metronome IM *
--
-- This file is part of the Metronome XMPP server and is released under the
-- ISC License, please see the LICENSE file in this source package for more
-- information about copyright and licensing.
--
-- As per the sublicensing clause, this file is also MIT/X11 Licensed.
-- ** Copyright (c) 2008-2010, Matthew Wild, Waqas Hussain

local st = require "util.stanza";
local datetime = require "util.datetime".datetime;

-- XEP-0202: Entity Time

module:add_feature("urn:xmpp:time");

local function time_handler(event)
	local origin, stanza = event.origin, event.stanza;
	if stanza.attr.type == "get" then
		origin.send(st.reply(stanza):tag("time", {xmlns = "urn:xmpp:time"})
			:tag("tzo"):text("+00:00"):up() -- TODO get the timezone in a platform independent fashion
			:tag("utc"):text(datetime()));
		return true;
	end
end

module:hook("iq/bare/urn:xmpp:time:time", time_handler);
module:hook("iq/host/urn:xmpp:time:time", time_handler);
