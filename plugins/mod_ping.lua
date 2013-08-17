-- * Metronome IM *
--
-- This file is part of the Metronome XMPP server and is released under the
-- ISC License, please see the LICENSE file in this source package for more
-- information about copyright and licensing.

local st = require "util.stanza";

module:add_feature("urn:xmpp:ping");

module:hook("iq/bare/urn:xmpp:ping:ping", function(event)
	return event.origin.send(st.error_reply(event.stanza, "cancel", "service-unavailable"));
end);
module:hook("iq/host/urn:xmpp:ping:ping", function(event)
	local origin, stanza = event.origin, event.stanza;
	if stanza.attr.type == "get" then return origin.send(st.reply(stanza)); end
end);

-- Ad-hoc command

local datetime = require "util.datetime".datetime;

function ping_command_handler (self, data, state)
	local now = datetime();
	return { info = "Pong\n"..now, status = "completed" };
end

local adhoc_new = module:require "adhoc".new;
local descriptor = adhoc_new("Ping", "ping", ping_command_handler);
module:add_item ("adhoc", descriptor);

