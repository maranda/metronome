-- * Metronome IM *
--
-- This file is part of the Metronome XMPP server and is released under the
-- ISC License, please see the LICENSE file in this source package for more
-- information about copyright and licensing.

module:depends("s2s");
module:set_global();

local hosts = hosts;
local incoming_s2s = metronome.incoming_s2s;
local set_new = require "util.set".new;
local now, pairs, section = os.time, pairs, require "util.jid".section;

local guard_blacklist = module:get_option_set("gate_blacklist", {});
local guard_protect = module:get_option_set("gate_protect", {});
local guard_whitelist = module:get_option_set("gate_whitelist", {});
local guard_expire = module:get_option_number("gate_expiretime", 172800);
local guard_max_hits = module:get_option_number("gate_max_hits", 50);
local guard_banned = {};
local guard_banned_filtered = {};
local guard_hits = {};

local error_reply = require "util.stanza".error_reply;
local tostring = tostring;

local function clean_filtered(from)
	for ip, host in pairs(guard_banned_filtered) do
		if host == from then guard_banned_filtered[ip] = nil; end
	end
end

local function filter(origin, from_host, to_host)
	if not from_host or not to_host then return; end

	if guard_blacklist:contains(from_host) or guard_protect:contains(to_host) and not guard_whitelist:contains(from_host) then
		module:log("info", "remote service %s is by configuration blocked from accessing host %s", from_host, to_host);
		origin.blocked = true;
		return;
	end

	if guard_banned[from_host] then
		local banned = guard_banned[from_host];
		if now() >= banned.expire then
			guard_banned[from_host] = nil;
			clean_filtered(from_host);
		else
			module:log("info", "remote banned service %s (%s) is blocked from accessing host %s", from_host, banned.reason, to_host);
			guard_banned_filtered[origin.conn:ip()] = from_host;
			origin.blocked = true;
			return;
		end
	end
end

local function rr_hook(event)
	local from_host, to_host, send, stanza = 
		event.from_host, event.to_host, (event.origin and event.origin.send) or function() return true; end, event.stanza;
	local banned = guard_banned[to_host];

	if guard_blacklist:contains(to_host) or banned then
		if banned and now() >= banned.expire then
			guard_banned[to_host] = nil;
			clean_filtered(to_host);
			return;
		end
		module:log("info", "%s attempted to connect to a blocked remote host %s", stanza.attr.from or event.origin.full_jid, to_host);
		if stanza.attr.type ~= "error" then
			send(error_reply(event.stanza, "cancel", "policy-violation", "Communicating with a blocked remote server is not allowed."));
		end
		return true;
	end

	return;
end

local function filtered_handler(event)
	local ip, conn = event.ip, event.conn;

	if guard_banned_filtered[ip] then
		local host = guard_banned_filtered[ip];
		local banned = guard_banned[host];
		if now() >= banned.expire then
			guard_banned[host] = nil;
			clean_filtered(host);
			return;
		end
		module:log("info", "%s (%s) attempted connecting... blocking", host, ip);
		conn:close();
		return true;
	end
end

module:hook("s2s-new-incoming-connection", filtered_handler);
module:hook("gate-guard-banned", function() return guard_banned; end);
module:hook("gate-guard-hits", function() return guard_hits; end);

function module.add_host(module)
	module:set_component_inheritable();

	local host = module.host;
	if not host.anonymous then
		module:hook("route/remote", rr_hook, 500);
		module:hook("stanza/jabber:server:dialback:result", function(event)
			return filter(event.origin, event.stanza.attr.from, event.stanza.attr.to);
		end, 500);
		module:hook("stanza/urn:ietf:params:xml:ns:xmpp-sasl:auth", function(event)
			return filter(event.origin, event.origin.from_host, event.origin.to_host);
		end, 500);
	end

	module:hook("call-gate-guard", function(event)
		local from, reason, ban_time = event.from, event.reason, event.ban_time;
		local host = section(from, "host");

		if not guard_banned[host] then
			if guard_hits[host] then
				guard_hits[host] = guard_hits[host] + 1;
				module:log("debug", "%s triggered gate guard, reason: %s - hits: %d", from, reason, guard_hits[host]);
				if guard_hits[host] >= guard_max_hits then
					module:log("info", "%s exceeded number of offenses, closing streams and banning for %d seconds (%s)", 
						host, ban_time or guard_expire, reason);
					guard_hits[host] = nil;
					guard_banned[host] = { expire = now() + ban_time or guard_expire, reason = reason };
					for i, _host in pairs(hosts) do
						for name, session in pairs(_host.s2sout) do
							if name == host then session:close(); end
						end
					end
					for session in pairs(incoming_s2s) do
						if session.from_host == host then session:close(); end
					end
				end
			else
				module:log("debug", "%s triggered gate guard, reason: %s - creating record for %s", from, reason, host);
				guard_hits[host] = 1;
			end
		end
	end);
end

local function close_filtered()
	for _, host in pairs(hosts) do
		for name, session in pairs(host.s2sout) do
			if guard_blacklist:contains(name) or guard_protect:contains(session.from_host) and not guard_whitelist:contains(name) then
				module:log("info", "closing down unallowed s2s outgoing stream to entity %s", name);
				session:close();
			end
		end
	end
	for session in pairs(incoming_s2s) do
		if (session.to_host and session.from_host) and 
			guard_blacklist:contains(session.from_host) or
			guard_protect:contains(session.to_host) and not guard_whitelist:contains(session.from_host) then
			module:log("info", "closing down unallowed s2s incoming stream from entity %s", session.from_host);
			session:close();
		end
	end
end

local function reload()
	module:log("debug", "reloading configuration...")
	guard_blacklist = module:get_option_set("gate_blacklist", {});
	guard_protect = module:get_option_set("gate_protect", {});
	guard_whitelist = module:get_option_set("gate_whitelist", {});
	guard_expire = module:get_option_number("gate_expiretime", 172800);
	guard_max_hits = module:get_option_number("gate_max_hits", 50);

	close_filtered();
end

local function setup()
	module:log("debug", "initializing Metronome's gate guard...");
	module:hook("config-reloaded", reload);
end

module.save = function() return { guard_banned = guard_banned, guard_hits = guard_hits }; end
module.restore = function(data) guard_banned, guard_hits = data.guard_banned or {}, data.guard_hits or {}; end

if metronome.start_time then
	setup();
else
	module:hook("server-started", setup);
end
