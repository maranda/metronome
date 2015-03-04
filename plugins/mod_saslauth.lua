-- * Metronome IM *
--
-- This file is part of the Metronome XMPP server and is released under the
-- ISC License, please see the LICENSE file in this source package for more
-- information about copyright and licensing.
--
-- As per the sublicensing clause, this file is also MIT/X11 Licensed.
-- ** Copyright (c) 2009-2011, Kim Alvefur, Matthew Wild, Nick Thomas, Paul Aurich, Waqas Hussain

local st = require "util.stanza";
local sm_make_authenticated = require "core.sessionmanager".make_authenticated;
local base64 = require "util.encodings".base64;
local usermanager_get_sasl_handler = require "core.usermanager".get_sasl_handler;
local offer_external = module:require "sasl_aux".offer_external;
local ipairs, tostring = ipairs, tostring;
local host_session = hosts[module.host];

local no_encryption = metronome.no_encryption;
local secure_auth_only = module:get_option_boolean("c2s_require_encryption", not no_encryption);
local allow_unencrypted_plain_auth = module:get_option_boolean("allow_unencrypted_plain_auth", false);
local blacklisted_mechanisms = module:get_option_set("blacklist_sasl_mechanisms");
local auth_failures = module:get_option_number("allowed_sasl_failures", 3);

local log = module._log;

local xmlns_sasl = "urn:ietf:params:xml:ns:xmpp-sasl";

local function reload()
	secure_auth_only = module:get_option_boolean("c2s_require_encryption", not no_encryption);
	allow_unencrypted_plain_auth = module:get_option_boolean("allow_unencrypted_plain_auth", false);
	blacklisted_mechanisms = module:get_option_set("blacklist_sasl_mechanisms");
	auth_failures = module:get_option_number("allowed_sasl_failures", 3);
end
module:hook_global("config-reloaded", reload);

local function build_reply(status, ret, err_msg)
	local reply = st.stanza(status, {xmlns = xmlns_sasl});
	if status == "challenge" then
		reply:text(ret and base64.encode(ret) or nil);
	elseif status == "failure" then
		reply:tag(ret):up();
		if err_msg then reply:tag("text"):text(err_msg); end
	elseif status == "success" then
		reply:text(ret and base64.encode(ret) or nil);
	else
		module:log("error", "Unknown sasl status: %s", status);
	end
	return reply;
end

local function handle_status(session, status, ret, err_msg)
	if status == "failure" then
		session.sasl_handler = session.sasl_handler:clean_clone();
	elseif status == "success" then
		local ok, err = sm_make_authenticated(session, session.sasl_handler.username);
		session.auth_failures = nil;
		if ok then
			module:fire_event("authentication-success", { session = session });
			session.sasl_handler = nil;
			session:reset_stream();
		else
			module:log("warn", "SASL succeeded but username was invalid");
			module:fire_event("authentication-failure", { session = session, condition = "not-authorized", text = err });
			session.sasl_handler = session.sasl_handler:clean_clone();
			return "failure", "not-authorized", "User authenticated successfully, but username was invalid";
		end
	end
	return status, ret, err_msg;
end

local function sasl_process_cdata(session, stanza)
	local text = stanza[1];
	if text then
		text = base64.decode(text);
		if not text then
			session.sasl_handler = nil;
			session.send(build_reply("failure", "incorrect-encoding"));
			return true;
		end
	end
	local status, ret, err_msg = session.sasl_handler:process(text);
	status, ret, err_msg = handle_status(session, status, ret, err_msg);
	local s = build_reply(status, ret, err_msg);
	log("debug", "sasl reply: %s", tostring(s));
	session.send(s);

	if status == "failure" then
		session.auth_failures = (session.auth_failures or 0) + 1;
		module:fire_event("authentication-failure", { session = session, condition = ret, text = err_msg });
	end
	return true;
end

module:hook("stanza/urn:ietf:params:xml:ns:xmpp-sasl:auth", function(event)
	local session, stanza = event.origin, event.stanza;

	if session.type ~= "c2s_unauthed" then return; end

	if session.sasl_handler and session.sasl_handler.selected then
		session.sasl_handler = nil; -- allow starting a new SASL negotiation before completing an old one
	end
	if not session.sasl_handler then
		session.sasl_handler = usermanager_get_sasl_handler(module.host, session);
	end
	local mechanism = stanza.attr.mechanism;
	if not session.secure and
	   ((secure_auth_only and host_session.ssl_ctx_in) or (mechanism == "PLAIN" and not allow_unencrypted_plain_auth)) then
		session.send(build_reply("failure", "encryption-required"));
		return true;
	end
	local valid_mechanism = session.sasl_handler:select(mechanism);
	if not valid_mechanism then
		session.send(build_reply("failure", "invalid-mechanism"));
		return true;
	end
	return sasl_process_cdata(session, stanza);
end);
module:hook("stanza/urn:ietf:params:xml:ns:xmpp-sasl:response", function(event)
	local session = event.origin;
	if not(session.sasl_handler and session.sasl_handler.selected) then
		session.send(build_reply("failure", "not-authorized", "Out of order SASL element"));
		return true;
	end
	return sasl_process_cdata(session, event.stanza);
end);
module:hook("stanza/urn:ietf:params:xml:ns:xmpp-sasl:abort", function(event)
	local session = event.origin;
	session.sasl_handler = nil;
	session.send(build_reply("failure", "aborted"));
	return true;
end);

module:hook("authentication-failure", function(event)
	local session = event.session;
	if session.auth_failures > auth_failures then
		session:close{ condition = "policy-violation", text = "Exceeded max failed authentication attempts, bye." };
	end
end, -1);

local mechanisms_attr = { xmlns = "urn:ietf:params:xml:ns:xmpp-sasl" };
module:hook("stream-features", function(event)
	local origin, features = event.origin, event.features;
	if not origin.username then
		if secure_auth_only and not origin.secure and host_session.ssl_ctx_in then
			return;
		end
		origin.sasl_handler = usermanager_get_sasl_handler(module.host, origin);
		local mechanisms = st.stanza("mechanisms", mechanisms_attr);
		for _, mechanism in ipairs(origin.sasl_handler:mechanisms()) do
			if not blacklisted_mechanisms or not blacklisted_mechanisms:contains(mechanism) then
				if ((mechanism == "PLAIN" and origin.secure) or allow_unencrypted_plain_auth) or
				   (mechanism == "EXTERNAL" and offer_external(origin)) or
				   (mechanism ~= "EXTERNAL" and mechanism ~= "PLAIN") then
					mechanisms:tag("mechanism"):text(mechanism):up();
				end
			end
		end
		if mechanisms[1] then features:add_child(mechanisms); end
	end
end, 99);
