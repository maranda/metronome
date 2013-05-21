-- * Metronome IM *
--
-- This file is part of the Metronome XMPP server and is released under the
-- ISC License, please see the LICENSE file in this source package for more
-- information about copyright and licensing.
--
-- As per the sublicensing clause, this file is also MIT/X11 Licensed.
-- ** Copyright (c) 2010-2013, Kim Alvefur, Jeff Mitchell, Matthew Wild

local host = module:get_host();
local motd_text = module:get_option_string("motd_text");
local motd_jid = module:get_option_string("motd_jid", host);

if not motd_text then return; end

local jid_join = require "util.jid".join;
local st = require "util.stanza";

motd_text = motd_text:gsub("^%s*(.-)%s*$", "%1"):gsub("\n%s+", "\n"); -- Strip indentation from the config

module:hook("presence/bare", function (event)
		local session, stanza = event.origin, event.stanza;
		if not session.presence and not stanza.attr.type then
			local motd_stanza =
				st.message({ to = session.full_jid, from = motd_jid })
					:tag("body"):text(motd_text);
			module:send(motd_stanza);
			module:log("debug", "MOTD send to user %s", session.full_jid);
		end
end, 1);
