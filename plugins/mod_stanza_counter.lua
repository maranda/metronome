local jid_bare = require "util.jid".bare

-- Setup, Init functions.
-- initialize function counter table on the global object on start
local function init_counter()
	metronome.stanza_counter = { 
		iq = { incoming=0, outgoing=0 },
		message = { incoming=0, outgoing=0 },
		presence = { incoming=0, outgoing=0 }
	}
end

-- Setup on server start
local function setup() init_counter() end

-- Basic Stanzas' Counters
local function iq_callback(check)
	return function(self)
		local origin, stanza = self.origin, self.stanza
		if not metronome.stanza_counter then init_counter() end
		if check then
			if not stanza.attr.to or hosts[jid_bare(stanza.attr.to)] then return nil
			else
				metronome.stanza_counter.iq["outgoing"] = metronome.stanza_counter.iq["outgoing"] + 1
			end
		else
			metronome.stanza_counter.iq["incoming"] = metronome.stanza_counter.iq["incoming"] + 1
		end
	end
end

local function mes_callback(check)
	return function(self)
		local origin, stanza = self.origin, self.stanza
		if not metronome.stanza_counter then init_counter() end
		if check then
			if not stanza.attr.to or hosts[jid_bare(stanza.attr.to)] then return nil
			else
				metronome.stanza_counter.message["outgoing"] = metronome.stanza_counter.message["outgoing"] + 1
			end
		else
			metronome.stanza_counter.message["incoming"] = metronome.stanza_counter.message["incoming"] + 1
		end
	end
end

local function pre_callback(check)
	return function(self)
		local origin, stanza = self.origin, self.stanza
		if not metronome.stanza_counter then init_counter() end
		if check then
			if not stanza.attr.to or hosts[jid_bare(stanza.attr.to)] then return nil
			else
				metronome.stanza_counter.presence["outgoing"] = metronome.stanza_counter.presence["outgoing"] + 1
			end
		else
			metronome.stanza_counter.presence["incoming"] = metronome.stanza_counter.presence["incoming"] + 1
		end
	end
end

-- Hook all pre-stanza events.
module:hook("pre-iq/bare", iq_callback(true), 140)
module:hook("pre-iq/full", iq_callback(true), 140)
module:hook("pre-iq/host", iq_callback(true), 140)

module:hook("pre-message/bare", mes_callback(true), 140)
module:hook("pre-message/full", mes_callback(true), 140)
module:hook("pre-message/host", mes_callback(true), 140)

module:hook("pre-presence/bare", pre_callback(true), 140)
module:hook("pre-presence/full", pre_callback(true), 140)
module:hook("pre-presence/host", pre_callback(true), 140)

-- Hook all stanza events.
module:hook("iq/bare", iq_callback(false), 140)
module:hook("iq/full", iq_callback(false), 140)
module:hook("iq/host", iq_callback(false), 140)

module:hook("message/bare", mes_callback(false), 140)
module:hook("message/full", mes_callback(false), 140)
module:hook("message/host", mes_callback(false), 140)

module:hook("presence/bare", pre_callback(false), 140)
module:hook("presence/full", pre_callback(false), 140)
module:hook("presence/host", pre_callback(false), 140)

-- Hook server start to initialize the counter.
module:hook("server-started", setup)
