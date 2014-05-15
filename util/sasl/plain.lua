-- Please see sasl.lua.license for licensing information.

local s_match = string.match;
local nodeprep = require "util.encodings".stringprep.nodeprep;
local saslprep = require "util.encodings".stringprep.saslprep;
local log = require "util.logger".init("sasl");

module "sasl.plain"

-- ================================
-- SASL PLAIN according to RFC 4616

--[[
Supported Authentication Backends

plain:
	function(username, realm)
		return password, state;
	end

plain_test:
	function(username, password, realm)
		return true or false, state;
	end
]]

local function plain(self, message)
	if not message then
		return "failure", "malformed-request";
	end

	local authorization, authentication, password = s_match(message, "^([^%z]*)%z([^%z]+)%z([^%z]+)");

	if not authorization then
		return "failure", "malformed-request";
	end

	-- SASLprep password and authentication
	authentication = saslprep(authentication);
	password = saslprep(password);

	if (not password) or (password == "") or (not authentication) or (authentication == "") then
		log("debug", "Username or password violates SASLprep.");
		return "failure", "malformed-request", "Invalid username or password.";
	end

	local _nodeprep = self.profile.nodeprep;
	if _nodeprep ~= false then
		authentication = (_nodeprep or nodeprep)(authentication);
		if not authentication or authentication == "" then
			return "failure", "malformed-request", "Invalid username or password"
		end
	end

	local correct, state = false, false;
	if self.profile.plain then
		local correct_password;
		correct_password, state = self.profile.plain(self, authentication, self.realm);
		correct = (correct_password == password);
	elseif self.profile.plain_test then
		correct, state = self.profile.plain_test(self, authentication, password, self.realm);
	end

	self.username = authentication
	if state == false then
		return "failure", "account-disabled";
	elseif state == nil then
		return "failure", "not-authorized", "Unable to authorize you with the authentication credentials you've sent";
	end

	if correct then
		return "success";
	else
		return "failure", "not-authorized", "Unable to authorize you with the authentication credentials you've sent";
	end
end

function init(registerMechanism)
	registerMechanism("PLAIN", {"plain", "plain_test"}, plain);
end

return _M;
