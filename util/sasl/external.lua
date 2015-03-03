-- * Metronome IM *
--
-- This file is part of the Metronome XMPP server and is released under the
-- ISC License, please see the LICENSE file in this source package for more
-- information about copyright and licensing.

local log = require "util.logger".init("sasl");
local nodeprep = require "util.encodings".stringprep.nodeprep;
local ipairs = ipairs;

module "sasl.external"

--[[
Supported Authentication Backends

external:
		function(sasl, session, authid)
			return nil (internal-server-error) or true (invalid-authzid) or false or username, err.
		end
]]--

local function external(self, authid)
	local username, err = self.profile.external(self, self.profile.session, authid);

	if username == nil then
		log("debug", "A server error was caught while attempting EXTERNAL SASL: %s", err);
		return "failure", "internal-server-error", err;
	end
	if username == true then return "failure", "invalid-authzid", err; end
	if username == false then return "failure", "not-authorized", err; end
	
	self.username = nodeprep(username);
	if self.username then
		return "success";
	else
		log("debug", "Username %s in the certificate, violates the NodePREP profile", username);
		return "failure", "malformed-request", "Username in the certificate violates the NodePREP profile";
	end
end

function init(registerMechanism)
	registerMechanism("EXTERNAL", {"external"}, external);
end

return _M;
