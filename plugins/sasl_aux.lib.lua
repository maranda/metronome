-- * Metronome IM *
--
-- This file is part of the Metronome XMPP server and is released under the
-- ISC License, please see the LICENSE file in this source package for more
-- information about copyright and licensing.

-- Exportable SASL backends.

local dm_load = require "util.datamanager".load;
local user_exists = require "core.usermanager".user_exists;
local get_password = require "core.usermanager".get_password;
local set_password = require "core.usermanager".set_password;
local test_password = require "core.usermanager".test_password;
local jid_compare = require "util.jid".compare;
local jid_split = require "util.jid".prepped_split;
local log = require "util.logger".init("sasl");
local get_time, ipairs, t_concat, unpack = os.time, ipairs, table.concat, unpack;

-- Util functions

local function replace_byte_with_hex(byte) return ("%02x"):format(byte:byte()); end
local function replace_hex_with_byte(hex) return string.char(tonumber(hex, 16)); end

local function to_hex(binary_string)
	return binary_string:gsub(".", replace_byte_with_hex);
end

local function from_hex(hex_string)
	return hex_string:gsub("..", replace_hex_with_byte);
end

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
	local sasl_host = sasl.profile.host;
	local socket = session.conn:socket();
	if not socket.getpeercertificate or not socket.getpeerverification then
		log("error", "LuaSec 0.5+ is required in order to perform SASL external");
		return nil, "Unable to perform external certificate authentications at this time";
	end

	local verified = module:fire_event("auth-external-proxy", sasl, session, authid, socket);
	if verified then -- certificate was verified pre-emptively by a plugin
		local state, err = unpack(verified);
		if not state then
			return false, err;
		else
			return state;
		end
	end

	local chain, errors = socket:getpeerverification();
	if not chain then
		local _log = session.log or log;
		_log("debug", "Invalid client certificate chain detected");
		for i, error in ipairs(errors) do _log("debug", "%d: %s", i, t_concat(error, ", ")); end
		return false, "Invalid client certificate chain";
	end

	local cert = socket:getpeercertificate();
	if not cert then
		return false, "No certificate found";
	end
	if not cert:validat(get_time()) then
		return false, "Supplied certificate is expired";
	end

	local data = extract_data(cert);
	for _, address in ipairs(data) do
		if authid == "" or jid_compare(authid, address) then
			local username, host = jid_split(address);
			if host == sasl_host and user_exists(username, host) then return username; end
		end
	end
	
	return false, "Couldn't find a valid address which could be associated with a xmpp account";
end

local function hashed_plain_test(sasl, username, password, realm)
	return test_password(username, realm, password), true;
end

local function hashed_scram_backend(sasl, username, realm)
	local credentials =
		module:fire_event("auth-hashed-proxy", sasl, username, realm)
		or dm_load(username, host, "accounts");

	if not credentials then return; end
	if credentials.password then
		set_password(username, credentials.password, host);
		credentials = dm_load(username, host, "accounts");
		if not credentials then return; end
	end
				
	local stored_key, server_key, iteration_count, salt =
		credentials.stored_key, credentials.server_key, credentials.iteration_count, credentials.salt;

	stored_key = stored_key and from_hex(stored_key);
	server_key = server_key and from_hex(server_key);
	return stored_key, server_key, iteration_count, salt, true;
end

local function plain_backend(sasl, username, realm)
	local password =
		module:fire_event("auth-plain-proxy", sasl, username, realm)
		or get_password(username, realm);

	if not password then
		return "", nil;
	end
	return password, true;
end

return {
	from_hex = from_hex,
	to_hex = to_hex,
	extract_data = extract_data,
	external_backend = external_backend,
	hashed_plain_test = hashed_plain_test,
	hashed_scram_backend = hashed_scram_backend,
	plain_backend = plain_backend
};
