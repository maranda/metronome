-- * Metronome IM *
--
-- This file is part of the Metronome XMPP server and is released under the
-- ISC License, please see the LICENSE file in this source package for more
-- information about copyright and licensing.
--
-- Additional Contributors: John Regan
--
-- As per the sublicensing clause, this file is also MIT/X11 Licensed.
-- ** Copyright (c) 2008-2013, Kim Alvefur, Matthew Wild, Waqas Hussain

local error, type, pairs = error, type, pairs;
local setmetatable = setmetatable;

local config = require "core.configmanager";
local datamanager = require "util.datamanager";
local modulemanager = require "core.modulemanager";
local multitable = require "util.multitable";
local hosts = hosts;
local log = require "util.logger".init("storagemanager");

local metronome = metronome;

module("storagemanager")

local olddm = {}; -- maintain old datamanager, for backwards compatibility
for k,v in pairs(datamanager) do olddm[k] = v; end
_M.olddm = olddm;

local null_storage_method = function () return false, "no data storage active"; end
local null_storage_driver = setmetatable(
	{
		name = "null",
		open = function (self) return self; end
	}, {
		__index = function (self, method)
			return null_storage_method;
		end
	}
);

local stores_available = multitable.new();
local stores_overrides = multitable.new();

function initialize_host(host)
	local host_session = hosts[host];
	host_session.events.add_handler("item-added/data-driver", function (event)
		local item = event.item;
		stores_available:set(host, item.name, item);
	end);
	
	host_session.events.add_handler("item-removed/data-driver", function (event)
		local item = event.item;
		stores_available:set(host, item.name, nil);
	end);

	host_session.events.add_handler("module-loaded", function (event)
		local host, storage = event.host, event.storage;
		if type(storage) == "table" then
			for store, driver in pairs(storage) do
				stores_overrides:set(host, store, driver);
			end
		end
	end);

	host_session.events.add_handler("module-unloaded", function (event)
		local host, storage = event.host, event.storage;
		if type(storage) == "table" then
			for store, driver in pairs(storage) do
				stores_overrides:set(host, store, nil);
			end
		end
	end);
end
metronome.events.add_handler("host-activated", initialize_host, 101);

function load_driver(host, driver_name)
	if driver_name == "null" then
		return null_storage_driver;
	end
	local driver = stores_available:get(host, driver_name);
	if driver then return driver; end

	local ok, err;
	ok, err = modulemanager.load(host, "storage_"..driver_name);
	if err == "module-already-loaded" then -- force unload and reload;
		modulemanager.unload(host, "storage_"..driver_name);
		ok, err = modulemanager.load(host, "storage_"..driver_name);
	end
	if not ok then
		log("error", "Failed to load storage driver plugin %s on %s: %s", driver_name, host, err);
	end
	return stores_available:get(host, driver_name);
end

function get_driver(host, store)
	local storage = stores_overrides:get(host, store) or config.get(host, "storage");
	local driver_name;
	local option_type = type(storage);
	if option_type == "string" then
		driver_name = storage;
	elseif option_type == "table" then
		driver_name = storage[store];
	end
	if not driver_name then
		if config.get(host, authentication) == "anonymous" then
			driver_name = config.get(host, "default_storage") or "null";
		else
			driver_name = config.get(host, "default_storage") or "internal";
		end
	end
	
	local driver = load_driver(host, driver_name);
	if not driver then
		log("warn", "Falling back to null driver for %s storage on %s", store, host);
		driver_name = "null";
		driver = null_storage_driver;
	end
	return driver, driver_name;
end
	
function open(host, store, typ)
	local driver, driver_name = get_driver(host, store);
	local ret, err = driver:open(store, typ);
	if not ret then
		if err == "unsupported-store" then
			log("debug", "Storage driver %s does not support store %s (%s), falling back to null driver",
				driver_name, store, typ);
			ret = null_storage_driver;
			err = nil;
		end
	end
	return ret, err;
end

function purge(user, host)
	local storage = config.get(host, "storage");
	local driver_name;
	if type(storage) == "table" then
		local purged = {};
		for store, driver in pairs(storage) do
			if not purged[driver] then purged[driver] = get_driver(host, store):purge(user); end
		end
	end
	get_driver(host):purge(user);
	olddm.purge(user, host);
	
	return true;
end

function datamanager.load(username, host, datastore)
	return open(host, datastore):get(username);
end
function datamanager.store(username, host, datastore, data)
	return open(host, datastore):set(username, data);
end
function datamanager.stores(username, host, type, pattern)
	return get_driver(host):stores(username, type, pattern);
end
function datamanager.store_exists(username, host, datastore, type)
	return get_driver(host):store_exists(username, datastore, type);
end
function datamanager.purge(username, host)
	return purge(username, host);
end
function datamanager.users(host)
	return get_driver(host):users();
end

return _M;
