-- * Metronome IM *
--
-- This file is part of the Metronome XMPP server and is released under the
-- ISC License, please see the LICENSE file in this source package for more
-- information about copyright and licensing.

local st = require "util.stanza";
local sm_bind_resource = require "core.sessionmanager".bind_resource;
local join = require "util.jid".join;

local xmlns_bind = "urn:ietf:params:xml:ns:xmpp-bind";
local xmlns_legacy = "urn:ietf:params:xml:ns:xmpp-session";
local bind_attr = { xmlns = xmlns_bind };
local legacy_attr = { xmlns = xmlns_legacy };

local bare_sessions, next = bare_sessions, next;

local legacy = module:get_option_boolean("legacy_session_support", "true");
local resources_limit = module:get_option_number("max_client_resources", 9);

local function limit_binds(session)
	local sessions = bare_sessions[join(session.username, session.host)];
	if sessions then
		sessions = sessions.sessions;
	else return; end
	local count, i = 0, nil;
	while next(sessions, i) do count = count + 1; i = next(sessions, i); end
	if count > resources_limit then
		session:close{
			condition = "policy-violation",
			text = "Too many resources bound, please disconnect one of the clients and retry"
		};
		return true;
	end
end

module:hook("stream-features", function(event)
	local origin, features = event.origin, event.features;
	if origin.username then
		features:tag("bind", bind_attr):tag("required"):up():up();
		if legacy then features:tag("session", legacy_attr):up(); end
	end
end, 99);

module:hook("iq-set/self/"..xmlns_bind..":bind", function(event)
	local origin, stanza = event.origin, event.stanza;
	local resource;

	if not origin.resource and limit_binds(origin) then return true; end
	local bind = stanza.tags[1];
	resource = bind:child_with_name("resource");
	resource = resource and #resource.tags == 0 and resource[1] or nil;
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
	local function session_handle(event)
		local origin, stanza = event.origin, event.stanza;
		if origin.username then
			return origin.send(st.reply(stanza));
		else
			return origin.send(st.error_reply(stanza, "auth", "forbidden"));
		end
	end
	module:hook("iq-set/host/"..xmlns_legacy..":session", session_handle);
	module:hook("iq-set/self/"..xmlns_legacy..":session", session_handle);
end
