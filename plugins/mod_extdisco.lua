-- * Metronome IM *
--
-- This file is part of the Metronome XMPP server and is released under the
-- ISC License, please see the LICENSE file in this source package for more
-- information about copyright and licensing.

local st = require "util.stanza";
local ipairs, pairs = ipairs, pairs;

local services = module:get_option_table("external_services", {});

local xmlns_extdisco = "urn:xmpp:extdisco:1";

module:add_feature(xmlns_extdisco);

local function render(host, type, info, reply)
	if not type or info.type == type then
		reply:tag("service", {
			host = host;
			port = info.port;
			transport = info.transport;
			type = info.type;
			username = info.username;
			password = info.password;
		}):up();
	end
end

module:hook_global("config-reloaded", function() 
	services = module:get_option_table("external_services", {}); 
end);

module:hook("iq-get/host/"..xmlns_extdisco..":services", function (event)
	local origin, stanza = event.origin, event.stanza;
	local service = stanza:get_child("service", xmlns_extdisco);
	local service_type = service and service.attr.type;
	local reply = st.reply(stanza);
	reply:tag("services", { xmlns = xmlns_extdisco });

	for host, service_info in pairs(services) do
		if #service_info > 0 then
			for i, info in ipairs(service_info) do 
				render(host, service_type, info, reply); 
			end
		else
			render(host, service_type, service_info, reply);
		end
	end

	return origin.send(reply);
end);

module:hook("iq-get/host/"..xmlns_extdisco..":credentials", function (event)
	local origin, stanza = event.origin, event.stanza;
	return origin.send(st.error_reply(
		stanza, "cancel", "feature-not-implemented", "Retrieving short-term credentials is not supported"
	));
end);
