local s_match = string.match;

local log = require "util.logger".init("sasl");
local generate_uuid = require "util.uuid".generate;

module "sasl.anonymous"

--=========================
--SASL ANONYMOUS according to RFC 4505

--[[
Supported Authentication Backends

anonymous:
	function(username, realm)
		return true; --for normal usage just return true; if you don't like the supplied username you can return false.
	end
]]

local function anonymous(self, message)
	local username;
	repeat
		username = generate_uuid();
	until self.profile.anonymous(self, username, self.realm);
	self.username = username;
	return "success"
end

function init(registerMechanism)
	registerMechanism("ANONYMOUS", {"anonymous"}, anonymous);
end

return _M;
