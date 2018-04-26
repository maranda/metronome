-- * Metronome IM *
--
-- This file is part of the Metronome XMPP server and is released under the
-- ISC License, please see the LICENSE file in this source package for more
-- information about copyright and licensing.
--
-- As per the sublicensing clause, this file is also MIT/X11 Licensed.
-- ** Copyright (c) 2008-2013, Florian Zeitz, Kim Alvefur, Jeff Mitchell, Marco Cirillo, Matthew Wild, Paul Aurich, Waqas Hussain

local logger = require "util.logger";
local log = logger.init("modulemanager");
local config = require "core.configmanager";
local pluginloader = require "util.pluginloader";
local set = require "util.set";

local new_multitable = require "util.multitable".new;

local hosts = hosts;
local metronome = metronome;

local pcall, xpcall = pcall, xpcall;
local setmetatable, rawget = setmetatable, rawget;
local ipairs, pairs, type, tostring, t_insert = ipairs, pairs, type, tostring, table.insert;

local debug_traceback = debug.traceback;
local unpack, select = unpack, select;
pcall = function(f, ...)
	local n = select("#", ...);
	local params = { ... };
	return xpcall(function() return f(unpack(params, 1, n)) end, function(e) return tostring(e).."\n"..debug_traceback(); end);
end

local autoload_modules = { "router", "bind_session", "presence", "message", "iq", "offline", "c2s", "s2s" };

local _G = _G;

module "modulemanager"

local api = _G.require "core.moduleapi"; -- Module API container

local modulemap = { ["*"] = {} };

function load_modules_for_host(host)
	local component = config.get(host, "component_module");
	
	local global_modules_enabled = config.get("*", "modules_enabled");
	local global_modules_disabled = config.get("*", "modules_disabled");
	local host_modules_enabled = config.get(host, "modules_enabled");
	local host_modules_disabled = config.get(host, "modules_disabled");
	
	if host_modules_enabled == global_modules_enabled then host_modules_enabled = nil; end
	if host_modules_disabled == global_modules_disabled then host_modules_disabled = nil; end
	
	local global_modules = set.new(autoload_modules) + set.new(global_modules_enabled) - set.new(global_modules_disabled);
	local modules = (global_modules + set.new(host_modules_enabled)) - set.new(host_modules_disabled);
	
	if component then
		load(host, component);
	end
	for module in modules do
		if not is_loaded(host, module) then load(host, module, component and set.new(host_modules_enabled or {})); end
	end
end
metronome.events.add_handler("host-activated", load_modules_for_host);
metronome.events.add_handler("host-deactivating", function (event)
	local host, host_session = event.host, event.host_session;
	if host_session.modules then
		for module in pairs(host_session.modules) do unload(host, module); end
	end
end, -3);
metronome.events.add_handler("host-deactivated", function (host)
	modulemap[host] = nil;
end);

--- Private helpers ---

local function do_unload_module(host, name, reload)
	local mod = get_module(host, name);
	if not mod then return nil, "module-not-loaded"; end
	
	if module_has_method(mod, "unload") then
		local ok, err = call_module_method(mod, "unload", reload);
		if (not ok) and err then
			log("warn", "Non-fatal error unloading module '%s' on '%s': %s", name, host, err);
		end
	end
	
	for object, event, handler in mod.module.event_handlers:iter(nil, nil, nil) do
		object.remove_handler(event, handler);
	end
	
	if mod.module.items then
		local events = (host == "*" and metronome.events) or hosts[host].events;
		for key,t in pairs(mod.module.items) do
			for i = #t,1,-1 do
				local value = t[i];
				t[i] = nil;
				events.fire_event("item-removed/"..key, {source = mod.module, item = value});
			end
		end
	end
	mod.module.loaded = false;
	modulemap[host][name] = nil;
	return true;
end

