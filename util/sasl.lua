-- Please see signal.lua.license for licensing information.

local pairs, ipairs = pairs, ipairs;
local t_insert = table.insert;
local type = type
local setmetatable = setmetatable;
local assert = assert;
local require = require;

module "sasl"

--[[
Authentication Backend Prototypes:

state = false : disabled
state = true : enabled
state = nil : non-existant
]]

local method = {};
method.__index = method;
local mechanisms = {};
local backend_mechanism = {};

-- register a new SASL mechanims
function registerMechanism(name, backends, f)
	assert(type(name) == "string", "Parameter name MUST be a string.");
	assert(type(backends) == "string" or type(backends) == "table", "Parameter backends MUST be either a string or a table.");
	assert(type(f) == "function", "Parameter f MUST be a function.");
	mechanisms[name] = f
	for _, backend_name in ipairs(backends) do
		if backend_mechanism[backend_name] == nil then backend_mechanism[backend_name] = {}; end
		t_insert(backend_mechanism[backend_name], name);
	end
end

-- create a new SASL object which can be used to authenticate clients,
-- new() expects an array, profile.order, to be present in the profile
-- and which specifies the order of preference in which mechanisms are
-- presented by the server
function new(realm, profile)
	local order = profile.order;
	local mechanisms = {};
	if type(order) == "table" and #order ~= 0 then
		for b = 1, #order do
			local backend = backend_mechanism[order[b]];
			if backend then
				for i = 1, #backend do
					local sasl = backend[i];
					t_insert(mechanisms, sasl);
					mechanisms[sasl] = true;
				end
			end
		end
	end
	return setmetatable({ profile = profile, realm = realm, mechs = mechanisms }, method);
end

-- get a fresh clone with the same realm and profile
function method:clean_clone()
	return new(self.realm, self.profile)
end

-- get a list of possible SASL mechanims to use
function method:mechanisms()
	return self.mechs;
end

-- select a mechanism to use
function method:select(mechanism)
	if not self.selected and self.mechs[mechanism] then
		self.selected = mechanism;
		return true;
	end
end

-- feed new messages to process into the library
function method:process(message)
	return mechanisms[self.selected](self, message);
end

-- load the mechanisms
require "util.sasl.external".init(registerMechanism);
require "util.sasl.scram".init(registerMechanism);
require "util.sasl.digest-md5".init(registerMechanism);
require "util.sasl.plain".init(registerMechanism);
require "util.sasl.anonymous".init(registerMechanism);

return _M;
