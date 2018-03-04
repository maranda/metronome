-- * Metronome IM *
--
-- This file is part of the Metronome XMPP server and is released under the
-- ISC License, please see the LICENSE file in this source package for more
-- information about copyright and licensing.

module:depends("s2s")
module:set_global()

local hosts = hosts
local incoming_s2s = metronome.incoming_s2s
local default_hexed_text = "Your server is into this service's HEX List and is therefore forbidden to access it."

local guard_blockall = module:get_option_set("host_guard_blockall", {})
local guard_ball_wl = module:get_option_set("host_guard_blockall_exceptions", {})
local guard_protect = module:get_option_set("host_guard_selective", {})
local guard_block_bl = module:get_option_set("host_guard_blacklist", {})
local guard_hexlist = module:get_option_set("host_guard_hexlist", {})
local guard_hexlist_text = module:get_option_string("host_guard_hexlist_text", default_hexed_text)

local error_reply = require "util.stanza".error_reply
local tostring = tostring

local function filter(origin, from_host, to_host)
	if not from_host or not to_host then return end

	if guard_hexlist:contains(from_host) then
		module:log("error", "remote hexed service %s attempted to access host %s", from_host, to_host)
		origin:close({condition = "policy-violation", text = guard_hexlist_text})
		return true
	elseif guard_blockall:contains(to_host) and not guard_ball_wl:contains(from_host) or
	       guard_block_bl:contains(from_host) and guard_protect:contains(to_host) then
		module:log("error", "remote service %s attempted to access restricted host %s", from_host, to_host)
		origin:close({condition = "policy-violation", text = "You're not authorized, good bye."})
		return true
	end

	return
end

local function rr_hook (event)
	local from_host, to_host, send, stanza = event.from_host, event.to_host, (event.origin and event.origin.send) or function() end, event.stanza

	if guard_hexlist:contains(to_host) or (guard_blockall:contains(from_host) and not guard_ball_wl:contains(to_host)) or
	   (guard_block_bl:contains(to_host) and guard_protect:contains(from_host)) then
	     module:log("info", "attempted to connect to a filtered remote host %s", to_host)
	     if stanza.attr.type ~= "error" then send(error_reply(event.stanza, "cancel", "policy-violation", "Communicating with a filtered remote server is not allowed.")) end
	     return true
	end

	return
end

function module.add_host(module)
	module:set_component_inheritable()

	local host = module.host
	if not host.anonymous then
		module:hook("route/remote", rr_hook, 500)
		module:hook("stanza/jabber:server:dialback:result", function(event)
			return filter(event.origin, event.stanza.attr.from, event.stanza.attr.to)
		end, 500)
	end
end

local function close_filtered()
	for _, host in pairs(hosts) do
		for name, session in pairs(host.s2sout) do
			if guard_hexlist:contains(session.to_host) or (guard_blockall:contains(session.host) and 
			   not guard_ball_wl:contains(session.to_host)) or (guard_block_bl:contains(session.to_host) and 
			   guard_protect:contains(session.host)) then
				module:log("info", "closing down s2s outgoing stream to filtered entity %s", tostring(session.to_host))
				session:close()
			end
		end
	end
	for session in pairs(incoming_s2s) do
		if session.to_host and session.from_host and guard_hexlist:contains(session.from_host) or 
		   (guard_blockall:contains(session.to_host) and not guard_ball_wl:contains(session.from_host) or
		   guard_block_bl:contains(session.from_host) and guard_protect:contains(session.to_host)) then
			module:log("info", "closing down s2s incoming stream from filtered entity %s", tostring(session.from_host))
			session:close()
		end
	end
end

local function reload()
	module:log("debug", "reloading filters configuration...")
	guard_blockall = module:get_option_set("host_guard_blockall", {})
	guard_ball_wl = module:get_option_set("host_guard_blockall_exceptions", {})
	guard_protect = module:get_option_set("host_guard_selective", {})
	guard_block_bl = module:get_option_set("host_guard_blacklist", {})
	guard_hexlist = module:get_option_set("host_guard_hexlist", {})
	guard_hexlist_text = module:get_option_string("host_guard_hexlist_text", default_hexed_text)

	close_filtered()
end

local function setup()
	module:log("debug", "initializing host guard module...")
	module:hook("config-reloaded", reload)
	module:hook("s2s-filter", filter)
end

if metronome.start_time then
	setup()
else
	module:hook("server-started", setup)
end
