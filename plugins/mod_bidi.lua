-- * Metronome IM *
--
-- This file is part of the Metronome XMPP server and is released under the
-- ISC License, please see the LICENSE file in this source package for more
-- information about copyright and licensing.

module:set_component_inheritable();
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

local exclude = module:get_option_set("bidi_exclusion_list", {});

local function handle_err(e) log("error", "Traceback[s2s]: %s: %s", tostring(e), tb()); end
local function handle_stanza(session, stanza)
	if stanza then
		return xpcall(function () return fire_event("route/process", session, stanza) end, handle_err);
	end
end

local function make_bidirectional(session)
	local from, to = session.from_host, session.to_host;
	if session.type == "s2sin" then
		local outgoing = hosts[session.to_host].s2sout[from];
		if outgoing and outgoing.close then -- close stream possibly used for dialback
			outgoing:close();
		end

		session.bidirectional = true;
		incoming[from] = session;
		verifying[from] = nil;
		module:fire_event("bidi-established", { session = session, host = from, type = "incoming" });
	elseif session.type == "s2sout" then
		local virtual = {
			type = "s2sin", direction = "incoming", bidirectional = true,
			to_host = from, from_host = to, hosts = { [to] = { authed = true } }
		};
		set_mt(virtual, { __index = session });
		
		session.send = function(stanza) return session.sends2s(stanza); end

		session.bidirectional = true;
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
		module:fire_event("bidi-established", { session = virtual, host = to, type = "outgoing", origin = session });
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
	local from = session.from_host;
	if from and not exclude:contains(from) and not session.bidirectional and
	   verifying[from] ~= "outgoing" and not outgoing[from] then
		features:tag("bidi", { xmlns = xmlns_features }):up();
	end
end, 100);

module:hook_stanza("http://etherx.jabber.org/streams", "features", function(session, stanza) -- outgoing
	local to = session.to_host;
        if session.type == "s2sout_unauthed" and stanza:get_child("bidi", xmlns_features) and
	   not exclude:contains(to) and not incoming[to] and verifying[to] ~= "incoming" then
		module:log("debug", "Attempting to enable bidirectional s2s stream on %s...", to);
		session.sends2s(st.stanza("bidi", { xmlns = xmlns }));
		session.can_do_bidi = true;
		verifying[to] = "outgoing";
	end
end, 155);

module:hook("stanza/"..xmlns..":bidi", function(event) -- incoming
	local session = event.origin;
	local from = session.from_host;
	if from and not exclude:contains(from) and not session.bidirectional and
	   not verifying[from] ~= "outgoing" then
		module:log("debug", "%s requested to enable a bidirectional s2s stream...", from);
		session.can_do_bidi = true;
		verifying[from] = "incoming";
		return true;
	end
end);

local function enable(event)
	local session = event.session;
	if not session.bidirectional and session.can_do_bidi then
		session.can_do_bidi = nil;
		make_bidirectional(session);
	end
end

local function disable(event)
	local session = event.session;
	if session.can_do_bidi or session.bidirectional then
		local type = session.type;
		local from, to = session.from_host, session.to_host;
		(type == "s2sin" and incoming or outgoing)[type == "s2sin" and from or to] = nil;	
		verifying[type == "s2sin" and from or to] = nil;
	end
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
