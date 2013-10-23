-- * Metronome IM *
--
-- This file is part of the Metronome XMPP server and is released under the
-- ISC License, please see the LICENSE file in this source package for more
-- information about copyright and licensing.

local log = require "util.logger".init("sasl");
local jid_compare = require "util.jid".compare;
local jid_split = require "util.jid".prepped_split;
local get_time = os.time;
local ipairs = ipairs;

module "sasl.external"

--[[
Supported Authentication Backends

external:
		function(sasl, session)
			return cert or nil, err.
		end
]]--

local function extract_data(cert)
	local extensions = cert:extensions();
	local SANs = extensions["2.5.29.17"];
	local xmpp_addresses = SANs and SANs["1.3.6.1.5.5.7.8.5"];
	local subject = cert:subject();
	
	if not xmpp_addresses then
		local email_addresses = {}
		for _, ava in ipairs(subject) do
			if ava.oid == "1.2.840.113549.1.9.1" then
				email_addresses[#email_addresses + 1] = ava.value;
			end
		end
		return email_addresses;
	end
	return xmpp_addresses;
end

local function external(self, authid)
	local _log = self.profile.session and self.profile.session.log;
	local cert, err = self.profile.external(self, self.profile.session);

	if err then
		(_log or log)("debug", "A server error was caught while attempting EXTERNAL SASL: %s", err);
		return "failure", "internal-server-error", err;
	end
	if not cert then
		(_log or log)("debug", "No certificate available");
		return "failure", "not-authorized", "No certificate could be obtained";
	end
	
	if not cert:validat(get_time()) then
		(_log or log)("debug", "The certificate supplied is expired")
		return "failure", "not-authorized", "Supplied certificate is expired";
	end
	
	local data = extract_data(cert);
	for _, address in ipairs(data) do
		if authid == "" or jid_compare(authid, address) then
			local username, host = jid_split(address);
			if host == self.host then return "success"; end
		end
	end
end

function init(registerMechanism)
	registerMechanism("EXTERNAL", {"external"}, external);
end

function backend(sasl, session)
	local socket = session.conn:socket();
	if not socket.getpeercertificate or not socket.getpeerverification then
		log("error", "LuaSec 0.5+ is required in order to perform SASL external");
		return nil, "Unable to perform external certificate authentications at this time.";
	end
	
	local chain, errors = socket:getpeerverification();
	if not chain then
		local _log = session.log or log;
		_log("warn", "Invalid client certificate chain detected");
		return nil, "Invalid client certificate chain";
	end
	return socket:getpeercertificate();
end

return _M;


