-- * Metronome IM *
--
-- This file is part of the Metronome XMPP server and is released under the
-- ISC License, please see the LICENSE file in this source package for more
-- information about copyright and licensing.

local st = require "util.stanza";
local base64 = require "util.encodings".base64.encode;
local hmac_sha1 = require "util.hmac".sha1;
local datetime = require "util.datetime".datetime;
local ipairs, pairs, now, tostring = ipairs, pairs, os.time, tostring;

local services = module:get_option_table("external_services", {});
local restricted = module:get_option_boolean("external_services_restricted", true);

local xmlns_extdisco = "urn:xmpp:extdisco:2";
local xmlns_extdisco_legacy = "urn:xmpp:extdisco:1";

module:add_feature(xmlns_extdisco_legacy);
module:add_feature(xmlns_extdisco);

local function generate_nonce(secret, ttl)
	local username = now() + ttl;
	local password = base64(hmac_sha1(secret, username, false));
	return tostring(username), password, datetime(username);
end

local function render(host, type, info, reply, proto)
	if not type or info.type == type then
		local username, password, expires;
		if info.turn_secret and info.turn_ttl then -- generate TURN REST temporal credentials
			username, password, expires = generate_nonce(info.turn_secret, info.turn_ttl);
		end
		reply:tag("service", {
			host = host;
			port = info.port;
			transport = info.transport;
			type = info.type;
			username = username or info.username;
			password = password or info.password;
			ttl = (proto == xmlns_extdisco_legacy and info.turn_ttl and tostring(info.turn_ttl)) or nil;
			expires = (proto == xmlns_extdisco and expires) or nil;
			restricted = (proto == xmlns_extdisco and expires and "1") or nil;
		}):up();
	end
end

local function render_credentials(host, type, info, reply)
	if (not type or type == info.type) and ((info.username and info.password) or (info.turn_secret and info.turn_ttl)) then
		local username, password;
		if info.turn_secret and info.turn_ttl then
			username, password = generate_nonce(info.turn_secret, info.turn_ttl);
		else
			username, password = info.username, info.password;
		end
		reply:tag("service", {
			host = host;
			type = info.type;
			username = username;
			password = password;
		}):up();
		return true;
	end
end

local function process_iq_services(origin, stanza, proto)
	if (origin.host == module.host) or not restricted then
		local service = stanza:get_child("service", proto);
		local service_type = service and service.attr.type;
		local reply = st.reply(stanza);
		reply:tag("services", { xmlns = proto });

		for host, service_info in pairs(services) do
			if #service_info > 0 then
				for i, info in ipairs(service_info) do 
					render(host, service_type, info, reply, proto);
				end
			else
				render(host, service_type, service_info, reply, proto);
			end
		end

		module:log("debug", "%s requested external service data (%s type)...", 
			stanza.attr.from or origin.username .. "@" .. origin.host, service_type or "nil");
		origin.send(reply);
	else
		origin.send(st.error_reply(stanza, "cancel", "not-allowed", "External services information is restricted"));
	end
	return true;
end

local function process_iq_credentials(origin, stanza, proto)
	if (origin.host == module.host) or not restricted then
		local credentials = stanza:get_child("credentials", proto):child_with_name("service");
		if not credentials then	
			origin.send(st.error_reply(stanza, "modify", "bad-request"));
			return true;
		end

		local host, type = credentials.attr.host, credentials.attr.type;
		if not host then
			origin.send(st.error_reply(stanza, "modify", "not-acceptable", "Please specify at least the hostname"));
			return true;
		end

		local service = services[host];
		if not service then
			origin.send(st.error_reply(stanza, "cancel", "item-not-found", "Specified service is not known"));
			return true;
		end

		local reply = st.reply(stanza);
		reply:tag("credentials", { xmlns = proto });
		local found;
		for i, info in pairs(service) do
			found = render_credentials(host, type, info, reply); 
		end
		if not found then
			origin.send(st.error_reply(stanza, "cancel", "item-not-found", "The service doesn't need any credentials"));
			return true;
		end

		module:log("debug", "%s requested external service credentials for service host %s (type %s)...", 
			stanza.attr.from or origin.username .. "@" .. origin.host, host, type or "nil");
		origin.send(reply);
	else
		origin.send(st.error_reply(stanza, "cancel", "not-allowed", "You are forbidden from requesting temporary credentials, sorry"));
	end
	return true;
end

module:hook_global("config-reloaded", function() 
	services = module:get_option_table("external_services", {}); 
end);

module:hook("iq-get/host/"..xmlns_extdisco_legacy..":services", function (event)
	local origin, stanza = event.origin, event.stanza;
	return process_iq_services(origin, stanza, xmlns_extdisco_legacy);
end);

module:hook("iq-get/host/"..xmlns_extdisco_legacy..":credentials", function (event)
	local origin, stanza = event.origin, event.stanza;
	return process_iq_credentials(origin, stanza, xmlns_extdisco_legacy);
end);

module:hook("iq-get/host/"..xmlns_extdisco..":services", function (event)
	local origin, stanza = event.origin, event.stanza;
	return process_iq_services(origin, stanza, xmlns_extdisco);
end);

module:hook("iq-get/host/"..xmlns_extdisco..":credentials", function (event)
	local origin, stanza = event.origin, event.stanza;
	return process_iq_credentials(origin, stanza, xmlns_extdisco);
end);
