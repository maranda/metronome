module:set_global()

local guard_blockall = module:get_option_set("host_guard_blockall", {})
local guard_ball_wl = module:get_option_set("host_guard_blockall_exceptions", {})
local guard_protect = module:get_option_set("host_guard_selective", {})
local guard_block_bl = module:get_option_set("host_guard_blacklist", {})
local guard_hexlist = module:get_option_set("host_guard_hexlist", {})

local config = configmanager
local error_reply = require "util.stanza".error_reply

local function s2s_hook (event)
	local origin, stanza = event.session or event.origin, event.stanza or false
	local to_host, from_host = (not stanza and origin.to_host) or stanza.attr.to, (not stanza and origin.from_host) or stanza.attr.from

	if origin.type == "s2sin" or origin.type == "s2sin_unauthed" then
	   if guard_hexlist:contains(from_host) then
		module:log("error", "remote hexed service %s attempted to access host %s", from_host, to_host)
		origin:close({condition = "policy-violation", text = "Your server is into LW.Org IM's HEX List and is therefore forbidden to access the service, please see http://www.lightwitch.org/im-service/hex-list for more info."})
		return false
	   end
	   if guard_blockall:contains(to_host) and not guard_ball_wl:contains(from_host) or
	      guard_block_bl:contains(from_host) and guard_protect:contains(to_host) then
                module:log("error", "remote service %s attempted to access restricted host %s", from_host, to_host)
                origin:close({condition = "policy-violation", text = "You're not authorized, good bye."})
                return false
           end
        end

	return nil
end

local function rr_hook (event)
	local from_host, to_host, send, stanza = event.from_host, event.to_host, (event.origin and event.origin.send) or function() end, event.stanza

	if guard_hexlist:contains(to_host) or (guard_blockall:contains(from_host) and not guard_ball_wl:contains(to_host)) or
	   (guard_block_bl:contains(to_host) and guard_protect:contains(from_host)) then
	     module:log("info", "attempted to connect to a filtered remote host %s", to_host)
	     if stanza.attr.type ~= "error" then send(error_reply(event.stanza, "cancel", "policy-violation", "Communicating with a filtered remote server is not allowed.")) end
	     return true
	end

	return nil
end

local function handle_activation (host, u)
	if hosts[host] and hosts[host].events and not hosts[host].modules["auth_anonymous"] then
		hosts[host].events.add_handler("s2sin-established", s2s_hook, 500)
		hosts[host].events.add_handler("route/remote", rr_hook, 500)
		hosts[host].events.add_handler("stanza/jabber:server:dialback:result", s2s_hook, 500)
               	if u then
			module:log ("debug", "updating or adding host protection for: "..host)
		else
			module:log ("debug", "adding host protection for: "..host)
		end
	end
end

local function handle_deactivation (host, u, i)
	if hosts[host] and hosts[host].events and not hosts[host].modules["auth_anonymous"] then
		hosts[host].events.remove_handler("s2sin-established", s2s_hook)
		hosts[host].events.remove_handler("route/remote", rr_hook)
		hosts[host].events.remove_handler("stanza/jabber:server:dialback:result", s2s_hook)
		-- Logging is suppressed if it's an update or module is initializing
               	if not u and not i then module:log ("debug", "removing host protection for: "..host) end
	end
end

local function init_hosts(u, i)
	for n in pairs(hosts) do
		handle_deactivation(n, u, i) ; handle_activation(n, u) 
	end
end

local function reload()
	module:log ("debug", "server configuration reloaded, rehashing plugin tables...")
	guard_blockall = module:get_option_set("host_guard_blockall", {})
	guard_ball_wl = module:get_option_set("host_guard_blockall_exceptions", {})
	guard_protect = module:get_option_set("host_guard_selective", {})
	guard_block_bl = module:get_option_set("host_guard_blacklist", {})

	init_hosts(true)
end

local function setup()
        module:log ("debug", "initializing host guard module...")
        module:hook ("host-activated", handle_activation)
        module:hook ("host-deactivated", handle_deactivation)
        module:hook ("config-reloaded", reload)

        init_hosts(false, true)
end

function module.unload()
	module:log ("debug", "removing host handlers as module is being unloaded...")
	for n in pairs(hosts) do
		hosts[n].events.remove_handler("s2sin-established", s2s_hook)
		hosts[n].events.remove_handler("route/remote", rr_hook)
		hosts[n].events.remove_handler("stanza/jabber:server:dialback:result", s2s_hook)
	end
end

if metronome.start_time then
	setup()
else
	module:hook ("server-started", setup)
end
