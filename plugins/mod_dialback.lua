-- * Metronome IM *
--
-- This file is part of the Metronome XMPP server and is released under the
-- ISC License, please see the LICENSE file in this source package for more
-- information about copyright and licensing.
--
-- As per the sublicensing clause, this file is also MIT/X11 Licensed.
-- ** Copyright (c) 2008-2013, Kim Alvefur, Florian Zeitz, Marco Cirillo, Matthew Wild, Paul Aurich, Waqas Hussain

local hosts = _G.hosts;
local s2s_make_authenticated = require "core.s2smanager".make_authenticated;

local log = module._log;
local s2s_strict_mode = module:get_option_boolean("s2s_strict_mode", false);
local require_encryption = module:get_option_boolean("s2s_require_encryption", false);

local st = require "util.stanza";
local sha256_hash = require "util.hashes".sha256;
local nameprep = require "util.encodings".stringprep.nameprep;

local xmlns_db = "jabber:server:dialback";
local xmlns_starttls = 'urn:ietf:params:xml:ns:xmpp-tls';
local xmlns_stream = "http://etherx.jabber.org/streams";

local dialback_requests = setmetatable({}, { __mode = "v" });

function generate_dialback(id, to, from)
	if hosts[from] then
		return sha256_hash(id..to..from..hosts[from].dialback_secret, true);
	else
		return false;
	end
end

function initiate_dialback(session)
	session.dialback_key = generate_dialback(session.streamid, session.to_host, session.from_host);
	session.sends2s(st.stanza("db:result", { from = session.from_host, to = session.to_host }):text(session.dialback_key));
	session.log("info", "sent dialback key on outgoing s2s stream");
end

function verify_dialback(id, to, from, key)
	return key == generate_dialback(id, to, from);
end

function make_authenticated(session, host)
	if require_encryption and not session.secure then
		local t = session.direction == "outgoing" and "offered" or "used";
		session:close("policy-violation", "authentication failure");
		return false;
	end
	return s2s_make_authenticated(session, host);
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
		-- COMPAT: Grr, ejabberd breaks this one too?? it is black and white in XEP-220 example 34
		--if attr.from ~= origin.to_host then error("invalid-from"); end
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
		local attr = stanza.attr;
		local to, from = nameprep(attr.to), nameprep(attr.from);
		
		if not hosts[to] then
			origin.log("info", "%s tried to connect to %s, which we don't serve", from, to);
			origin:close("host-unknown");
			return true;
		elseif not from then
			origin:close("improper-addressing");
			return true;
		end
		
		origin.hosts[from] = { dialback_key = stanza[1] };
		
		dialback_requests[from.."/"..origin.streamid] = origin;
		
		-- COMPAT: ejabberd, gmail and perhaps others do not always set 'to' and 'from'
		-- on streams. We fill in the session's to/from here instead.
		if not origin.from_host then
			origin.from_host = from;
		end
		if not origin.to_host then
			origin.to_host = to;
		end

		origin.log("debug", "asking %s if key %s belongs to them", from, stanza[1]);
		module:fire_event("route/remote", {
			from_host = to, to_host = from;
			stanza = st.stanza("db:verify", { from = to, to = from, id = origin.streamid }):text(stanza[1]);
		});
		return true;
	end
end);

module:hook("stanza/"..xmlns_db..":verify", function(event)
	local origin, stanza = event.origin, event.stanza;
	
	if origin.type == "s2sout_unauthed" or origin.type == "s2sout" then
		local attr = stanza.attr;
		local dialback_verifying = dialback_requests[attr.from.."/"..(attr.id or "")];
		if dialback_verifying and attr.from == origin.to_host then
			local valid, authed;
			if attr.type == "valid" then
				authed = make_authenticated(dialback_verifying, attr.from);
				valid = "valid";
			else
				log("warn", "authoritative server for %s denied the key", attr.from or "(unknown)");
				valid = "invalid";
			end
			if authed and dialback_verifying.destroyed then
				log("warn", "Incoming s2s session %s was closed in the meantime, so we can't notify it of the db result", tostring(dialback_verifying):match("%w+$"));
			elseif authed then
				dialback_verifying.sends2s(
					st.stanza("db:result", { from = attr.to, to = attr.from, id = attr.id, type = valid }):text(dialback_verifying.hosts[attr.from].dialback_key)
				);
			end
			dialback_requests[attr.from.."/"..(attr.id or "")] = nil;
			if not authed then origin:close("not-authorized", "authentication failure"); end -- we close the outgoing stream
		end
		return true;
	end
end);

module:hook("stanza/"..xmlns_db..":result", function(event)
	local origin, stanza = event.origin, event.stanza;
	
	if origin.type == "s2sout_unauthed" or origin.type == "s2sout" then
		local attr = stanza.attr;
		if not hosts[attr.to] then
			origin:close("host-unknown");
			return true;
		elseif hosts[attr.to].s2sout[attr.from] ~= origin then
			-- This isn't right
			origin:close("invalid-id");
			return true;
		end
		if stanza.attr.type == "valid" then
			make_authenticated(origin, attr.from);
		else
			origin:close("not-authorized", "authentication failure");
		end
		return true;
	end
end);

module:hook_stanza("urn:ietf:params:xml:ns:xmpp-sasl", "failure", function (origin, stanza)
	if origin.external_auth == "failed" and origin.can_do_dialback then
		module:log("debug", "SASL EXTERNAL failed, falling back to dialback");
		initiate_dialback(origin);
		return true;
	else
		module:log("debug", "SASL EXTERNAL failed and no dialback available, closing stream(s)");
		origin:close();
		return true;
	end
end, 100);

module:hook_stanza(xmlns_stream, "features", function (origin, stanza)
	if not origin.external_auth or origin.external_auth == "failed" then
		local db = origin.stream_declared_ns and origin.stream_declared_ns["db"];
		local tls = stanza:child_with_ns(xmlns_starttls);
		if db == xmlns_db or stanza:get_child("dialback", "urn:xmpp:features:dialback") then
			local tls_required = tls and tls:get_child("required");
			if tls_required and not origin.secure then
				module:log("warn", "Remote server mandates to encrypt streams but TLS is not available for this host,");
				module:log("warn", "please check your configuration and that mod_tls is loaded correctly");
				return;
			end
			
			module:log("debug", "Initiating dialback...");
			origin.can_do_dialback = true;
			initiate_dialback(origin);
			return true;
		end
	end
end, 100);

module:hook("s2s-authenticate-legacy", function (event)
	event.origin.legacy_dialback = true;
	module:log("debug", "Initiating dialback...");
	initiate_dialback(event.origin);
	return true;
end, 100);

function module.unload(reload)
	if not reload and not s2s_strict_mode then
		module:log("warn", "In interoperability mode mod_s2s directly depends on mod_dialback for its local instances.");
		module:log("warn", "Perhaps it will be unloaded as well for this host. (To prevent this set s2s_strict_mode = true in the config)");
	end
end
