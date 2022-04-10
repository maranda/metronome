-- * Metronome IM *
--
-- This file is part of the Metronome XMPP server and is released under the
-- ISC License, please see the LICENSE file in this source package for more
-- information about copyright and licensing.
--
-- This implements XEP-198: Stream Management,
-- The code is based on the module available for Prosody.

module:set_component_inheritable();

local hosts = hosts;

local ipairs, min, now, pairs, t_insert, t_remove, tonumber, tostring =
	ipairs, math.min, os.time, pairs, table.insert, table.remove, tonumber, tostring;
	
local st_clone, st_stanza, st_reply = 
	require "util.stanza".clone, require "util.stanza".stanza, require "util.stanza".reply;

local add_filter = require "util.filters".add_filter;
local add_timer = require "util.timer".add_task;
local dt = require "util.datetime".datetime;
local destroy = require "core.sessionmanager".destroy_session;
local uuid = require "util.uuid".generate;

local fire_event = metronome.events.fire_event;

local xmlns_sm2 = "urn:xmpp:sm:2";
local xmlns_sm3 = "urn:xmpp:sm:3";
local xmlns_e = "urn:ietf:params:xml:ns:xmpp-stanzas";
local xmlns_d = "urn:xmpp:delay";

local timeout = module:get_option_number("sm_resume_timeout", 360);
local max_unacked = module:get_option_number("sm_max_unacked_stanzas", 10);
local max_queued_stanzas = module:get_option_number("sm_max_unacked_stanzas_limit", 15000);

local handled_sessions = {};

local function verify(session)
	if session.sm then return false, "unexpected-request", "Already enabled"; end
	
	local session_type = session.type;
	if session_type == "c2s" then
		if not session.resource then
			return false, "unexpected-request", "A resource must be bound to use Stream Management";
		else
			return true;
		end
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
	session.secure = new.secure;
	session.halted = nil;
	session.detached = nil;

	local filter = session.filter;
	local log = session.log;
	local stream = session.stream;
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

local function check_carbons(session)
	local bare_jid, resource = session.username.."@"..session.host, session.resource;
	local bare_session, has_carbons = module:get_bare_session(bare_jid);
	if bare_session.has_carbons then
		for _resource, _session in pairs(bare_session.sessions) do
			if _resource ~= resource and _session.carbons then has_carbons = true; break; end
		end
	end
	return has_carbons;
end

