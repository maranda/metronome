-- * Metronome IM *
--
-- This file is part of the Metronome XMPP server and is released under the
-- ISC License, please see the LICENSE file in this source package for more
-- information about copyright and licensing.
--
-- As per the sublicensing clause, this file is also MIT/X11 Licensed.
-- ** Copyright (c) 2008-2013, Kim Alvefur, Florian Zeitz, Marco Cirillo, Matthew Wild, Paul Aurich, Waqas Hussain

local hosts = metronome.hosts;
local incoming = metronome.incoming_s2s;
local host_session = hosts[module.host];
local s2s_make_authenticated = require "util.s2smanager".make_authenticated;

local log = module._log;
local s2s_strict_mode = module:get_option_boolean("s2s_strict_mode", false);
local no_encryption = metronome.no_encryption;
local require_encryption = module:get_option_boolean("s2s_require_encryption", not no_encryption);
local encryption_exceptions = module:get_option_set("s2s_encryption_exceptions", {});

local st = require "util.stanza";
local sha256_hash = require "util.hashes".sha256;
local nameprep = require "util.encodings".stringprep.nameprep;

local xmlns_db = "jabber:server:dialback";
local xmlns_starttls = "urn:ietf:params:xml:ns:xmpp-tls";
local xmlns_stream = "http://etherx.jabber.org/streams";
local xmlns_stanzas = "urn:ietf:params:xml:ns:xmpp-stanzas";

local dialback_requests = setmetatable({}, { __mode = "v" });

function generate_dialback(id, to, from)
	if hosts[from] then
		return sha256_hash(id..to..from..hosts[from].dialback_secret, true);
	else
		return false;
	end
end

function initiate_dialback(session)
	session.doing_db = true;
	session.dialback_key = generate_dialback(session.streamid, session.to_host, session.from_host);
	session.sends2s(st.stanza("db:result", { from = session.from_host, to = session.to_host }):text(session.dialback_key));
	session.log("info", "sent dialback key on outgoing s2s stream");
end

function verify_dialback(id, to, from, key)
	return key == generate_dialback(id, to, from);
end

function make_authenticated(session, host)
	if session.type == "s2sout_unauthed" then
		local multiplexed_from = session.multiplexed_from;
		if multiplexed_from and not multiplexed_from.destroyed then
			local hosts = multiplexed_from.hosts;
			if not hosts[session.to_host] then
				hosts[session.to_host] = { authed = true };
			else
				hosts[session.to_host].authed = true;
			end
		else
			session.multiplexed_from = nil; -- don't hold destroyed sessions.
		end
	end
	return s2s_make_authenticated(session, host);
end

local function can_do_dialback(origin)
	local db = origin.stream_declared_ns and origin.stream_declared_ns["db"];
	if db == xmlns_db then return true; else return false; end
end

local function exceed_errors(origin)
	origin.db_errors = (origin.db_errors or 0) + 1;

	if origin.db_errors >= 10 then
		origin:close(
			{ condition = "policy-violation", text = "Number of max allowed dialback failures exceeded, good bye" },
			"stream failure"
		);
		return true;
	end
end

local errors_map = {
	["item-not-found"] = "requested host was not found on the remote enitity",
	["remote-connection-failed"] = "the receiving entity failed to connect back to us",
	["remote-server-not-found"] = "encountered an error while attempting to verify dialback, like the server unexpectedly closing the connection",
	["remote-server-timeout"] = "time exceeded while attempting to contact the authoritative server",
	["policy-violation"] = "the receiving entity requires to enable TLS before executing dialback",
	["not-authorized"] = "the receiving entity denied dialback, probably because it requires a valid certificate",
	["forbidden"] = "received a response of type invalid while authenticating with the authoritative server",
	["not-acceptable"] = "the receiving entity was unable to assert our identity"
};
local function handle_db_errors(origin, stanza)
	local attr = stanza.attr;
	local condition = stanza:child_with_name("error") and stanza:child_with_name("error")[1];
	local err = condition and errors_map[condition.name];
	local type = origin.type;
	local format;

	origin.doing_db = nil;

	if exceed_errors(origin) then return true; end
	
	if err then
		format = ("Dialback non-fatal error: "..err.." (%s)"):format(type:find("s2sin.*") and attr.from or attr.to);
	else -- invalid error condition
		origin:close(
			{ condition = "not-acceptable", text = "Supplied error dialback condition is a non graceful one, good bye" },
			"stream failure"
		);
	end
	
	if format then 
		module:log("warn", format);
		if origin.bounce_sendq then origin:bounce_sendq(err); end
	end
	return true;
