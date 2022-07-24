-- * Metronome IM *
--
-- This file is part of the Metronome XMPP server and is released under the
-- ISC License, please see the LICENSE file in this source package for more
-- information about copyright and licensing.
--
-- As per the sublicensing clause, this file is also MIT/X11 Licensed.
-- ** Copyright (c) 2010-2013, Kim Alvefur, Matthew Wild, Waqas Hussain

local storagemanager = require "core.storagemanager";
local new_sasl = require "util.sasl".new;
local nodeprep = require "util.encodings".stringprep.nodeprep;
local plain_backend = module:require("sasl", "auxlibs").plain_backend;
local external_backend = module:require("sasl", "auxlibs").external_backend;
local get_channel_binding_callback = module:require("sasl", "auxlibs").get_channel_binding_callback;

local accounts = storagemanager.open(module.host, "accounts");

local log = module._log;

function new_default_provider(host)
	local provider = { name = "internal_plain" };
	log("debug", "initializing internal_plain authentication provider for host '%s'", host);

	function provider.test_password(username, password)
		log("debug", "test password '%s' for user %s at host %s", password, username, module.host);
		local credentials = accounts:get(username) or {};
	
		if password == credentials.password then
			return true;
		else
			return nil, "Auth failed, invalid username or password";
		end
	end

	function provider.get_password(username)
		log("debug", "get_password for username '%s' at host '%s'", username, module.host);
		return (accounts:get(username) or {}).password;
	end
	
	function provider.set_password(username, password)
		local account = accounts:get(username);
		if account then
			account.password = password;
			return accounts:set(username, account);
		end
		return nil, "Account not available";
	end

	function provider.user_exists(username)
		local account = accounts:get(username);
		if not account then
			log("debug", "account not found for username '%s' at host '%s'", username, module.host);
			return nil, "Auth failed, invalid username";
		end
		return true;
	end

	function provider.is_locked(username)
		local account = accounts:get(username);
		if not account then
			return nil, "Auth failed, invalid username";
		elseif account and account.locked then
			return true;
		end
		return false;
	end

	function provider.unlock_user(username)
		local account = accounts:get(username);
		if not account then
			return nil, "Auth failed, invalid username";
		elseif account and account.locked then
			account.locked = nil;
			local bare_session = module:get_bare_session(username);
			if bare_session then
				for _, session in pairs(bare_session.sessions) do
					session.locked = nil;
				end
			end
			return accounts:set(username, account);
		end
		return nil, "User isn't locked";
	end

	function provider.create_user(username, password, locked)
		return accounts:set(username, { password = password, locked = locked });
	end
	
	function provider.delete_user(username)
		return accounts:set(username, nil);
	end

	function provider.get_sasl_handler(session)
		local getpass_authentication_profile = {
			external = session.secure and external_backend,
			plain = plain_backend,
			session = session,
			host = host
		};
		if session.secure then
			getpass_authentication_profile.channel_bind_cb = get_channel_binding_callback(session);
			getpass_authentication_profile.order = { "external", "plain" };
		else
			getpass_authentication_profile.order = { "plain" };
		end
		return new_sasl(host, getpass_authentication_profile);
	end
	
	return provider;
end

module:add_item("auth-provider", new_default_provider(module.host));
