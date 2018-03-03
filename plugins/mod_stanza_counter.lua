-- * Metronome IM *
--
-- This file is part of the Metronome XMPP server and is released under the
-- ISC License, please see the LICENSE file in this source package for more
-- information about copyright and licensing.

module:set_global()

local jid_bare = require "util.jid".bare

-- Setup, Init functions.
-- initialize function counter table on the global object on start
function init_counter()
	metronome.stanza_counter = { 
		iq = { incoming = 0, outgoing = 0 },
		message = { incoming = 0, outgoing = 0 },
		presence = { incoming = 0, outgoing = 0 }
	}
end

-- Basic Stanzas' Counters
local function callback(check)
	return function(self)
		local name = self.stanza.name
		if not metronome.stanza_counter then init_counter() end
		if check then
			metronome.stanza_counter[name].outgoing = metronome.stanza_counter[name].outgoing + 1
		else
			metronome.stanza_counter[name].incoming = metronome.stanza_counter[name].incoming + 1
		end
	end
end

function module.add_host(module)
	-- Hook all pre-stanza events.
	module:hook("pre-iq/bare", callback(true), 999)
	module:hook("pre-iq/full", callback(true), 999)
	module:hook("pre-iq/host", callback(true), 999)

	module:hook("pre-message/bare", callback(true), 999)
	module:hook("pre-message/full", callback(true), 999)
	module:hook("pre-message/host", callback(true), 999)

	module:hook("pre-presence/bare", callback(true), 999)
	module:hook("pre-presence/full", callback(true), 999)
	module:hook("pre-presence/host", callback(true), 999)

	-- Hook all stanza events.
	module:hook("iq/bare", callback(false), 999)
	module:hook("iq/full", callback(false), 999)
	module:hook("iq/host", callback(false), 999)

	module:hook("message/bare", callback(false), 999)
	module:hook("message/full", callback(false), 999)
	module:hook("message/host", callback(false), 999)

	module:hook("presence/bare", callback(false), 999)
	module:hook("presence/full", callback(false), 999)
	module:hook("presence/host", callback(false), 999)
end

-- Set up!
module:hook("server-started", init_counter);