end
local function send_db_error(origin, name, condition, from, to, id)
	module:log("debug", "sending dialback error (%s) to %s...", condition, to);
	local db_error = st.stanza(name, { from = from, to = to, id = id, type = "error" })
		:tag("error", { type = "cancel" })
			:tag(condition, { xmlns = xmlns_stanzas });

	origin.db_errors = (origin.db_errors or 0) + 1;

	if exceed_errors(origin) then return true; end
	
	origin.sends2s(db_error);
	return true;
end

module:hook("stanza/"..xmlns_db..":verify", function(event)
	local origin, stanza = event.origin, event.stanza;
	
	if origin.type == "s2sin_unauthed" or origin.type == "s2sin" then
		origin.log("debug", "verifying that dialback key is ours...");
		local attr = stanza.attr;
		if attr.type then
			module:log("warn", "Ignoring incoming session from %s claiming a dialback key for %s is %s",
				origin.from_host or "(unknown)", attr.from or "(unknown)", attr.type);
			return true;
		end

		local type;
		if verify_dialback(attr.id, attr.from, attr.to, stanza[1]) then
			type = "valid";
			if origin.type == "s2sin" then
				local s2sout = hosts[attr.to].s2sout[attr.from];
				if s2sout and origin.from_host ~= attr.from then s2sout.multiplexed_from = origin; end
			end
		else
			type = "invalid";
			origin.log("warn", "Asked to verify a dialback key that was incorrect. An imposter is claiming to be %s?", attr.to);
		end
		origin.log("debug", "verified dialback key... it is %s", type);
		origin.sends2s(st.stanza("db:verify", { from = attr.to, to = attr.from, id = attr.id, type = type }):text(stanza[1]));
		return true;
	end
end);

module:hook("stanza/"..xmlns_db..":result", function(event)
	local origin, stanza = event.origin, event.stanza;
	
	if origin.type == "s2sin_unauthed" or origin.type == "s2sin" then
		local attr = stanza.attr;
		local to, from = nameprep(attr.to), nameprep(attr.from);
		local is_multiplexed_from;

		if not origin.from_host then
			origin.from_host = from;
		end
		if not origin.to_host then
			origin.to_host = to;
		end
		if origin.from_host ~= from then -- multiplexed stream
			is_multiplexed_from = origin;
		end
		
		if not hosts[to] then
			origin.log("info", "%s tried to connect to %s, which we don't serve", from, to);
			return send_db_error(origin, "db:result", "item-not-found", to, from, attr.id);
		elseif not from then
			origin:close("improper-addressing");
			return true;
		end
		
		origin.hosts[from] = { dialback_key = stanza[1] };
		dialback_requests[from.."/"..origin.streamid] = origin;
		
		origin.log("debug", "asking %s if key %s belongs to them", from, stanza[1]);
		module:fire_event("route/remote", {
			from_host = to, to_host = from, multiplexed_from = is_multiplexed_from,
			stanza = st.stanza("db:verify", { from = to, to = from, id = origin.streamid }):text(stanza[1])
		});
		return true;
	end
end);

