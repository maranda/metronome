-- * Metronome IM *
--
-- This file is part of the Metronome XMPP server and is released under the
-- ISC License, please see the LICENSE file in this source package for more
-- information about copyright and licensing.
--
-- This implements XEP-198: Stream Management,
-- The code is based on the module available for Prosody.

local ipairs, min, now, t_insert, t_remove, tonumber, tostring =
	ipairs, math.min, os.time, table.insert, table.remove, tonumber, tostring;
	
local st_clone, st_stanza, st_reply = 
	require "util.stanza".clone, require "util.stanza".stanza, require "util.stanza".reply;

local add_filter = require "util.filters".add_filter;
local add_timer = require "util.timer".add_timer;
local dt = require "util.datetime".datetime;
local destroy = sessionmanager.destroy_session;
local uuid = require "util.uuid".generate;

local process_stanza = metronome.core_process_stanza;

local xmlns_sm = "urn:xmpp:sm:3";
local xmlns_e = "urn:ietf:params:xml:ns:xmpp-stanzas";
local xmlns_d = "urn:xmpp:delay";

local timeout = module:get_option_number("sm_resume_timeout", 180);
local max_unacked = module:get_option_number("sm_max_unacked_stanzas", 0);

local handled_sessions = {};

local function verify(session)
	if session.sm then return false, "unexpected-request", "Already enabled"; end
	
	local session_type = session.type;
	if session_type == "c2s" and not session.resource then
		return false, "unexpected-request", "A resource must be bound to use Stream Management";
	elseif session_type == "s2sin" or session_type == "s2sout" then
		return true;
	end
	
	return false, "service-unavailable", "Stream Management not available for this session type";
end

