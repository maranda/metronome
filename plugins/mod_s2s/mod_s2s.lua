-- * Metronome IM *
--
-- This file is part of the Metronome XMPP server and is released under the
-- ISC License, please see the LICENSE file in this source package for more
-- information about copyright and licensing.
--
-- As per the sublicensing clause, this file is also MIT/X11 Licensed.
-- ** Copyright (c) 2012-2013, Kim Alvefur, Matthew Wild, Waqas Hussain

module:set_global();

local metronome = metronome;
local hosts = metronome.hosts;

local tostring, type, now = tostring, type, os.time;
local t_insert = table.insert;
local xpcall, traceback = xpcall, debug.traceback;

local add_task = require "util.timer".add_task;
local st = require "util.stanza";
local initialize_filters = require "util.filters".initialize;
local nameprep = require "util.encodings".stringprep.nameprep;
local new_xmpp_stream = require "util.xmppstream".new;
local is_module_loaded = require "core.modulemanager".is_loaded;
local load_module = require "core.modulemanager".load;
local s2s_new_incoming = require "util.s2smanager".new_incoming;
local s2s_new_outgoing = require "util.s2smanager".new_outgoing;
local s2s_destroy_session = require "util.s2smanager".destroy_session;
local s2s_mark_connected = require "util.s2smanager".mark_connected;
local uuid_gen = require "util.uuid".generate;
local cert_verify_identity = require "util.x509".verify_identity;

local s2sout = module:require("s2sout");

local connect_timeout = module:get_option_number("s2s_timeout", 90);
local stream_close_timeout = module:get_option_number("s2s_close_timeout", 5);
local s2s_strict_mode = module:get_option_boolean("s2s_strict_mode", false);
local require_encryption = module:get_option_boolean("s2s_require_encryption", not metronome.no_encryption);
local max_inactivity = module:get_option_number("s2s_max_inactivity", 1800);
local check_inactivity = module:get_option_number("s2s_check_inactivity", 900);
local encryption_exceptions = module:get_option_set("s2s_encryption_exceptions", {});
if connect_timeout < 60 then connect_timeout = 60; end

local sessions = module:shared("sessions");

local log = module._log;
local fire_event = metronome.events.fire_event;

local xmlns_stream = "http://etherx.jabber.org/streams";

--- Handle stanzas to remote domains

module:add_timer(check_inactivity, function()
	module:log("debug", "checking incoming streams for inactivity...");
	for session in pairs(metronome.incoming_s2s) do
		if now() - session.last_receive > max_inactivity then session:close(); end
	end
	module:log("debug", "checking outgoing streams for inactivity...");
	for _, host in pairs(hosts) do
		for domain, session in pairs(host.s2sout) do
			if not session.notopen and now() - session.last_send > max_inactivity then session:close(); end
		end
	end
	return check_inactivity;
end);

