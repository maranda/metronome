-- * Metronome IM *
--
-- This file is part of the Metronome XMPP server and is released under the
-- ISC License, please see the LICENSE file in this source package for more
-- information about copyright and licensing.

module:depends("s2s");

local st = require "util.stanza";
local add_filter = require "util.filters".add_filter;
local section = require "util.jid".prepped_section;
local tb = debug.traceback;
local fire_event = metronome.events.fire_event;

local tostring, set_mt, time = tostring, setmetatable, os.time;

local hosts = metronome.hosts;
local myself = module.host;
local xmlns = "urn:xmpp:bidi";
local xmlns_features = "urn:xmpp:features:bidi";

local outgoing = module:shared("outgoing-sessions");
local incoming = module:shared("incoming-sessions");
local verifying = module:shared("awaiting-verification");

local function handle_err(e) log("error", "Traceback[s2s]: %s: %s", tostring(e), tb()); end
local function handle_stanza(session, stanza)
        if stanza then
                return xpcall(function () return fire_event("route/process", session, stanza) end, handle_err);
        end
end

local function make_bidirectional(session)
	local from, to = session.from_host, session.to_host;
	if session.type == "s2sin" and verifying[from] ~= "outgoing" then
		local outgoing = hosts[session.to_host].s2sout[from]
		if outgoing then -- close stream possibly used for dialback
			outgoing:close();
		end

		session.bidirectional = true;
		incoming[from] = session;
		verifying[from] = nil;
		module:fire_event("bidi-established", { session = session, host = from, type = "incoming" });
	elseif session.type == "s2sout" and verifying[to] ~= "incoming" then
		local virtual = {
			type = "s2sin", direction = "incoming", bidirectional = true,
			to_host = from, from_host = to,	hosts = { [to] = { authed = true } }
		};
		set_mt(virtual, { __index = session });

		session.incoming_bidi = virtual;
		add_filter(session, "stanzas/in", function(stanza)
			local attr = stanza.attr;
			if attr.xmlns == nil then return stanza; end
			local host = section(attr.from, "host");
			if host ~= from then return stanza; end
			handle_stanza(virtual, stanza);
		end);

		outgoing[to] = virtual;	
		verifying[to] = nil;
		module:fire_event("bidi-established", { session = virtual, host = to, type = "outgoing" });	
	end
end

module:hook("route/remote", function(event)
	local from, to, stanza, multiplexed_from = event.from_host, event.to_host, event.stanza, event.multiplexed_from;
	if from == myself then
		local session = incoming[to];
		if session then
			session.last_receive = time();
			if multiplexed_from then session.multiplexed_from = multiplexed_from; end
			if session.sends2s(stanza) then return true; end
		end
	end
end, 101);

module:hook("s2s-stream-features", function(event)
	local session, features = event.origin, event.features;
	if not session.bidirectional and not session.incoming_bidi and 
	   verifying[session.from_host] ~= "outgoing" and not outgoing[session.from_host] then
		features:tag("bidi", { xmlns = xmlns_features }):up();
	end
end, 100);

module:hook_stanza("http://etherx.jabber.org/streams", "features", function(session, stanza) -- outgoing
        if session.type == "s2sout_unauthed" and stanza:get_child("bidi", xmlns_features) and
	   not incoming[session.to_host] and verifying[session.to_host] ~= "incoming" then
                module:log("debug", "Attempting to enable bidirectional s2s stream on %s...", session.to_host);
                session.sends2s(st.stanza("bidi", { xmlns = xmlns }));
                session.can_do_bidi = true;
		verifying[session.to_host] = "outgoing";
        end
end, 155);

module:hook("stanza/"..xmlns..":bidi", function(event) -- incoming
        local session = event.origin;
 	if not session.bidirectional or session.incoming_bidi then
                module:log("debug", "%s requested to enable a bidirectional s2s stream...", session.from_host);
                session.can_do_bidi = true;
		verifying[session.from_host] = "incoming";
                return true;
        end
end);

local function enable(event)
        local session = event.session;
        if not (session.bidirectional or session.incoming_bidi) and session.can_do_bidi then
                session.can_do_bidi = nil;
                make_bidirectional(session);
        end
end

local function disable(event)
	local session = event.session;
	local type = session.type;
	(type == "s2sin" and incoming or outgoing)[(type == "s2sin" and session.from_host) or session.to_host] = nil;	
end

module:hook("s2sin-established", enable);
module:hook("s2sin-destroyed", disable);
module:hook("s2sout-established", enable);
module:hook("s2sout-destroyed", disable);

function module.unload()
	-- cleanup and close connections
	for _, session in pairs(incoming) do session:close(); end
	for _, session in pairs(outgoing) do session:close(); end
end