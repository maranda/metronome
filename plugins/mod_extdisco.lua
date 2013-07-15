-- * Metronome IM *
--
-- This file is part of the Metronome XMPP server and is released under the
-- ISC License, please see the LICENSE file in this source package for more
-- information about copyright and licensing.

local st = require "util.stanza";

local services = module:get_option_table("external_services", {});

local xmlns_extdisco = "urn:xmpp:extdisco:1";

module:add_feature(xmlns_extdisco);

module:hook("config-reloaded", function() 
	services = module:get_option_table("external_services"); 
end);

module:hook("iq-get/host/"..xmlns_extdisco..":services", function (event)
	local origin, stanza = event.origin, event.stanza;
	local service = stanza:get_child("service", xmlns_extdisco);
	local service_type = service and service.attr.type;
	local reply = st.reply(stanza);

	for host, service_info in pairs(services) do
		if not(service_type) or service_info.type == service_type then
			reply:tag("service", {
				host = host;
				port = service_info.port;
				transport = service_info.transport;
				type = service_info.type;
				username = service_info.username;
				password = service_info.password;
			}):up();
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
