-- * Metronome IM *
--
-- This file is part of the Metronome XMPP server and is released under the
-- ISC License, please see the LICENSE file in this source package for more
-- information about copyright and licensing.

-- This module builds a vCard4 and marks the server as public service,
-- by adding "urn:xmpp:public-server" between features.

local my_host = module.host;
local st = require "util.stanza";

module:depends("server_presence");
module:add_feature("urn:xmpp:public-server");

local vcard4_xmlns = "urn:ietf:params:xml:ns:vcard-4.0";
local server_vcard = module:get_option_table("public_service_vcard", {});

-- Build Service vCard4

local vcard;

local function build_vcard()
	vcard = st.stanza("vcard", { xmlns = vcard4_xmlns });
	vcard:tag("kind"):tag("text"):text("application"):up():up();
	vcard:tag("name"):tag("text"):text("Metronome"):up():up();
	vcard:tag("fn"):tag("text"):text(my_host):up():up();
	
	if server_vcard.name then vcard:tag("note"):tag("text"):text(server_vcard.name):up():up(); end
	if server_vcard.url then vcard:tag("url"):tag("uri"):text(server_vcard.url):up():up(); end
	if server_vcard.foundation_year then vcard:tag("bday"):tag("date"):text(server_vcard.foundation_year):up():up(); end
	if server_vcard.country then vcard:tag("adr"):tag("country"):text(server_vcard.country):up():up(); end
	if server_vcard.email then vcard:tag("email"):tag("uri"):text(server_vcard.email):up():up(); end
	if server_vcard.admin_jid then vcard:tag("impp"):tag("uri"):text("xmpp:"..server_vcard.admin_jid):up():up(); end
	if server_vcard.geo then vcard:tag("geo"):tag("uri"):text("geo:"..server_vcard.geo):up():up(); end
	if server_vcard.ca then
		local ca = server_vcard.ca;
		vcard:tag("ca")
			:tag("name"):text(ca.name):up()
			:tag("uri"):text(ca.url):up():up();
	end
	if server_vcard.oob_registration_uri then
		vcard:tag("registration", { xmlns = "urn:xmpp:vcard:registration:1" }):tag("uri"):text(server_vcard.oob_registration_uri):up():up();
	end
	
	hosts[my_host].public_service_vcard = vcard;
end

local function handle_vcard(event)
	local origin, stanza = event.origin, event.stanza;
	local reply = st.reply(stanza):add_child(vcard);
	module:log("info", "sending public service vcard to %s...", stanza.attr.from);
	return origin.send(reply);
end

local function handle_reload()
	server_vcard = module:get_option_table("public_service_vcard", {});
	build_vcard();
end

function module.load() build_vcard(); end

module:hook_global("config-reloaded", handle_reload);
module:hook("iq-get/host/"..vcard4_xmlns..":vcard", handle_vcard, 30);
	
