local datamanager = require "core.storagemanager".olddm;

local host = module.host;

cache = {};

local driver = { name = "internal" };
local driver_mt = { __index = driver };

function driver:open(store)
	if not cache[store] then cache[store] = setmetatable({ store = store }, driver_mt); end
	return cache[store];
end
function driver:get(user)
	return datamanager.load(user, host, self.store);
end

function driver:set(user, data)
	return datamanager.store(user, host, self.store, data);
end

function driver:stores(username, type)
	return datamanager.stores(username, host, type);
end

function driver:purge(user)
	return datamanager.purge(user, host);
end

module:add_item("data-driver", driver);