local bouncy_stanzas = { message = true, presence = true, iq = true };
local function bounce_sendq(session, reason)
	local sendq = session.sendq;
	if not sendq then return; end
	session.log("info", "sending error replies for "..#sendq.." queued stanzas because of failed outgoing connection to "..tostring(session.to_host));
	local dummy = {
		type = "s2sin";
		send = function(s)
			(session.log or log)("error", "Replying to a s2s error reply, please report this! Stanza: %s Traceback: %s", tostring(s), traceback());
		end;
		dummy = true;
	};
	for i, data in ipairs(sendq) do
		local reply = data[2];
		if reply and not(reply.attr.xmlns) and bouncy_stanzas[reply.name] then
			reply.attr.type = "error";
			reply:tag("error", {type = "cancel"})
				:tag("remote-server-not-found", {xmlns = "urn:ietf:params:xml:ns:xmpp-stanzas"}):up();
			if reason then
				reply:tag("text", {xmlns = "urn:ietf:params:xml:ns:xmpp-stanzas"})
					:text("Server-to-server connection failed: "..reason):up();
			end
			fire_event("route/process", dummy, reply);
		end
		sendq[i] = nil;
	end
	session.sendq = nil;
end

-- Handles stanzas to existing s2s sessions
function route_to_existing_session(event)
	local from_host, to_host, stanza = event.from_host, event.to_host, event.stanza;
	if not hosts[from_host] then
		log("warn", "Attempt to send stanza from %s - a host we don't serve", from_host);
		return false;
	end
	local host = hosts[from_host].s2sout[to_host];
	if host then
		host.last_send = now();
		-- We have a connection to this host already
		if host.type == "s2sout_unauthed" and (stanza.name ~= "db:verify" or not host.dialback_key) then
			(host.log or log)("debug", "trying to send over unauthed s2sout to "..to_host);

			-- Queue stanza until we are able to send it
			if host.sendq then 
				t_insert(host.sendq, { tostring(stanza), stanza.attr.type ~= "error" and stanza.attr.type ~= "result" and st.reply(stanza) });
			else 
				host.sendq = { { tostring(stanza), stanza.attr.type ~= "error" and stanza.attr.type ~= "result" and st.reply(stanza) } };
			end
			host.log("debug", "stanza [%s] queued ", stanza.name);
			-- Retry to authenticate using dialback...
			if host.can_do_dialback then hosts[from_host].events.fire_event("s2s-dialback-again", host); end
			return true;
		elseif host.type == "local" or host.type == "component" then
			log("error", "Trying to send a stanza to ourselves??")
			log("error", "Traceback: %s", traceback());
			log("error", "Stanza: %s", tostring(stanza));
			return false;
		else
			(host.log or log)("debug", "going to send stanza to "..to_host.." from "..from_host);
			-- FIXME
			if host.from_host ~= from_host then
				log("error", "WARNING! This might, possibly, be a bug, but it might not...");
				log("error", "We are going to send from %s instead of %s", tostring(host.from_host), tostring(from_host));
			end
			if host.sends2s(stanza) then
				host.log("debug", "stanza sent over %s", host.type);
				return true;
			end
		end
	end
end

local function session_open_stream(session, from, to)
	local from = from or session.from_host;
	local to = to or session.to_host;
	local direction = session.direction;
	local db = (not s2s_strict_mode and true) or hosts[direction == "outgoing" and from or to].dialback_capable;
	local attr = {
		xmlns = "jabber:server", 
		["xmlns:db"] = db and "jabber:server:dialback" or nil,
		["xmlns:stream"] = xmlns_stream,
		id = session.streamid,
		from = from, to = to,
		version = session.version and (session.version > 0 and "1.0" or nil), 
	};
	
	session.sends2s("<?xml version='1.0'?>");
	session.sends2s(st.stanza("stream:stream", attr):top_tag());
end

-- Create a new outgoing session for a stanza
function route_to_new_session(event)
	local from_host, to_host, from_multiplexed, verify_only, stanza =
		event.from_host, event.to_host, event.from_multiplexed, event.verify_only, event.stanza;
	log("debug", "opening a new outgoing connection for this stanza");
	local host_session = s2s_new_outgoing(from_host, to_host);

	-- Store in buffer
	host_session.bounce_sendq = bounce_sendq;
	host_session.open_stream = session_open_stream;
	if from_multiplexed then host_session.from_multiplexed = from_multiplexed; end
	if verify_only then host_session.verify_only = verify_only; end

	host_session.sendq = { { tostring(stanza), stanza.attr.type ~= "error" and stanza.attr.type ~= "result" and st.reply(stanza) } };
	log("debug", "stanza [%s] queued until connection complete", tostring(stanza.name));
	s2sout.initiate_connection(host_session);
	if (not host_session.connecting) and (not host_session.conn) then
		log("warn", "Connection to %s failed already, destroying session...", to_host);
		s2s_destroy_session(host_session, "Connection failed");
		return false;
	end
	return true;
end

--- Helper to check that a session peer's certificate is valid
local function check_cert_status(session, from, to)
	local conn = session.conn:socket();
	local cert;
	if conn.getpeercertificate then
		cert = conn:getpeercertificate();
	end

	if cert then
		local chain_valid, errors;
		if conn.getpeerverification then						
			chain_valid, errors = conn:getpeerverification();
			errors = type(errors) == "nil" and {} or errors;
		else
			chain_valid, errors = false, { { "This version of LuaSec doesn't support peer verification" } };
		end

		-- Is there any interest in printing out all/the number of errors here?
		if not chain_valid then
			(session.log or log)("debug", "certificate chain validation result: invalid");
			for depth, t in ipairs(errors) do
				(session.log or log)("debug", "certificate error(s) at depth %d: %s", depth-1, table.concat(t, ", "));
			end
			session.cert_chain_status = "invalid";
		else
			(session.log or log)("debug", "certificate chain validation result: valid");
			session.cert_chain_status = "valid";

			local host = session.direction == "incoming" and (from or session.from_host) or (to or session.to_host);

			-- We'll go ahead and verify the asserted identity if the
			-- connecting server specified one.
			if host then
				if cert_verify_identity(host, "xmpp-server", cert) then
					session.cert_identity_status = "valid";
				else
					session.cert_identity_status = "invalid";
				end
			end
		end
	end
end

function module.add_host(module)
	module:set_component_inheritable();

	local modules_disabled = module:get_option_set("modules_disabled", {});
	if not s2s_strict_mode then
		module:depends("dialback");
	else
		if not is_module_loaded(module.host, "dialback") and not modules_disabled:contains("dialback") then
			load_module(module.host, "dialback");
		end
	end
	if not is_module_loaded(module.host, "sasl_s2s") and not modules_disabled:contains("sasl_s2s") then
		load_module(module.host, "sasl_s2s");
	end
	module:hook_stanza(xmlns_stream, "features", function(origin, stanza)
		if origin.type == "s2sout_unauthed" then
			if origin.verify_only then -- we only should verify
				for i, queued in ipairs(origin.sendq) do
					if queued[2].name == "db:verify" then origin.sends2s(queued[1]); break; end
				end
				origin.sendq = nil; return true;
			end
			if not origin.can_do_dialback then
				module:log("warn", "Remote server doesn't offer any mean of (known) authentication, closing stream(s)");
				origin:close({ condition = "unsupported-feature", text = "Unable to authenticate at this time" }, "couldn't authenticate with the remote server");
			end
		end
		return true;
	end, -100)
	module:hook("route/remote", route_to_existing_session, 200);
	module:hook("route/remote", route_to_new_session, 100);
	module:hook("s2s-authenticated", function(event)
		-- Everytime you remove this return a kitten dies... And we no want good kittehs die ye?
		return true;
	end, -100);
	module:hook("s2s-check-certificate-status", check_cert_status);
	module:hook("s2s-no-encryption", function(session)
		local to = session.to_host;
		if encryption_exceptions:contains(session.from_multiplexed) then
			return;
		elseif not encryption_exceptions:contains(to) then
			session:close({
				condition = "policy-violation",
				text = "TLS encryption is mandatory but was not offered" }, "authentication failure");
			return true;
		end
		return;
	end)
end

--- XMPP stream event handlers

local stream_callbacks = { default_ns = "jabber:server" };

local xmlns_xmpp_streams = "urn:ietf:params:xml:ns:xmpp-streams";

function stream_callbacks.streamopened(session, attr)
	local send = session.sends2s;
	
	session.version = tonumber(attr.version) or 0;

	if session.conn:ssl() and session.secure == nil then -- Direct TLS s2s connection
		session.secure = true;
		if session.direction == "incoming" then
			session.direct_tls_s2s = true;
		end
	end
	
	if session.secure == false then
		session.secure = true;
	end

	if session.direction == "incoming" then
		-- Send a reply stream header
		
		-- Validate to/from
		local to, from = nameprep(attr.to), nameprep(attr.from);
		if not to and attr.to then -- COMPAT: Some servers do not reliably set 'to' (especially on stream restarts)
			session:close({ condition = "improper-addressing", text = "Invalid 'to' address" });
			return;
		end
		if not from and attr.from then -- COMPAT: Some servers do not reliably set 'from' (especially on stream restarts)
			session:close({ condition = "improper-addressing", text = "Invalid 'from' address" });
			return;
		end
		
		-- Set session.[from/to]_host if they have not been set already and if
		-- this session isn't already authenticated
		if session.type == "s2sin_unauthed" and from and not session.from_host then
			session.from_host = from;
		elseif from ~= session.from_host then
			session:close({ condition = "improper-addressing", text = "New stream 'from' attribute does not match original" });
			return;
		end
		if session.type == "s2sin_unauthed" and to and not session.to_host then
			session.to_host = to;
		elseif to ~= session.to_host then
			session:close({ condition = "improper-addressing", text = "New stream 'to' attribute does not match original" });
			return;
		end
		
		-- For convenience we'll put the sanitised values into these variables
		to, from = session.to_host, session.from_host;
		
		session.streamid = uuid_gen();
		(session.log or log)("debug", "Incoming s2s received %s", st.stanza("stream:stream", attr):top_tag());
		if to then
			if not hosts[to] then
				-- Attempting to connect to a host we don't serve
				session:close({
					condition = "host-unknown";
					text = "This host does not serve "..to
				});
				return;
			elseif not hosts[to].modules.s2s then
				-- Attempting to connect to a host that disallows s2s
				session:close({
					condition = "policy-violation";
					text = "Server-to-server communication is disabled for this host";
				});
				return;
			end
		end

		if (not to or not from) and s2s_strict_mode then
			session:close({ condition = "improper-addressing", text = "No to or from attributes on stream header" });
			return;
		end
		session.open_stream = session_open_stream;
		session:open_stream();

		if session.version >= 1.0 then
			local features = st.stanza("stream:features");
			
			if to then
				hosts[to].events.fire_event("s2s-stream-features", { origin = session, features = features });
			else
				(session.log or log)("warn", "No 'to' on stream header from %s means we can't offer any features", from or "unknown host");
			end
			
			log("debug", "Sending stream features: %s", tostring(features));
			send(features);
		end
	elseif session.direction == "outgoing" then
		-- If we are just using the connection for verifying dialback keys, we won't try and auth it
		if not attr.id then
			log("error", "stream response did not give us a streamid!");
			session:close({ condition = "undefined-condition", text = "ID on the stream response is missing" });
			return;
		end
		session.streamid = attr.id;

		-- If server is pre-1.0, don't wait for features, just do dialback
		if session.version < 1.0 then
			local from, to = session.from_host, session.to_host;
			if require_encryption and hosts[from].ssl_ctx and
			   not encryption_exceptions:contains(to) and not encryption_exceptions:contains(session.from_multiplexed) then
				-- pre-1.0 servers won't support tls perhaps they should be excluded
				session:close("unsupported-version", "error communicating with the remote server");
				return;
			end
		
			if hosts[from].dialback_capable then
				hosts[from].events.fire_event("s2s-authenticate-legacy", session);
			else
				session:close("internal-server-error", "unable to authenticate, dialback is not available");
				return;
			end
		elseif session.secure and not session.verify_only and not session.cert_chain_status then
			check_cert_status(session);
		end
	end
	session.notopen = nil;
end

function stream_callbacks.streamclosed(session)
	(session.log or log)("debug", "Received </stream:stream>");
	session:close(false);
end

function stream_callbacks.error(session, error, data)
	if error == "no-stream" then
		session:close("invalid-namespace");
	elseif error == "parse-error" then
		session.log("debug", "Server-to-server XML parse error: %s", tostring(error));
		session:close("not-well-formed");
	elseif error == "stream-error" then
		local condition, text = "undefined-condition";
		for child in data:children() do
			if type(child.attr) == "table" and child.attr.xmlns == xmlns_xmpp_streams then
				if child.name ~= "text" then
					condition = child.name;
				else
					text = child:get_text();
				end
				if condition ~= "undefined-condition" and text then
					break;
				end
			end
		end
		text = condition .. (text and (" ("..text..")") or "");
		session.log("info", "Session closed by remote with error: %s", text);
		session:close(nil, text);
	end
end

local function handleerr(err) log("error", "Traceback[s2s]: %s: %s", tostring(err), traceback()); end
function stream_callbacks.handlestanza(session, stanza)
	if stanza.attr.xmlns == "jabber:client" then
		stanza.attr.xmlns = nil;
	end
	stanza = session.filter("stanzas/in", stanza);
	if stanza then
		return xpcall(function () return fire_event("route/process", session, stanza) end, handleerr);
	end
end

local listener = {};

--- Session methods
local stream_xmlns_attr = {xmlns = "urn:ietf:params:xml:ns:xmpp-streams"};
local default_stream_attr = { ["xmlns:stream"] = xmlns_stream, xmlns = stream_callbacks.default_ns, version = "1.0", id = "" };
local function session_close(session, reason, remote_reason)
	local log = session.log or log;
	if session.conn then
		if session.notopen then
			session.sends2s("<?xml version='1.0'?>");
			session.sends2s(st.stanza("stream:stream", default_stream_attr):top_tag());
		end
		if reason then -- nil == no err, initiated by us, false == initiated by remote
			local stanza = st.stanza("stream:error");
			if type(reason) == "string" then -- assume stream error
				log("debug", "Disconnecting %s[%s], <stream:error> is: %s", session.host or "(unknown host)", session.type, reason);
				session.sends2s(stanza:tag(reason, {xmlns = "urn:ietf:params:xml:ns:xmpp-streams" }));
			elseif type(reason) == "table" then
				if reason.condition then
					stanza:tag(reason.condition, stream_xmlns_attr):up();
					if reason.text then
						stanza:tag("text", stream_xmlns_attr):text(reason.text):up();
					end
					if reason.extra then
						stanza:add_child(reason.extra);
					end
					log("debug", "Disconnecting %s[%s], <stream:error> is: %s", session.host or "(unknown host)", session.type, tostring(stanza));
					session.sends2s(stanza);
				elseif reason.name then -- a stanza
					log("debug", "Disconnecting %s->%s[%s], <stream:error> is: %s", session.from_host or "(unknown host)", session.to_host or "(unknown host)", session.type, tostring(reason));
					session.sends2s(reason);
				end
			end
		elseif reason == nil then
			if session.type == "s2sin" and hosts[session.to_host] then
				local event_data = { session = session };
				metronome.events.fire_event("s2sin-pre-destroy", event_data);
				hosts[session.to_host].events.fire_event("s2sin-pre-destroy", event_data);
			elseif session.type == "s2sout" and hosts[session.from_host] then
				local event_data = { session = session };
				metronome.events.fire_event("s2sout-pre-destroy", event_data);
				hosts[session.from_host].events.fire_event("s2sout-pre-destroy", event_data);				
			end
		end

		if not reason then session.graceful_close = true; end

		session.sends2s("</stream:stream>");
		function session.sends2s() return false; end
		
		local reason = remote_reason or (reason and (reason.text or reason.condition)) or reason;
		session.log("info", "%s s2s stream %s->%s closed: %s", session.direction, session.from_host or "(unknown host)", session.to_host or "(unknown host)", reason or "stream closed");
		
		-- Authenticated incoming stream may still be sending us stanzas, so wait for </stream:stream> from remote
		local conn = session.conn;
		if reason == nil and not session.notopen and session.type == "s2sin" then
			add_task(stream_close_timeout, function ()
				if not session.destroyed then
					session.log("warn", "Failed to receive a stream close response, closing connection anyway...");
					s2s_destroy_session(session, reason);
					sessions[conn] = nil;
					conn:close();
				end
			end);
		else
			s2s_destroy_session(session, reason);
			sessions[conn] = nil;
			conn:close(); -- Close immediately, as this is an outgoing connection or is not authed
		end
	end
end

-- Session initialization logic shared by incoming and outgoing
local function initialize_session(session)
	local stream = new_xmpp_stream(session, stream_callbacks);
	session.stream = stream;
	
	session.notopen = true;
		
	function session.reset_stream()
		session.notopen = true;
		session.stream:reset();
	end
	
	local filter = session.filter;
	function session.data(data)
		data = filter("bytes/in", data);
		if data then
			local ok, err = stream:feed(data);
			if ok then return; end
			(session.log or log)("warn", "Received invalid XML: %s", data);
			(session.log or log)("warn", "Problem was: %s", err);
			session:close("not-well-formed");
		end
	end

	session.close = session_close;

	local handlestanza = stream_callbacks.handlestanza;
	function session.dispatch_stanza(session, stanza)
		return handlestanza(session, stanza);
	end
	
	if session.type == "s2sin_unauthed" then
		session.last_receive = now();
	elseif session.type == "s2sout_unauthed" then
		session.last_send = now();
	end

	add_task(connect_timeout, function ()
		if session.type == "s2sin" or session.type == "s2sout" then
			return; -- Ok, we're connected
		end
		-- Not connected, need to close session and clean up
		if session.type ~= "s2s_destroyed" then
			(session.log or log)("debug", "Destroying incomplete session %s->%s due to inactivity",
			session.from_host or "(unknown)", session.to_host or "(unknown)");
			session:close("connection-timeout");
		end
	end);
end

function listener.onconnect(conn)
	local session = sessions[conn];
	if not session then -- New incoming connection
		local filtered = module:fire_event("s2s-new-incoming-connection", { ip = conn:ip(), conn = conn });
		if filtered then return; end

		session = s2s_new_incoming(conn);
		sessions[conn] = session;
		session.log("debug", "Incoming s2s connection");

		local filter = initialize_filters(session);
		local w = conn.write;
		session.sends2s = function (t)
			log("debug", "sending: %s", t.top_tag and t:top_tag() or t:match("^([^>]*>?)"));
			if t.name then
				t = filter("stanzas/out", t);
			end
			if t then
				t = filter("bytes/out", tostring(t));
				if t then
					return w(conn, t);
				end
			end
		end
	
		initialize_session(session);
	else -- Outgoing session connected
		session:open_stream(session.from_host, session.to_host);
	end
end

function listener.onincoming(conn, data)
	local session = sessions[conn];
	if session then
		session.last_receive = now();
		session.data(data);
	end
end
	
function listener.onstatus(conn, status)
	if status == "ssl-handshake-complete" then
		local session = sessions[conn];
		if session and session.direction == "outgoing" then
			session.log("debug", "Sending stream header...");
			session:open_stream(session.from_host, session.to_host);
		end
	end
end

function listener.ondisconnect(conn, err)
	local session = sessions[conn];
	if session then
		sessions[conn] = nil;
		if err and session.direction == "outgoing" and session.notopen then
			(session.log or log)("debug", "s2s connection attempt failed: %s", err);
			if s2sout.attempt_connection(session, err) then
				(session.log or log)("debug", "...so we're going to try another target");
				return; -- Session lives for now
			end
		end
		(session.log or log)("debug", "s2s disconnected: %s->%s (%s)", tostring(session.from_host), tostring(session.to_host), tostring(err or "connection closed"));
		s2s_destroy_session(session, err);
	end
end

function listener.register_outgoing(conn, session)
	session.direction = "outgoing";
	sessions[conn] = session;
	initialize_session(session);
end

s2sout.set_listener(listener);

module:hook("config-reloaded", function()
	connect_timeout = module:get_option_number("s2s_timeout", 90);
	stream_close_timeout = module:get_option_number("s2s_close_timeout", 5);
	s2s_strict_mode = module:get_option_boolean("s2s_strict_mode", false);
	require_encryption = module:get_option_boolean("s2s_require_encryption", not metronome.no_encryption);
	max_inactivity = module:get_option_number("s2s_max_inactivity", 1800);
	check_inactivity = module:get_option_number("s2s_check_inactivity", 900);
	encryption_exceptions = module:get_option_set("s2s_encryption_exceptions", {});
	if connect_timeout < 60 then connect_timeout = 60; end
end);

module:hook("host-deactivating", function(event)
	local host, host_session, reason = event.host, event.host_session, event.reason;
	if host_session.s2sout then
		for remotehost, session in pairs(host_session.s2sout) do
			if session.close then
				log("debug", "Closing outgoing connection to %s", remotehost);
				if session.srv_hosts then session.srv_hosts = nil; end
				session:close(reason);
			end
		end
	end
	for remote_session in pairs(metronome.incoming_s2s) do
		if remote_session.to_host == host then
			module:log("debug", "Closing incoming connection from %s", remote_session.from_host or "<unknown>");
			remote_session:close(reason);
		end
	end
end, -2);

module:add_item("net-provider", {
	name = "s2s",
	listener = listener,
	default_port = 5269,
	encryption = "starttls",
	multiplex = {
		pattern = "^<.*:stream.*%sxmlns%s*=%s*(['\"])jabber:server%1.*>"
	}
});

module:add_item("net-provider", {
	name = "s2s_secure",
	listener = listener,
	encryption = "ssl"
});