local function wrap(session, _r, xmlns_sm) -- SM session wrapper
	local _q = (_r and session.sm_queue) or {};
	if not _r then
		session.sm_queue, session.sm_last_ack, session.sm_last_req, session.sm_handled = _q, 0, 0, 0;
		local session_type = session.type;
		add_filter(session, (session_type == "s2sout" and "stanzas/out") or "stanzas/in", function(stanza)
			local name = stanza.name;
			if name == "iq" or name == "message" or name == "presence" then
				session.sm_handled = session.sm_handled + 1;
				session.log("debug", "Handled %s stanzas: %d", 
					(session_type == "s2sout" and "outgoing") or "incoming", session.sm_handled);
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
		if #_q > max_queued_stanzas then
			local has_carbons = session.type == "c2s" and check_carbons(session);
			local queued = _q[1];
			module:log("warn", "%s session queue is over limit (%d stanzas), dropping oldest: %s",
				(_type == "s2sin" or _type == "s2sout") and "Remote server" or "Client", #_q, queued:top_tag());
			if session.type == "c2s" and (queued.name == "iq" or queued.name == "message" or queued.name == "presence") 
				and queued.attr.type ~= "error" then
				local reply = st_reply(queued);
				if reply.attr.to and reply.attr.to ~= session.full_jid and (has_carbons and name ~= "message" or not has_carbons) then
					reply.attr.type = "error";
					reply:tag("error", { type = "cancel" }):tag("recipient-unavailable", { xmlns = xmlns_e });
					fire_event("route/process", session, reply);
				end					
			end
			t_remove(_q, 1);
		end
		if session.type == "c2s" and stanza.name == "message" and #_q > 0 and (session.waiting_ack or session.halted) then
			module:fire_event("sm-push-message", { username = session.username, host = session.host, stanza = stanza });
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
		local token = session.token;
		if token then
			handled_sessions[token] = nil;
			session.token = nil;
		end
		return close(...);
	end
	
	function session.handle_unacked(session)
		if session.type == "c2s" then
			has_carbons = check_carbons(session);
			for _, queued in ipairs(_q) do
				local name = queued.name;
				if (name == "iq" or name == "message" or name == "presence") and queued.attr.type ~= "error" then
					local reply = st_reply(queued);
					if reply.attr.to and reply.attr.to ~= session.full_jid and (has_carbons and name ~= "message" or not has_carbons) then
						reply.attr.type = "error";
						reply:tag("error", { type = "cancel" }):tag("recipient-unavailable", { xmlns = xmlns_e });
						fire_event("route/process", session, reply);
					end
				end
			end
		elseif session.type == "s2sout" or session.bidirectional then
			local host_session = session.direction == "outgoing" and hosts[session.from_host] or hosts[session.to_host];
			for _, queued in ipairs(_q) do
				local name = queued.name;
				if (name == "iq" or name == "message" or name == "presence") and queued.attr.type ~= "error" then
					local reply = st_reply(queued);
					reply.attr.type = "error";
					reply:tag("error", { type = "cancel" }):tag("recipient-unavailable", { xmlns = xmlns_e });
					fire_event("route/local", host_session, reply);
				end
			end
		end
		_q, session.sm_queue = {}, {};
	end
	
	module:fire_event(session.type .. "-sm-enabled", session);
	return session;
end

-- Features Handlers

module:hook("stream-features", function(event)
	local session = event.origin;
	if session.type == "c2s" and not session.sm then
		event.features:tag("sm", { xmlns = xmlns_sm2 }):up();
		event.features:tag("sm", { xmlns = xmlns_sm3 }):up();
	end
end, 97);

module:hook("s2s-stream-features", function(event)
	local session = event.origin;
	if not session.sm then
		event.features:tag("sm", { xmlns = xmlns_sm2 }):up();
		event.features:tag("sm", { xmlns = xmlns_sm3 }):up();
	end
end, 97);

module:hook_stanza("http://etherx.jabber.org/streams", "features", function(session, stanza)
	local session_type = session.type;
	local version = (stanza:get_child("sm", xmlns_sm3) and 3) or (stanza:get_child("sm", xmlns_sm2) and 2);
	if not session.can_do_sm and 
	   (session_type == "s2sout_unauthed" or session_type == "s2sout") and version then
		session.can_do_sm = true;
		session.sm_version = version;
	end
end, 501);

module:hook("s2sout-established", function(event)
	local session = event.session
	if session.can_do_sm then
		session.log("debug", "Attempting to enable Stanza Acknowledgement on s2sout...");
		session.sends2s(st_stanza("enable", { xmlns = session.sm_version == 3 and xmlns_sm3 or xmlns_sm2 }));
	end
end);

-- SM Handlers

local function enable_handler(session, stanza)
	local ok, err, text = verify(session);
	if not ok then
		session.log("warn", "Failed to enable Stream Management reason is: %s", text);
		(session.sends2s or session.send)(st_stanza("failed", { xmlns = stanza.attr.xmlns }));
		return true;
	end
	
	local c2s = session.type == "c2s" and true;
	local xmlns_sm = stanza.attr.xmlns;
	session.log("debug", "Attempting to enable %s...", (c2s and "Stream Management") or "Stanza Acknowledgement");
	session.sm = true;
	wrap(session, nil, xmlns_sm);
	
	local token;
	local resume = stanza.attr.resume;
	if (resume == "1" or resume == "true") and c2s then
		token = uuid();
		handled_sessions[token], session.token = session, token;
	end
	local max;
	if c2s and stanza.attr.max then
		max = tonumber(stanza.attr.max);
		if max > timeout then max = timeout; else session.sm_timeout = max < timeout and max or nil; end
	end
	(session.sends2s or session.send)(
		st_stanza("enabled", { xmlns = xmlns_sm, id = token, max = c2s and tostring(max or timeout) or nil, resume = c2s and resume or nil })
	);
	return true;
end
module:hook_stanza(xmlns_sm2, "enable", enable_handler, 100);
module:hook_stanza(xmlns_sm3, "enable", enable_handler, 100);

local function enabled_handler(session, stanza)
	local session_type = session.type;
	if session_type == "s2sin" or session_type == "s2sout" then
		session.sm = true;
		wrap(session, nil, stanza.attr.xmlns);
	end
	return true;
end
module:hook_stanza(xmlns_sm2, "enabled", enabled_handler);
module:hook_stanza(xmlns_sm3, "enabled", enabled_handler);

local function req_handler(session, stanza)
	if session.sm then
		session.sm_last_req = session.sm_handled;
		session.log("debug", "Received ack request for %d", session.sm_handled);
		(session.sends2s or session.send)(st_stanza("a", { xmlns = stanza.attr.xmlns, h = tostring(session.sm_handled) }));
	end
	return true;
end
module:hook_stanza(xmlns_sm2, "r", req_handler);
module:hook_stanza(xmlns_sm3, "r", req_handler);

local function ack_handler(session, stanza)
	if session.sm then
		session.waiting_ack = nil;
		local _count = tonumber(stanza.attr.h) - session.sm_last_ack;
		local _q = session.sm_queue;
		local _type = session.type;
		
		if _count > #_q then
			module:log("warn", "%s says it handled %d stanzas, but only %d were sent", 
				(_type == "s2sin" or _type == "s2sout") and "Remote server" or "Client", _count, #_q); 
		end
		for i=1, min(_count, #_q) do t_remove(_q, 1); end
		session.sm_last_ack = session.sm_last_ack + _count;
	end
	return true;
end
module:hook_stanza(xmlns_sm2, "a", ack_handler);
module:hook_stanza(xmlns_sm3, "a", ack_handler);

local function resume_handler(session, stanza)
	local xmlns_sm = stanza.attr.xmlns;
	local _type = session.type;
	if _type == "s2sin" or _type == "s2sout" then
		-- properly bounce resumption requests for s2s streams
		return session.sends2s(st_stanza("failed", { xmlns = xmlns_sm }):tag("service-unavailable", { xmlns = xmlns_e }));
	elseif _type ~= "c2s" then
		-- bounce all the unauthed ones
		return (session.sends2s or session.send)(st_stanza("failed", { xmlns = xmlns_sm }):tag("unexpected-request", { xmlns = xmlns_e }));
	end

	if session.full_jid then
		session.log("warn", "Attempted to resume session after it bound a resource");
		session.send(st_stanza("failed", { xmlns = xmlns_sm }):tag("unexpected-request", { xmlns = xmlns_e }));
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
		if original.conn then
			local conn = original.conn;
			c2s_sessions[conn] = nil;
			conn:close();
			session.log("debug", "Closed the old session's connection...");
		end
		replace_session(original, session);
		wrap(original, true, xmlns_sm);
		session.stream:set_session(original);
		c2s_sessions[session.conn] = original;
		session.send(st_stanza("resumed", { xmlns = xmlns_sm, h = original.sm_handled, previd = id }));
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
end
module:hook_stanza(xmlns_sm2, "resume", resume_handler);
module:hook_stanza(xmlns_sm3, "resume", resume_handler);

module:hook("pre-resource-unbind", function(event)
	local session = event.session;
	if session.sm then
		if session.token then
			session.log("debug", "Session is being halted for up to %d seconds", timeout);
			local _now, token = now(), session.token;
			session.halted, session.detached = _now, true;
			module:fire_event("sm-process-queue", { username = session.username, host = session.host, queue = session.sm_queue });
			add_timer(session.sm_timeout or timeout, function()
				local current = module:get_full_session(session.username, session.resource);
				if not session.destroyed and current and (current.token == token and session.halted == _now) then
					session.log("debug", "%s session has been halted too long, destroying", session.full_jid);
					handled_sessions[token] = nil;
					session.token = nil;
					destroy(session);
				end
			end, module.name, module.host);
			return true;
		else
			if #session.sm_queue > 0 then
				session.log("warn", "Session is being destroyed while it still has unacked stanzas");
				session:handle_unacked();
			end
		end
	end
end, 10);

local function handle_s2s_preclose(event)
	local session = event.session;
	if session.sm and session.sm_handled > session.sm_last_req then
		session.log("debug", "Sending ack before closing for %d, as we handled more stanzas", session.sm_handled);
		session.sends2s(st_stanza("a", { xmlns = session.sm_version == 3 and xmlns_sm3 or xmlns_sm2, h = tostring(session.sm_handled) }));
	end
end
module:hook("s2sin-pre-destroy", handle_s2s_preclose, 10);
module:hook("s2sout-pre-destroy", handle_s2s_preclose, 10);

local function handle_s2s_unacked(event)
	local session = event.session;
	if (session.type == "s2sout" or session.bidirectional) and not session.graceful_close and session.sm and #session.sm_queue > 0 then
		session.log("warn", "Session is being destroyed while it still has unacked stanzas");
		session:handle_unacked();
	end
end
module:hook("s2sin-destroyed", handle_s2s_unacked, 10);
module:hook("s2sout-destroyed", handle_s2s_unacked, 10);

-- Module Methods

function module.save()
	return { handled_sessions = handled_sessions };
end

function module.restore(data)
	handled_sessions = data.handled_sessions or {};
end

function module.unload(reload)
	if not reload then
		local incoming_s2s = metronome.incoming_s2s;
		for _, session in module:get_full_sessions() do
			if session.sm then session:close(); end
		end
		for session in pairs(incoming_s2s) do
			if session.to_host == module.host and session.sm then session:close(); end
		end
		for _, session in pairs(module:get_host_session().s2sout) do
			if session.sm and session.close then session:close(); end
		end
		module:remove_all_timers();
	end
end