local function do_load_module(host, module_name, component_load)
	if not (host and module_name) then
		return nil, "insufficient-parameters";
	elseif not hosts[host] and host ~= "*"then
		return nil, "unknown-host";
	end

	if not modulemap[host] then modulemap[host] = hosts[host].modules; end
	
	if modulemap[host][module_name] then
		log("warn", "%s is already loaded for %s, so not loading again", module_name, host);
		return nil, "module-already-loaded";
	elseif modulemap["*"][module_name] then
		local mod = modulemap["*"][module_name];
		if module_has_method(mod, "add_host") then
			local _log = logger.init(host..":"..module_name);
			local host_module_api = setmetatable({
				host = host, event_handlers = new_multitable(), items = {};
				_log = _log, log = function (self, ...) return _log(...); end;
			},{
				__index = modulemap["*"][module_name].module;
			});
			local host_module = setmetatable({ module = host_module_api }, { __index = mod });
			host_module_api.environment = host_module;
			modulemap[host][module_name] = host_module;
			local ok, result, module_err = call_module_method(mod, "add_host", host_module_api);
			if not ok or result == false then
				do_unload_module(host, module_name);
				return nil, ok and module_err or result;
			end
			if component_load and not host_module_api.component_inheritable and not component_load:contains(module_name) then
				do_unload_module(host, module_name);
				return nil, "module-not-component-inheritable";
			end
			return host_module;
		end
		return nil, "global-module-already-loaded";
	end

	local _log = logger.init(host..":"..module_name);
	local api_instance = setmetatable({ name = module_name, host = host,
		_log = _log, log = function (self, ...) return _log(...); end, event_handlers = new_multitable() }
		, { __index = api });

	local pluginenv = setmetatable({ module = api_instance }, { __index = _G });
	api_instance.environment = pluginenv;
	
	local mod, err = pluginloader.load_code(module_name, nil, pluginenv);
	if not mod then
		log("error", "Unable to load module '%s': %s", module_name or "nil", err or "nil");
		return nil, err;
	end

	api_instance.path = err;

	modulemap[host][module_name] = pluginenv;
	local ok, err = pcall(mod);
	if ok then
		if module_has_method(pluginenv, "load") then
			ok, err = call_module_method(pluginenv, "load");
			if not ok then
				log("warn", "Error loading module '%s' on '%s': %s", module_name, host, err or "nil");
			end
		end

		if api_instance.host == "*" then
			if not api_instance.global then
				if host ~= "*" then
					log("warn", "mod_%s: Setting module.host = '*' deprecated, call module:set_global() instead", module_name);
				end
				api_instance:set_global();
			end
			modulemap[host][module_name] = nil;
			modulemap[api_instance.host][module_name] = pluginenv;
			if host ~= api_instance.host and module_has_method(pluginenv, "add_host") then
				ok, err = do_load_module(host, module_name);
			end
		end
	end
	if not ok then
		modulemap[api_instance.host][module_name] = nil;
		log("error", "Error initializing module '%s' on '%s': %s", module_name, host, err or "nil");
	end
	if component_load and not api_instance.component_inheritable and not component_load:contains(module_name) then
		do_unload_module(host, module_name);
		return nil, "module-not-component-inheritable";
	end
	return ok and pluginenv, err;
end

local function do_reload_module(host, name)
	local mod = get_module(host, name);
	if not mod then return nil, "module-not-loaded"; end

	local _mod, err = pluginloader.load_code(name);
	if not _mod then
		log("error", "Unable to load module '%s': %s", name or "nil", err or "nil");
		return nil, err;
	end

	local saved;
	if module_has_method(mod, "save") then
		local ok, ret, err = call_module_method(mod, "save");
		if ok then
			saved = ret;
		else
			log("warn", "Error saving module '%s:%s' state: %s", host, name, ret);
			if not config.get(host, "force_module_reload") then
				log("warn", "Aborting reload due to error, set force_module_reload to ignore this");
				return nil, "save-state-failed";
			else
				log("warn", "Continuing with reload (using the force)");
			end
		end
	end

	do_unload_module(host, name, true);
	local ok, err = do_load_module(host, name);
	if ok then
		mod = get_module(host, name);
		if module_has_method(mod, "restore") then
			local ok, err = call_module_method(mod, "restore", saved or {})
			if (not ok) and err then
				log("warn", "Error restoring module '%s' from '%s': %s", name, host, err);
			end
		end
	end
	return ok and mod, err;
end

--- Public API ---

function load(host, name, component_load)
	local mod, err = do_load_module(host, name, component_load);
	if mod then
		(hosts[mod.module.host] or metronome).events.fire_event("module-loaded",
			{ module = name, host = mod.module.host, storage = mod.module.storage }
		);
	end
	return mod, err;
end

function unload(host, name)
	local mod = get_module(host, name);
	local ok, err = do_unload_module(host, name);
	if ok then
		(hosts[host] or metronome).events.fire_event("module-unloaded",
			{ module = name, host = host, storage = mod.module.storage }
		);
	end
	return ok, err;
end

function reload(host, name)
	local mod, err = do_reload_module(host, name);
	if mod then
		modulemap[host][name].module.reloading = true;
		(hosts[host] or metronome).events.fire_event("module-reloaded", { module = name, host = host });
		mod.module.reloading = nil;
	elseif not is_loaded(host, name) then
		(hosts[host] or metronome).events.fire_event("module-unloaded", { module = name, host = host });
	end
	return mod, err;
end

function get_module(host, name)
	return modulemap[host] and modulemap[host][name];
end

function get_items(key, host)
	local result = {};
	local modules = modulemap[host];
	if not key or not host or not modules then return nil; end

	for _, module in pairs(modules) do
		local mod = module.module;
		if mod.items and mod.items[key] then
			for _, value in ipairs(mod.items[key]) do
				t_insert(result, value);
			end
		end
	end

	return result;
end

function get_modules(host)
	return modulemap[host];
end

function is_loaded(host, name)
	return modulemap[host] and modulemap[host][name] and true;
end

function module_has_method(module, method)
	return type(rawget(module.module, method)) == "function";
end

function call_module_method(module, method, ...)
	local f = rawget(module.module, method);
	if type(f) == "function" then
		return pcall(f, ...);
	else
		return false, "no-such-method";
	end
end

return _M;
