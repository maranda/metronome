-- * Metronome IM *
--
-- This file is part of the Metronome XMPP server and is released under the
-- ISC License, please see the LICENSE file in this source package for more
-- information about copyright and licensing.
--
-- As per the sublicensing clause, this file is also MIT/X11 Licensed.
-- ** Copyright (c) 2008-2013, Florian Zeitz, Kim Alvefur, Marco Cirillo, Matthew Wild, Waqas Hussain

local hosts = hosts;
local next, tostring, pairs, ipairs, getmetatable, setmetatable
    = next, tostring, pairs, ipairs, getmetatable, setmetatable;

local fire_event = metronome.events.fire_event;
local logger_init = require "util.logger".init;

local log = logger_init("s2smanager");

local config = require "core.configmanager";

local metronome = _G.metronome;
local incoming_s2s = metronome.incoming_s2s;

module "s2smanager"

function new_incoming(conn)
	local session = { conn = conn, type = "s2sin_unauthed", direction = "incoming", hosts = {} };
	session.log = logger_init("s2sin"..tostring(conn):match("[a-f0-9]+$"));
	incoming_s2s[session] = true;
	return session;
end

function new_outgoing(from_host, to_host, connect)
	local host_session = { to_host = to_host, from_host = from_host, host = from_host,
		               notopen = true, type = "s2sout_unauthed", direction = "outgoing" };
	hosts[from_host].s2sout[to_host] = host_session;
	local conn_name = "s2sout"..tostring(host_session):match("[a-f0-9]*$");
	host_session.log = logger_init(conn_name);
	return host_session;
end

local function incoming_has_hosts(session, host)
	local _hosts = session.hosts;
	if not _hosts[host] then
		_hosts[host] = {};
	elseif next(_hosts) then
		session.multiplexed_stream = true;
	end
end

function make_authenticated(session, host)
	if session.type == "s2sout_unauthed" then
		session.type = "s2sout";
	elseif session.type == "s2sin_unauthed" then
		session.type = "s2sin";
		if host then
			incoming_has_hosts(session, host);
			session.hosts[host].authed = true;
		end
	elseif session.type == "s2sin" and host then
		incoming_has_hosts(session, host);
		session.hosts[host].authed = true;
	else
		return false;
	end

	local direction, from, to = session.direction, session.from_host, session.to_host;
	local ctx;
	if direction == "incoming" and hosts[to] then
		ctx = hosts[to].ssl_ctx_in;
	elseif hosts[from] then
		ctx = hosts[from].ssl_ctx;
	end
	local authed = hosts[direction == "incoming" and to or from].events.fire_event("s2s-authenticated", {
		session = session,
		direction = direction,
		ctx = ctx,
		from = from, to = to
	});
	if not authed then return false; end
	
	session.log("debug", "connection %s->%s is now authenticated for %s", session.from_host, session.to_host, host);
	mark_connected(session);
	return true;
end

function mark_connected(session)
	local sendq, send = session.sendq, session.sends2s;
	
	local from, to = session.from_host, session.to_host;
	
	session.log("info", "%s s2s connection %s->%s complete", session.direction, from, to);

	local event_data = { session = session };
	if session.type == "s2sout" then
		metronome.events.fire_event("s2sout-established", event_data);
		hosts[from].events.fire_event("s2sout-established", event_data);
	else
		local host_session = hosts[to];
		session.send = function(stanza)
			return host_session.events.fire_event("route/remote", { from_host = to, to_host = from, stanza = stanza });
		end;

		metronome.events.fire_event("s2sin-established", event_data);
		hosts[to].events.fire_event("s2sin-established", event_data);
	end
	
	if session.direction == "outgoing" then
		if sendq then
			session.log("debug", "sending %d queued stanzas across new outgoing connection to %s", #sendq, session.to_host);
			for i, data in ipairs(sendq) do
				send(data[1]);
				sendq[i] = nil;
			end
			session.sendq = nil;
		end
		
		session.ip_hosts = nil;
		session.srv_hosts = nil;
	end
end

local resting_session = { -- Resting, not dead
		destroyed = true;
		type = "s2s_destroyed";
		open_stream = function (session)
			session.log("debug", "Attempt to open stream on resting session");
		end;
		close = function (session)
			session.log("debug", "Attempt to close already-closed session");
		end;
		filter = function (type, data) return data; end;
	}; resting_session.__index = resting_session;

function retire_session(session, reason)
	local log = session.log or log;
	for k in pairs(session) do
		if k ~= "log" and k ~= "id" and k ~= "conn" and k ~= "from_host" and k ~= "to_host" then
			session[k] = nil;
		end
	end

	session.destruction_reason = reason;

	function session.send(data) log("debug", "Discarding data sent to resting session: %s", tostring(data)); end
	function session.data(data) log("debug", "Discarding data received from resting session: %s", tostring(data)); end
	return setmetatable(session, resting_session);
end

function destroy_session(session, reason)
	if session.destroyed then return; end
	(session.log or log)("debug", "Destroying "..tostring(session.direction).." session "..tostring(session.from_host).."->"..tostring(session.to_host)..(reason and (": "..reason) or ""));
	
	if session.direction == "outgoing" then
		hosts[session.from_host].s2sout[session.to_host] = nil;
		session:bounce_sendq(reason);
	elseif session.direction == "incoming" then
		incoming_s2s[session] = nil;
	end
	
	local event_data = { session = session, reason = reason };
	if session.type == "s2sout" then
		metronome.events.fire_event("s2sout-destroyed", event_data);
		if hosts[session.from_host] then
			hosts[session.from_host].events.fire_event("s2sout-destroyed", event_data);
		end
	elseif session.type == "s2sin" then
		metronome.events.fire_event("s2sin-destroyed", event_data);
		if hosts[session.to_host] then
			hosts[session.to_host].events.fire_event("s2sin-destroyed", event_data);
		end
	end
	
	retire_session(session, reason); -- Clean session until it is GC'd
	return true;
end

return _M;
