-- * Metronome IM *
--
-- This file is part of the Metronome XMPP server and is released under the
-- ISC License, please see the LICENSE file in this source package for more
-- information about copyright and licensing.
--
-- As per the sublicensing clause, this file is also MIT/X11 Licensed.
-- ** Copyright (c) 2010-2013, Kim Alvefur, Matthew Wild, Waqas Hussain


local datamanager = require "util.datamanager";
local new_sasl = require "util.sasl".new;
local nodeprep = require "util.encodings".stringprep.nodeprep;
local plain_backend = module:require "sasl_aux".plain_backend;
local external_backend = module:require "sasl_aux".external_backend;
local my_host = module.host;

local log = module._log;

function new_default_provider(host)
	local provider = { name = "internal_plain" };
	log("debug", "initializing internal_plain authentication provider for host '%s'", host);

	function provider.test_password(username, password)
		log("debug", "test password '%s' for user %s at host %s", password, username, module.host);
		local credentials = datamanager.load(username, host, "accounts") or {};
	
		if password == credentials.password then
			return true;
		else
			return nil, "Auth failed. Invalid username or password.";
		end
	end

	function provider.get_password(username)
		log("debug", "get_password for username '%s' at host '%s'", username, module.host);
		return (datamanager.load(username, host, "accounts") or {}).password;
	end
	
	function provider.set_password(username, password)
		local account = datamanager.load(username, host, "accounts");
		if account then
			account.password = password;
			return datamanager.store(username, host, "accounts", account);
		end
		return nil, "Account not available.";
	end

	function provider.user_exists(username)
		local account = datamanager.load(username, host, "accounts");
		if not account then
			log("debug", "account not found for username '%s' at host '%s'", username, module.host);
			return nil, "Auth failed. Invalid username";
		end
		return true;
	end

	function provider.create_user(username, password)
		return datamanager.store(username, host, "accounts", {password = password});
	end
	
	function provider.delete_user(username)
		return datamanager.store(username, host, "accounts", nil);
	end

	function provider.get_sasl_handler(session)
		local getpass_authentication_profile = {
			external = session.secure and external_backend,
			plain = plain_backend,
			session = session,
			host = my_host
		};
		if session.secure then
			getpass_authentication_profile.order = { "external", "plain" };
		else
			getpass_authentication_profile.order = { "plain" };
		end
		return new_sasl(module.host, getpass_authentication_profile);
	end
	
	return provider;
end

module:add_item("auth-provider", new_default_provider(module.host));
