-- * Metronome IM *
--
-- This file is part of the Metronome XMPP server and is released under the
-- ISC License, please see the LICENSE file in this source package for more
-- information about copyright and licensing.
--
-- As per the sublicensing clause, this file is also MIT/X11 Licensed.
-- ** Copyright (c) 2010-2013, Kim Alvefur, Marco Cirillo, Matthew Wild, Waqas Hussain

local new_sasl = require "util.sasl".new;
local datamanager = require "util.datamanager";
local hmac_sha1 = require "util.hmac".sha1;
local gen_uuid = require "util.uuid".generate;
local b64_encode = require "util.encodings".base64.encode;
local os_time = os.time;

local multi_resourcing = module:get_option_boolean("allow_anonymous_multiresourcing", false);
local sha1_gentoken = module:get_option_string("anonymous_jid_gentoken", b64_encode(os_time()));
local randomize_for_trusted = module:get_option_set("anonymous_randomize_for_trusted_addresses", nil);
local my_host = hosts[module.host];

function new_default_provider(host)
	local provider = { name = "anonymous" };

	function provider.test_password(username, password)
		return nil, "Password based auth not supported.";
	end

	function provider.get_password(username)
		return nil, "Password not available.";
	end

	function provider.set_password(username, password)
		return nil, "Password based auth not supported.";
	end

	function provider.user_exists(username)
		local user_session = my_host.sessions[username];
		if not user_session then 
			return nil, "No anonymous user connected with that username."; 
		end

		return true;
	end

	function provider.create_user(username, password)
		return nil, "Account creation/modification not supported.";
	end

	function provider.get_sasl_handler(session)
		local anonymous_authentication_profile = {
			order = { "anonymous" },
			anonymous = function(sasl, session, realm)
				local username;
				if randomize_for_trusted and randomize_for_trusted:contains(session.ip) then
					username = gen_uuid();
				else
					username = hmac_sha1(session.ip, sha1_gentoken, true);
				end

				if not multi_resourcing and my_host.sessions[username] then
					return nil, "You're allowed to have only one anonymous session at any given time, good bye.";
				end

				session.is_anonymous = true;
				return username;
			end,
			session = session,
			host = my_host
		};
		return new_sasl(module.host, anonymous_authentication_profile);
	end

	return provider;
end

local function dm_callback(username, host, datastore, data)
	if host == module.host then
		return false;
	end
	return username, host, datastore, data;
end

local function reject_s2s(event)
	event.origin:close({condition = "not-allowed", text = "Remote communication to this entity is forbidden"});
end

if not module:get_option_boolean("allow_anonymous_s2s", false) then
	module:hook("route/remote", function (event)
		return false; -- Block outgoing s2s from anonymous users
	end, 300);
	module:hook("s2sin-established", reject_s2s, 300);
	module:hook("stanza/jabber:server:dialback:result", reject_s2s, 300);
end

function module.load()
	datamanager.add_callback(dm_callback);
	my_host.anonymous_host = true;
end
function module.unload()
	datamanager.remove_callback(dm_callback);
	my_host.anonymous_host = nil;
end

module:add_item("auth-provider", new_default_provider(module.host));

