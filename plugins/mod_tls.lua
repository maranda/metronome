-- * Metronome IM *
--
-- This file is part of the Metronome XMPP server and is released under the
-- ISC License, please see the LICENSE file in this source package for more
-- information about copyright and licensing.
--
-- As per the sublicensing clause, this file is also MIT/X11 Licensed.
-- ** Copyright (c) 2008-2011, Matthew Wild, Paul Aurich, Tobias Markmann, Waqas Hussain

local config = require "core.configmanager";
local create_context = require "core.certmanager".create_context;
local st = require "util.stanza";

local secure_auth_only = module:get_option_boolean("c2s_require_encryption", false) or module:get_option_boolean("require_encryption", false);
local secure_s2s_only = module:get_option_boolean("s2s_require_encryption", false);
local allow_s2s_tls = module:get_option_boolean("s2s_allow_encryption", true);
if secure_s2s_only then allow_s2s_tls = true; end

local xmlns_starttls = 'urn:ietf:params:xml:ns:xmpp-tls';
local starttls_attr = { xmlns = xmlns_starttls };
local starttls_proceed = st.stanza("proceed", starttls_attr);
local starttls_failure = st.stanza("failure", starttls_attr);
local c2s_feature = st.stanza("starttls", starttls_attr);
local s2s_feature = st.stanza("starttls", starttls_attr);
if secure_auth_only then c2s_feature:tag("required"):up(); end
if secure_s2s_only then s2s_feature:tag("required"):up(); end

local global_ssl_ctx = metronome.global_ssl_ctx;

local host = hosts[module.host];

local function can_do_tls(session)
	if session.type == "c2s_unauthed" then
		return session.conn.starttls and host.ssl_ctx_in;
	elseif session.type == "s2sin_unauthed" and allow_s2s_tls then
		return session.conn.starttls and host.ssl_ctx_in;
	elseif session.direction == "outgoing" and allow_s2s_tls then
		return session.conn.starttls and host.ssl_ctx;
	end
	return false;
end

-- Hook <starttls/>
module:hook("stanza/urn:ietf:params:xml:ns:xmpp-tls:starttls", function(event)
	local origin = event.origin;
	if can_do_tls(origin) then
		(origin.sends2s or origin.send)(starttls_proceed);
		origin:reset_stream();
		local host = origin.to_host or origin.host;
		local ssl_ctx = host and hosts[host].ssl_ctx_in or global_ssl_ctx;
		origin.conn:starttls(ssl_ctx);
		origin.log("debug", "TLS negotiation started for %s...", origin.type);
		origin.secure = false;
	else
		origin.log("warn", "Attempt to start TLS, but TLS is not available on this %s connection", origin.type);
		(origin.sends2s or origin.send)(starttls_failure);
		origin:close();
	end
	return true;
end);

-- Advertize stream feature
module:hook("stream-features", function(event)
	local origin, features = event.origin, event.features;
	if can_do_tls(origin) then
		features:add_child(c2s_feature);
	end
end, 101);
module:hook("s2s-stream-features", function(event)
	local origin, features = event.origin, event.features;
	if can_do_tls(origin) then
		features:add_child(s2s_feature);
	end
end, 101);

-- For s2sout connections, start TLS if we can
module:hook_stanza("http://etherx.jabber.org/streams", "features", function (session, stanza)
	module:log("debug", "Received features element");
	if can_do_tls(session) and stanza:child_with_ns(xmlns_starttls) then
		module:log("debug", "%s is offering TLS, taking up the offer...", session.to_host);
		session.sends2s("<starttls xmlns='"..xmlns_starttls.."'/>");
		return true;
	end
end, 500);

module:hook_stanza(xmlns_starttls, "proceed", function (session, stanza)
	module:log("debug", "Proceeding with TLS on s2sout...");
	session:reset_stream();
	local ssl_ctx = session.from_host and hosts[session.from_host].ssl_ctx or global_ssl_ctx;
	session.conn:starttls(ssl_ctx);
	session.secure = false;
	return true;
end);

function module.load()
	local ssl_config = config.get(module.host, "ssl");
	if not ssl_config then
		local base_host = module.host:match("%.(.*)");
		ssl_config = config.get(base_host, "ssl");
	end
	host.ssl_ctx = create_context(host.host, "client", ssl_config); -- for outgoing connections
	host.ssl_ctx_in = create_context(host.host, "server", ssl_config); -- for incoming connections
end

function module.unload()
	host.ssl_ctx = nil;
	host.ssl_ctx_in = nil;
end

local function reload()
	secure_auth_only = module:get_option_boolean("c2s_require_encryption", false) or module:get_option_boolean("require_encryption", false);
	secure_s2s_only = module:get_option_boolean("s2s_require_encryption", false);
	allow_s2s_tls = module:get_option_boolean("s2s_allow_encryption", true);
	if secure_s2s_only then allow_s2s_tls = true; end
	module.load();
end
module:hook_global("config-reloaded", reload);
