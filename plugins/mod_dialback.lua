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

local tostring = tostring;

local log = module._log;
local no_encryption = metronome.no_encryption;
local require_encryption = module:get_option_boolean("s2s_require_encryption", not no_encryption);
local encryption_exceptions = module:get_option_set("s2s_encryption_exceptions", {});
local cert_verify_identity = require "util.x509".verify_identity;

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
	return s2s_make_authenticated(session, host);
end

local function verify_identity(origin, from)
	local conn = origin.conn:socket();
	local cert;
	if conn.getpeercertificate then cert = conn:getpeercertificate(); end
	if cert then return cert_verify_identity(from, "xmpp-server", cert); end
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

local function send_db_error(origin, name, type, condition, from, to, id)
	module:log("debug", "sending dialback error (%s) to %s...", condition, to);
	local db_error = st.stanza(name, { from = from, to = to, id = id, type = "error" })
		:tag("error", { type = type })
			:tag(condition, { xmlns = xmlns_stanzas });

	origin.db_errors = (origin.db_errors or 0) + 1;

	if exceed_errors(origin) then return true; end
	
	origin.sends2s(db_error);
	return true;
end

local errors_map = {
	["bad-request"] = "the receiving entity was unable to process the dialback request",
	["forbidden"] = "received a response of type invalid while authenticating with the authoritative server",
	["improper-addressing"] = "dialback request lacks to or from attribute",
	["internal-server-error"] = "the remote server encountered an error while authenticating",
	["item-not-found"] = "requested host was not found on the remote enitity",
	["policy-violation"] = "the receiving entity refused dialback due to a local policy",
	["not-acceptable"] = "the receiving entity was unable to assert our identity",
	["not-authorized"] = "the receiving entity denied dialback",
	["not-allowed"] = "the receiving entity refused dialback because we are into a blacklist",
	["remote-connection-failed"] = "the receiving entity failed to connect back to us",
	["remote-server-not-found"] = "encountered an error while attempting to verify dialback",
	["remote-server-timeout"] = "time exceeded while attempting to contact the authoritative server",
	["resource-constraint"] = "the remote server is currently too busy, try again laters"
};
local function handle_db_errors(origin, stanza, verifying)
	local attr = stanza.attr;
	local condition = stanza:child_with_name("error") and stanza:child_with_name("error")[1];
	local err = condition and errors_map[condition.name];
	local type = origin.type;
	local format;

	origin.doing_db = nil;

	if exceed_errors(origin) then return true; end
	
	if err then
		format = ("Dialback non-fatal error: "..err.." (%s)"):format(type:find("s2sin.*") and attr.from or attr.to);
	else -- non graceful error condition
		origin:close({ condition = "undefined-condition", text = "Condition is non graceful, good bye" }, "dialback failure");
	end

	if verifying and not verifying.destroyed then -- send back condition to verifying stream
		if condition.name == "item-not-found" then 
			send_db_error(verifying, "db:result", "cancel", "remote-server-not-found", attr.to, attr.from, attr.id);
		else
			send_db_error(verifying, "db:result", "modify", "not-acceptable", attr.to, attr.from, attr.id);
		end
	end
	
	if format then 
		module:log("warn", format);
		if origin.bounce_sendq then origin:bounce_sendq(err); end
	end
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

		if not hosts[attr.to] or not hosts[attr.to].s2sout[attr.from] then
			return send_db_error(origin, "db:verify", "cancel", "item-not-found", attr.to, attr.from, attr.id);
		end

		local type;
		if verify_dialback(attr.id, attr.from, attr.to, stanza[1]) then
			type = "valid";
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
		local attr, streamid = stanza.attr, origin.streamid;
		local to, from = nameprep(attr.to), nameprep(attr.from);
		local from_multiplexed;

		if not origin.from_host then
			origin.from_host = from;
		end
		if not origin.to_host then
			origin.to_host = to;
		end
		if origin.from_host ~= from then -- multiplexed stream
			from_multiplexed = origin.from_host;
		end
		
		if not hosts[to] then
			origin.log("info", "%s tried to connect to %s, which we don't serve", from, to);
			return send_db_error(origin, "db:result", "cancel", "item-not-found", to, from, attr.id);
		elseif not from then
			return send_db_error(origin, "db:result", "modify", "improper-addressing", to, from, attr.id);
		elseif origin.blocked then
			return send_db_error(origin, "db:result", "cancel", "not-allowed", to, from, attr.id);
		elseif require_encryption and not origin.secure and not encryption_exceptions:contains(from) then
			return send_db_error(origin, "db:result", "cancel", "policy-violation", to, from, attr.id);
		end

		-- Implement Dialback without Dialback (See XEP-0344) shortcircuiting
		local shortcircuit;
		if origin.cert_identity_status == "valid" and from == origin.from_host then
			shortcircuit = true;
		elseif from ~= origin.from_host and verify_identity(origin, from) then
			shortcircuit = true;
		end

		if shortcircuit then
			origin.log("debug", "shortcircuiting %s dialback request, as it presented a valid certificate", from);
			origin.sends2s(
				st.stanza("db:result", { from = to, to = from, id = attr.id, type = "valid" }):text(stanza[1])
			);
			make_authenticated(origin, from);
			return true;
		end
		
		origin.hosts[from] = { dialback_key = stanza[1] };
		dialback_requests[from.."/"..streamid] = origin;

		module:add_timer(15, function()
			if dialback_requests[from.."/"..streamid] then
				local verifying = dialback_requests[from.."/"..streamid];
				if not verifying.destroyed and hosts[verifying.to_host] and not hosts[verifying.to_host].s2sout[verifying.from_host] and
					not module:fire_event("s2s-is-bidirectional", verifying.from_host) then
					module:log("debug", "Failed to open an outgoing verification stream to %s (id: %s)", verifying.from_host, tostring(attr.id));
					send_db_error(verifying, "db:result", "cancel", "remote-connection-failed", verifying.to_host, verifying.from_host, attr.id);
				end
				dialback_requests[from.."/"..streamid] = nil;
			end
		end);
		
		origin.log("debug", "asking %s if key %s belongs to them", from, stanza[1]);
		module:fire_event("route/remote", {
			from_host = to, to_host = from, from_multiplexed = from_multiplexed,
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
				return handle_db_errors(origin, stanza, dialback_verifying);
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
				send_db_error(dialback_verifying, "db:result", "auth", "forbidden", attr.to, attr.from, attr.id);
			end
		else
			origin:close(); -- just close the stream gracefully
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
			return send_db_error(origin, "db:result", "cancel", "item-not-found", attr.to, attr.from, attr.id);
		elseif hosts[attr.to].s2sout[attr.from] ~= origin then
			-- This isn't right
			origin:close("invalid-id");
			return true;
		end
		if attr.type == "valid" then
			make_authenticated(origin, attr.from);
		elseif attr.type == "error" then
			return handle_db_errors(origin, stanza);
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
	require_encryption = module:get_option_boolean("s2s_require_encryption", not no_encryption);
	encryption_exceptions = module:get_option_set("s2s_encryption_exceptions", {});
end);
