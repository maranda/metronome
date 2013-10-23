-- * Metronome IM *
--
-- This file is part of the Metronome XMPP server and is released under the
-- ISC License, please see the LICENSE file in this source package for more
-- information about copyright and licensing.

-- Exportable SASL backends.

local user_exists = require "core.usermanager".user_exists;
local log = require "util.logger".init("sasl");
local ipairs, t_concat = ipairs, t_concat;

-- Util functions

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

-- Backends

local function external_backend(sasl, session, authid)
	local socket = session.conn:socket();
	if not socket.getpeercertificate or not socket.getpeerverification then
		log("error", "LuaSec 0.5+ is required in order to perform SASL external");
		return nil, "Unable to perform external certificate authentications at this time";
	end

	local _log = session.log or log;
	local chain, errors = socket:getpeerverification();
	if not chain then
		_log("warn", "Invalid client certificate chain detected");
		for i, error in ipairs(errors) do _log("debug", "%d: %s", i, t_concat(error, ", ")); end
		return false, "Invalid client certificate chain";
	end

	local cert = socket:getpeercertificate();
	if not cert then
		_log("warn", "Client attempted SASL External without a certificate");
		return false, "No certificate found";
	end
	if not cert:validat(get_time()) then
		_log("warn", "Client attempted SASL External with an expired certificate");
		return false, "Supplied certificate is expired";
	end	

	local data = extract_data(cert);
	for _, address in ipairs(data) do
		if authid == "" or jid_compare(authid, address) then
			local username, host = jid_split(address);
			if host == self.host and user_exists(username, host) then return username; end
		end
	end
	
	return false, "Couldn't find a valid address which could be associated with an xmpp account";
end

return { external_backend = external_backend };