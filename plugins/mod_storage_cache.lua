-- * Metronome IM *
--
-- This file is part of the Metronome XMPP server and is released under the
-- ISC License, please see the LICENSE file in this source package for more
-- information about copyright and licensing.
--
-- This is an experimental resident memory cache storage, it currently loads
-- and dumps the cache data on startup and shutdown of Metronome by default, 
-- it doesn't currently offer any fault tollerance in the case of software or
-- hardware failures and is suitable for temporary or non storage critical
-- uses (e.g. anonymous hosts).

-- Configuration
local store_data = module:get_option_boolean("storage_cache_save_data", true);

-- Module code
local dm, jsonload = require "util.datamanager", require "util.jsonload";
local load, serialize = jsonload.loadfile, jsonload.serialize;
local atomic_store, get_path = dm.atomic_store, dm.get_path;

local next, pairs, os_remove = next, pairs, os.remove;

local host = module.host;

store = {};
cache = {};

local driver = { name = "cache" };
local driver_mt = { __index = driver };

local type_error = "Only key / value pairs are supported";

local function dump_cache()
	local serialized = serialize(store);
	local try = 0;
	repeat
		local ok, ret = atomic_store(getpath(nil, host, "ram_storage", "cache", true), serialized);
		if not ok then
			if try <= 3 then
				try = try + 1;
			else
				module:log("error", "atomic store failed to write the cache to disk");
				return;
			end
		end
		if next(store) == nil then
			module:log("info", "removing empty cache dump from disk");
			os_remove(getpath(nil, host, "ram_storage", "cache"));
		end
	until ok;
end

-- Define driver object
function driver:open(store)
	if not cache[store] then cache[store] = setmetatable({ store = store }, driver_mt); end
	return cache[store];
end

function driver:get(node)
	if store[self.store] then
		if not next(store[self.store]) then -- remove
			store[self.store] = nil;
			return;
		end
		return store[self.store][node or true];
	end
end

function driver:set(node, data)
	if type(data) ~= "table" or not next(data) then
		return nil, "Data must be enclosed in a table and the table shouldn't be empty";
	end
	if not store[self.store] then store[self.store] = {}; end
	store[self.store][node or true] = data;
	return true;
end

function driver:stores(node, type, pattern)
	if not pattern then	return nil, "A pattern is required"; end
	if type and type ~= "keyval" then return nil, type_error; end
	local state;
	local function _stores()
		state = next(store, state);
		local k, v = state, store[state];
		if state == nil then
			return nil;
		elseif k:match("^"..pattern..".*") then
			if node and node ~= true and not v[node] then return _stores(); end
			return k;
		else
			return _stores();
		end
	end
	return _stores;
end

function driver:store_exists(node, type)
	if type and type ~= "keyval" then return nil, type_error; end
	if store[self.store][node or true] then
		return true;
	end
	return false;
end

function driver:purge(node)
	for name, datastore in pairs(store) do
		datastore[node or true] = nil;
		if not next(datastore) then store[name] = nil; end
	end
end

function driver:users(type)
	if type and type ~= "keyval" then return nil, type_error; end
	local function _keys(t, k) return (next(t, k)); end
	return _keys, store[self.store] or {};
end

module.load = function()
	if store_data then
		module:load("warn", "the memory cache is about to be serialized from the disk dump, it may take");
		module:load("warn", "a bit depending on the amount of data, the server could block");
		ok, store = load(getpath(nil, host, "ram_storage", "cache", true));
		if ok then
			module:log("info", "storage cache successfully loaded in memory");
		else
			module:log("error", "storage cache failed to load from disk creating a new one, error: %s", store);
			store = {};
		end
	end
end

module.unload = function(reload)
	if not reload and store_data then
		module:log("warn", "cache storage driver is being unloaded, serializing and dumping data to disk, server may block!");
		dump_cache();
	end
end

module.save = function()
	return { store = store };
end

module.restore = function(save)
	store = save.store or {};
end

module:add_item("data-driver", driver);

module:hook_global("server-stopping", function()
	if store_data then
		module:log("info", "serializing cache storage and dumping data to disk since the server is shutting down... please wait");
		dump_cache();
	end
end);