local function replace_session(session, new)
	session.ip = new.ip;
	session.conn = new.conn;
	session.send = new.send;
	session.stream = new.stream;
	local filter = session.filter;
	local log = session.log;
	function session.data(data)
		data = filter("bytes/in", data);
		if data then
			local ok, err = stream:feed(data);
			if ok then return; end
			log("debug", "Received invalid XML (%s) %d bytes: %s", tostring(err), #data, data:sub(1, 300):gsub("[\r\n]+", " "):gsub("[%z\1-\31]", "_"));
			session:close("xml-not-well-formed");
		end
	end
end

local function wrap(session, _r) -- SM session wrapper
	local _q = (_r and session.sm_queue) or {};
	if not _r then
		session.sm_queue, session.sm_last_ack, session.sm_handled = _q, 0, 0;
		add_filter(session, "stanzas/in", function(stanza)
			if not stanza.attr.xmlns then
				session.sm_handled = session.sm_handled + 1;
				session.log("debug", "Handled incoming stanzas: %d", session.sm_handled);
			end
			return stanza;
		end);
	end
	
	local send = session.sends2s or session.send;
	local function new_send(stanza)
                local attr = stanza.attr;
                if attr and not attr.xmlns then
                        local cached = st_clone(stanza);
                        if not cached:get_child("delay", xmlns_d) then
                                cached = cached:tag("delay", { xmlns = xmlns_d, from = session.host, stamp = dt() });
                        end
                        t_insert(_q, cached);
                end
                if session.halted then return true; end
                local ok, err = send(stanza);
                if ok and #_q > max_unacked and not session.waiting_ack and attr and not attr.xmlns then
                        session.waiting_ack = true;
                        return send(st_stanza("r", { xmlns = xmlns_sm }));
                end
                return ok, err;
	end
	if session.sends2s then session.sends2s = new_send; else session.send = new_send; end
	
	local close = session.close;
	function session.close(...)
		local token = session.sm_token;
		if token then
			handled_sessions[token] = nil;
			session.sm_token = nil;
		end
		return close(...);
	end
	
	local function handle_unacked(session)
		local attr = { type = "cancel" };
		for _, queued in ipairs(_q) do
			local reply = st_reply(queued);
			if reply.attr.to ~= session.full_jid then
				reply.attr.type = "error";
				reply:tag("error", attr):tag("recipient-unavaible", { xmlns = xmlns_e });
				process_stanza(session, reply);
			end
		end
		_q, session.sm_queue = {}, {};
	end
	session.handle_unacked = handle_unacked;
	
	return session;
end

-- Features Handlers

module:hook("stream-features", function (event)
	local session = event.origin;
	if session.type == "c2s" and not session.sm then 
		event.features:tag("sm", sm_attr):tag("optional"):up():up(); 
	end
end);

module:hook("s2s-stream-features", function (event)
	local session = event.origin;
	if verify(event.origin) then 
		event.features:tag("sm", sm_attr):tag("optional"):up():up(); 
	end
end);

module:hook_stanza("http://etherx.jabber.org/streams", "features", function (session, stanza)
	if verify(session) and stanza:get_child("sm", xmlns_sm) then
		session.sends2s(st.stanza("enable", { xmlns = xmlns_sm }));
	end
end);

-- SM Handlers

module:hook_stanza("xmlns_sm", "enable", function(session, stanza)
	local ok, err, text = verify(session);
	if not ok then
                session.log("warn", "Failed to enable Stream Management reason is: %s", text);
                session.send(st.stanza("failed", { xmlns = xmlns_sm }));
                return true;
        end
	
	session.log("debug", "Attempting to enable Stream Management...");
	session.sm = true;
	wrap(session);
	
	local token;
	local resume = stanza.attr.resume;
	if resume == "1" or resume == "true" then
		token = uuid();
		handled_sessions[token], session.token = session, token;
	end
	return (session.sends2s or session.send)(st_stanza("enabled", { xmlns = xmlns_sm, id = token, resume = resume }));
end, 100);

module:hook_stanza(xmlns_sm, "enabled", function (session, stanza)
	local session_type = session.type;
	if session_type:find("s2s.*") then
		session.sm = true;
		wrap(session);
		return true;
	end
	-- TODO: Stream resumption for s2s streams.
end);

module:hook_stanza(xmlns_sm, "r", function(session, stanza)
	if session.sm then
		session.log("debug", "Received ack request for %d", session.sm_handled);
		return (session.sends2s or session.send)(st_stanza("a", { xmlns = xmlns_sm, h = tostring(origin.handled_stanza_count) }));
	end
end);

module:hook_stanza(xmlns_sm, "a", function(session, stanza)
	if session.sm then
		session.waiting_ack = nil;
		local _count = tonumber(stanza.attr.h) - session.sm_last_ack;
		local _q = session.sm_queue;
		
		if _count > #_q then module:log("warn", "Client says it handled %d stanzas, but only %d were sent", _count, #_q); end
		for i=1, min(_count, #_q) do t_remove(_q, 1); end
		session.sm_last_ack = session.sm_last_ack + _count;
		return true;
	end
end);

module:hook_stanza(xmlns_sm, "resume", function(session, stanza)
	if session.full_jid then
		session.log("warn", "Attempted to resume session after it bound a resource");
		session.send(st_stanza("failed", { xmlns = xmlns_sm }):tag("unexpexted-request", { xmlns = xmlns_e }));
		return true;
	end
	
	local id = stanza.attr.previd;
	local original = handled_sessions[id];
	local c2s_sessions = module:shared("/*/c2s/sessions");
	if not original then
		session.log("warn", "Attempted to resume unexistent session with id %s", id);
		session.send(st_stanza("failed", { xmlns = xmlns_sm }):tag("item-not-found", { xmlns = xmlns_e }));
	elseif session.host == original.host and session.username == original.username then
		session.log("debug", "Session is being resumed...");
		replace_session(original, session);
		wrap(original, true);
		session.stream:set_session(original);
		c2s_sessions[session.conn] = original;
		session.send(st_stanza("resumed", { xmlns = xmlns_sm, h = session.sm_handled, previd = id }));
		original:dispatch_stanza(st_stanza("a", { xmlns = xmlns_sm, h = stanza.attr.h }));
		
		-- Send all originally queued stanzas
		local _q = original.sm_queue;
		for _, queued in ipairs(_q) do session.send(queued); end
	else
		module:log("warn", "Client %s@%s[%s] tried to resume stream for %s@%s[%s]",
                        session.username or "?", session.host or "?", session.type,
			original.username or "?", original.host or "?", original.type);
		session.send(st_stanza("failed", { xmlns = xmlns_sm }):tag("not-authorized", { xmlns = xmlns_e }));
	end
	return true;
end);

module:hook("pre-resource-unbind", function(event)
	local session, _error = event.session, event.error;
	if session.sm then
		if session.token then
			session.log("debug", "Session is being halted for up to %d seconds", timeout);
			local _now, token = now(), session.token;
			session.halted = _now;
			add_timer(timeout, function()
				local current = full_sessions[session.full_jid];
				if session.destroyed then
					session.log("debug", "SM timeout was reached but the session is already gone");
				elseif current and (current.token == token and session.halted == _now) then
					session.log("debug", "Session has been halted too long, destroying");
					handled_sessions[token] = nil;
					session.token = nil;
					destroy(session);
				end
			end);
			return true;
		else
			local _q = session.sm_queue;
			if #_q > 0 then
				session.log("warn", "Session is being destroyed while it still has unacked stanzas");
				session:handle_unacked();
			end
		end
	end
end);