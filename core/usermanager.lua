-- * Metronome IM *
--
-- This file is part of the Metronome XMPP server and is released under the
-- ISC License, please see the LICENSE file in this source package for more
-- information about copyright and licensing.
--
-- As per the sublicensing clause, this file is also MIT/X11 Licensed.
-- ** Copyright (c) 2008-2013, Kim Alvefur, Jeff Mitchell, Matthew Wild, Waqas Hussain

local modulemanager = require "core.modulemanager";
local log = require "util.logger".init("usermanager");
local type = type;
local ipairs = ipairs;
local jid_bare = require "util.jid".bare;
local jid_join = require "util.jid".join;
local jid_prep = require "util.jid".prep;
local config = require "core.configmanager";
local hosts = hosts;
local sasl_new = require "util.sasl".new;
local storagemanager = require "core.storagemanager";

local metronome = _G.metronome;

local setmetatable = setmetatable;

local default_provider = "internal_plain";

local _ENV = nil;
local _M = {};

local function new_null_provider()
	local function dummy() return nil, "method not implemented"; end;
	local function dummy_get_sasl_handler() return sasl_new(nil, {}); end
	return setmetatable({name = "null", get_sasl_handler = dummy_get_sasl_handler}, {
		__index = function(self, method) return dummy; end
	});
end

local provider_mt = { __index = new_null_provider() };

local function initialize_host(host)
	local host_session = hosts[host];
	if host_session.type ~= "local" then return; end
	
	host_session.events.add_handler("item-added/auth-provider", function (event)
		local provider = event.item;
		local auth_provider = config.get(host, "authentication") or default_provider;
		if provider.name == auth_provider then
			host_session.users = setmetatable(provider, provider_mt);
		end
		if host_session.users ~= nil and host_session.users.name ~= nil then
			log("debug", "host '%s' now set to use user provider '%s'", host, host_session.users.name);
		end
	end);
	host_session.events.add_handler("item-removed/auth-provider", function (event)
		local provider = event.item;
		if host_session.users == provider then
			host_session.users = new_null_provider();
		end
	end);
	host_session.users = new_null_provider();
	local auth_provider = config.get(host, "authentication") or default_provider;
	if auth_provider ~= "null" then
		modulemanager.load(host, "auth_"..auth_provider);
	end
end;
metronome.events.add_handler("host-activated", initialize_host, 100);

local host_unknown = "host unknown or deactivated";

local function test_password(username, host, password)
	if hosts[host] then return hosts[host].users.test_password(username, password); end
	return nil, host_unknown;
end

local function get_password(username, host)
	if hosts[host] then return hosts[host].users.get_password(username); end
	return nil, host_unknown;
end

local function set_password(username, password, host)
	if hosts[host] then return hosts[host].users.set_password(username, password); end
	return nil, host_unknown;
end

local function user_exists(username, host)
	if hosts[host] then return hosts[host].users.user_exists(username); end
	return nil, host_unknown;
end

local function create_user(username, password, host, locked)
	local ok, err = hosts[host].users.create_user(username, password, locked);
	if not ok then
		return nil, err;
	else
		metronome.events.fire_event("user-created", { username = username, host = host });
		return true;
	end
end

local function delete_user(username, host, source, reason)
	local hostname = hosts[host];
	local session = hostname.sessions and hostname.sessions[username];
	local ok, err = hostname.users.delete_user(username);
	if not ok then return nil, err; end

	hostname.events.fire_event("user-pre-delete",
		{ username = username, host = host, session = session, source = source, reason = reason });
	metronome.events.fire_event("user-deleted",
		{ username = username, host = host, session = session, source = source, reason = reason });
	return storagemanager.purge(username, host);
end

local function get_sasl_handler(host, session)
	if hosts[host] then return hosts[host].users.get_sasl_handler(session); end
	return nil, host_unknown;
end

local function get_provider(host)
	return hosts[host] and hosts[host].users or nil;
end

local function is_locked(username, host)
	if hosts[host] then return hosts[host].users.is_locked(username); end
	return nil, host_unknown;
end

local function unlock_user(username, host)
	if hosts[host] then return hosts[host].users.unlock_user(username); end
	return nil, host_unknown;
end

local function is_admin(jid, host)
	if host and not hosts[host] then return false; end
	if type(jid) ~= "string" then return false; end

	local is_admin;
	jid = jid_bare(jid);
	host = host or "*";
	
	local host_admins = config.get(host, "admins");
	local global_admins = config.get("*", "admins");
	
	if host_admins and host_admins ~= global_admins then
		if type(host_admins) == "table" then
			for _,admin in ipairs(host_admins) do
				if jid_prep(admin) == jid then
					is_admin = true;
					break;
				end
			end
		elseif host_admins then
			log("error", "Option 'admins' for host '%s' is not a list", host);
		end
	end
	
	if not is_admin and global_admins then
		if type(global_admins) == "table" then
			for _,admin in ipairs(global_admins) do
				if jid_prep(admin) == jid then
					is_admin = true;
					break;
				end
			end
		elseif global_admins then
			log("error", "Global option 'admins' is not a list");
		end
	end

	if not is_admin and host ~= "*" and hosts[host].users and hosts[host].users.is_admin then
		is_admin = hosts[host].users.is_admin(jid);
	end
	return is_admin or false;
end

local function account_type(user, host)
	local host_session = hosts[host];
	if not host_session or host_session.type ~= "local" then return; end
	if is_admin(jid_join(user, host), host) then
		return "admin";
	elseif host_session.anonymous_host then
		return "anonymous";
	elseif user_exists(user, host) then
		return "registered";
	end
end

_M.initialize_host = initialize_host;
_M.test_password = test_password;
_M.get_password = get_password;
_M.set_password = set_password;
_M.user_exists = user_exists;
_M.create_user = create_user;
_M.delete_user = delete_user;
_M.get_sasl_handler = get_sasl_handlers;
_M.get_provider = get_provider;
_M.is_locked = is_locked;
_M.is_admin = is_admin;
_M.account_type = account_type;
return _M;
