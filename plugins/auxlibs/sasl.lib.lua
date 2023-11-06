-- * Metronome IM *
--
-- This file is part of the Metronome XMPP server and is released under the
-- ISC License, please see the LICENSE file in this source package for more
-- information about copyright and licensing.

-- Exportable SASL backends.

local storagemanager = require "core.storagemanager";
local user_exists = require "core.usermanager".user_exists;
local get_password = require "core.usermanager".get_password;
local set_password = require "core.usermanager".set_password;
local test_password = require "core.usermanager".test_password;
local jid_compare = require "util.jid".compare;
local jid_split = require "util.jid".prepped_split;
local log = require "util.logger".init("sasl");
local get_time, ipairs, t_concat, unpack = os.time, ipairs, table.concat, table.unpack or unpack;

local accounts = storagemanager.open(module.host, "accounts");

-- Util functions

local function replace_byte_with_hex(byte) return ("%02x"):format(byte:byte()); end
local function replace_hex_with_byte(hex) return string.char(tonumber(hex, 16)); end

local function to_hex(binary_string)
	return binary_string:gsub(".", replace_byte_with_hex);
end

local function from_hex(hex_string)
	return hex_string:gsub("..", replace_hex_with_byte);
end

local function get_address(address, sasl_host, authid)
	if not authid or authid == "" or jid_compare(authid, address) then
		local username, host = jid_split(address);
		if host == sasl_host and user_exists(username, host) then return username; end
	end
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

local function can_do_external(session)
	local socket = session.conn.socket and session.conn:socket();
	if not socket or not socket.getpeercertificate or not socket:getpeercertificate() then
		return false;
	end
	return true;
end

local function verify_certificate(session)
	local sasl = session.sasl_handler;
	local sasl_profile = sasl.profile;
	local sasl_host = sasl_profile.host;
	if not session.conn.socket then
		sasl_profile.ext_user = false;
		return false;
	end

	local socket = session.conn:socket();
	if not socket.getpeercertificate or not socket.getpeerverification then
		sasl_profile.ext_user, sasl_profile.ext_err =
			nil, "Unable to perform external certificate authentications at this time";
		return false;
	end

	local verified = module:fire_event("auth-external-proxy", sasl, session, socket);
	if verified then -- certificate was verified pre-emptively by a plugin
		local state, err = unpack(verified);
		if not state then
			sasl_profile.ext_user, sasl_profile.ext_err = false, err;
			return false;
		else
			sasl_profile.ext_user = state;
			return true;
		end
	end

	local chain, errors = socket:getpeerverification();
	if not chain then
		local _log = session.log or log;
		_log("debug", "Invalid client certificate chain detected");
		for i, error in ipairs(errors) do _log("debug", "%d: %s", i, t_concat(error, ", ")); end
		sasl_profile.ext_user, sasl_profile.ext_err = false, "Invalid client certificate chain";
		return false;
	end

	local cert = socket:getpeercertificate();
	if not cert then
		sasl_profile.ext_user, sasl_profile.ext_err = false, "No certificate found";
		return false;
	end
	if not cert:validat(get_time()) then
		sasl_profile.ext_user, sasl_profile.ext_err = false, "Supplied certificate is expired";
		return false;
	end

	local data = extract_data(cert);
	if #data == 1 then
		local address = data[1];
		sasl_profile.ext_user = get_address(address, sasl_host);
		return true;
	elseif #data ~= 0 then
		local valid_ids = {};
		for _, address in ipairs(data) do
			valid_ids[#valid_ids + 1] = get_address(address, sasl_host);
		end
		if #valid_ids > 0 then
			sasl_profile.valid_identities = valid_ids;
			return true;
		end
	end
	
	sasl_profile.ext_user, sasl_profile.ext_err =
		false, "Couldn't find a valid address which could be associated with a xmpp account";
	return false;
end

-- Backends

local function external_backend(sasl, session, authid)
	local sasl_profile = sasl.profile;
	local username, identities, err;
	if authid and module:fire_event("auth-external-proxy-withid", sasl, authid) then
		username, err = sasl_profile.ext_user, sasl_profile.ext_err;
		return username, err;
	end

	verify_certificate(session);

	username, identities, err =
		sasl_profile.ext_user, sasl_profile.valid_identities, sasl_profile.ext_err;

	if username then -- user is verified
		return username;
	elseif identities then -- user cert has multiple identities
		if not authid then return true; end
		for i = 1, #identities do
			local identity = identities[i];
			if identity == authid then return identity; end
		end
		return true;
	else
		return username, err;
	end
end

local function hashed_plain_test(sasl, username, password, realm)
	return test_password(username, realm, password), true;
end

local function hashed_scram_backend(algorithm, sasl, username, realm)
	local host = sasl.profile.host;
	local credentials =
		module:fire_event("auth-hashed-proxy", sasl, username, realm)
		or accounts:get(username);

	if not credentials then return; end
	if credentials.password then
		set_password(username, credentials.password, host);
		credentials = accounts:get(username);
		if not credentials then return; end
	end

	local stored_key, server_key;
	if algorithm == "sha_256" then
		stored_key, server_key = credentials.stored_key_256, credentials.server_key_256;
	elseif algorithm == "sha_384" then
		stored_key, server_key = credentials.stored_key_384, credentials.server_key_384;
	elseif algorithm == "sha_512" then
		stored_key, server_key = credentials.stored_key_512, credentials.server_key_512;
	else
		stored_key, server_key = credentials.stored_key, credentials.server_key;
	end

	stored_key = stored_key and from_hex(stored_key);
	server_key = server_key and from_hex(server_key);
	return stored_key, server_key, credentials.iteration_count, credentials.salt, true;
end

local function scram_sha1_backend(sasl, username, realm)
	return hashed_scram_backend(nil, sasl, username, realm);
end

local function scram_sha256_backend(sasl, username, realm)
	return hashed_scram_backend("sha_256", sasl, username, realm);
end

local function scram_sha384_backend(sasl, username, realm)
	return hashed_scram_backend("sha_384", sasl, username, realm);
end

local function scram_sha512_backend(sasl, username, realm)
	return hashed_scram_backend("sha_512", sasl, username, realm);
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

local function get_channel_binding_callback(session)
	local socket = session.conn.socket and session.conn:socket();
	local info = socket and socket.info and socket:info();
	if info and info.protocol == "TLSv1.3" then
		return function()
			if socket.exportkeyingmaterial then
				return socket:exportkeyingmaterial("EXPORT-Channel-Binding", 32, ""), "tls-exporter";
			else
				return nil;
			end
		end
	end
	if socket and socket.getpeerfinished then
		return function()
			return socket:getpeerfinished(), "tls-unique";
		end
	end
end

return {
	from_hex = from_hex,
	to_hex = to_hex,
	get_address = get_address,
	extract_data = extract_data,
	can_do_external = can_do_external,
	verify_certificate = verify_certificate,
	external_backend = external_backend,
	hashed_plain_test = hashed_plain_test,
	scram_sha1_backend = scram_sha1_backend,
	scram_sha256_backend = scram_sha256_backend,
	scram_sha384_backend = scram_sha384_backend,
	scram_sha512_backend = scram_sha512_backend,
	plain_backend = plain_backend,
	get_channel_binding_callback = get_channel_binding_callback
};
