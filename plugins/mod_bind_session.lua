-- * Metronome IM *
--
-- This file is part of the Metronome XMPP server and is released under the
-- ISC License, please see the LICENSE file in this source package for more
-- information about copyright and licensing.

local st = require "util.stanza";
local sm_bind_resource = require "core.sessionmanager".bind_resource;

local xmlns_bind = "urn:ietf:params:xml:ns:xmpp-bind";
local xmlns_legacy = "urn:ietf:params:xml:ns:xmpp-session";
local bind_attr = { xmlns = xmlns_bind };
local legacy_attr = { xmlns = xmlns_legacy };

local legacy = module:get_option_boolean("legacy_session_support", "true");

module:hook("stream-features", function(event)
	local origin, features = event.origin, event.features;
	if origin.username then
		features:tag("bind", bind_attr):tag("required"):up():up();
		if legacy then features:tag("session", legacy_attr):tag("optional"):up():up(); end
	end
end, 96);

module:hook("iq/self/urn:ietf:params:xml:ns:xmpp-bind:bind", function(event)
	local origin, stanza = event.origin, event.stanza;
	local resource;
	if stanza.attr.type == "set" then
		local bind = stanza.tags[1];
		resource = bind:child_with_name("resource");
		resource = resource and #resource.tags == 0 and resource[1] or nil;
	end
	local success, err_type, err, err_msg = sm_bind_resource(origin, resource);
	if success then
		origin.send(st.reply(stanza)
			:tag("bind", { xmlns = xmlns_bind })
			:tag("jid"):text(origin.full_jid));
		origin.log("debug", "Resource bound: %s", origin.full_jid);
	else
		origin.send(st.error_reply(stanza, err_type, err, err_msg));
		origin.log("debug", "Resource bind failed: %s", err_msg or err);
	end
	return true;
end);

if legacy then 
	module:hook("iq/host/urn:ietf:params:xml:ns:xmpp-session:session", function(event)
		return event.origin.send(st.reply(event.stanza));
	end);
end