module:hook("stanza/"..xmlns_db..":verify", function(event)
	local origin, stanza = event.origin, event.stanza;
	
	if origin.type == "s2sout_unauthed" or origin.type == "s2sout" then
		local attr = stanza.attr;
		local dialback_verifying = dialback_requests[attr.from.."/"..(attr.id or "")];
		dialback_requests[attr.from.."/"..(attr.id or "")] = nil;
		if dialback_verifying and attr.from == origin.to_host and not dialback_verifying.destroyed then
			local valid, authed, destroyed;
			if attr.type == "valid" then
				authed = make_authenticated(dialback_verifying, attr.from);
				valid = "valid";
			elseif attr.type == "error" then
				return handle_db_errors(origin, stanza);
			else
				log("warn", "authoritative server for %s denied the key", attr.from or "(unknown)");
				valid = "invalid";
			end
			destroyed = dialback_verifying.destroyed; -- incoming connection was destroyed before verifying
			if not destroyed then
				dialback_verifying.sends2s(
					st.stanza("db:result", { from = attr.to, to = attr.from, id = attr.id, type = valid })
						:text(dialback_verifying.hosts[attr.from].dialback_key));
			end
			if not destroyed and not authed then
				send_db_error(origin, "db:verify", "not-authorized", attr.to, attr.from, attr.id);
			end
		else
			send_db_error(origin, "db:verify", "remote-server-not-found", attr.to, attr.from, attr.id);
		end
		origin.doing_db = nil;
		return true;
	end
end);

module:hook("stanza/"..xmlns_db..":result", function(event)
	local origin, stanza = event.origin, event.stanza;
	
	if origin.type == "s2sout_unauthed" or origin.type == "s2sout" then
		local attr = stanza.attr;
		if not hosts[attr.to] then
			send_db_error(origin, "db:result", "item-not-found", attr.to, attr.from, attr.id);
			return true;
		elseif hosts[attr.to].s2sout[attr.from] ~= origin then
			-- This isn't right
			origin:close("invalid-id");
			return true;
		end
		if attr.type == "valid" then
			make_authenticated(origin, attr.from);
		elseif attr.type == "error" then
			return handle_db_errors(origin, stanza);
		else
			send_db_error(origin, "db:result", "not-authorized", attr.to, attr.from, attr.id);
		end
		origin.doing_db = nil;
		return true;
	end
end);

module:hook_stanza("urn:ietf:params:xml:ns:xmpp-sasl", "failure", function (origin, stanza)
	if origin.external_auth == "failed" and can_do_dialback(origin) then
		module:log("debug", "SASL EXTERNAL failed, falling back to dialback");
		origin.can_do_dialback = true;
		initiate_dialback(origin);
		return true;
	else
		module:log("debug", "SASL EXTERNAL failed and no dialback available, closing stream(s)");
		origin:close();
		return true;
	end
end, 100);

module:hook_stanza(xmlns_stream, "features", function (origin, stanza)
	if origin.type == "s2sout_unauthed" and (not origin.external_auth or origin.external_auth == "failed") then
		local tls = stanza:child_with_ns(xmlns_starttls);
		if can_do_dialback(origin) then
			local to, from = origin.to_host, origin.from_host;
			local tls_required = tls and tls:get_child("required");
			if tls_required and not origin.secure and not encryption_exceptions:contains(to) then
				module:log("warn", "Remote server mandates to encrypt streams but TLS is not available for this host,");
				module:log("warn", "please check your configuration and that mod_tls is loaded correctly");
				-- Close paired incoming stream
				for session in pairs(incoming) do
					if session.from_host == to and session.to_host == from and not session.multiplexed_stream then
						session:close("internal-server-error", "dialback authentication failed on paired outgoing stream");
					end
				end
				return;
			end
			
			module:log("debug", "Initiating dialback...");
			origin.can_do_dialback = true;
			initiate_dialback(origin);
		end
	end
end, 100);

module:hook("s2s-stream-features", function (data)
	data.features:tag("dialback", { xmlns = "urn:xmpp:features:dialback" }):tag("errors"):up():up();
end, 98);

module:hook("s2s-authenticate-legacy", function (session)
	module:log("debug", "Initiating dialback...");
	initiate_dialback(session);
	return true;
end, 100);

module:hook("s2s-dialback-again", function (session)
	if not session.doing_db then
		module:log("debug", "Attempting to perform dialback again... as more stanzas are being queued.");
		initiate_dialback(session);
	end
	return true;
end);

function module.load()
	host_session.dialback_capable = true;
end

function module.unload(reload)
	host_session.dialback_capable = nil;
end

module:hook_global("config-reloaded", function()
	s2s_strict_mode = module:get_option_boolean("s2s_strict_mode", false);
	require_encryption = module:get_option_boolean("s2s_require_encryption", not no_encryption);
	encryption_exceptions = module:get_option_set("s2s_encryption_exceptions", {});
end);
