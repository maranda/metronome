module:set_global(); -- this is a necessary interoperability measure.
local load_module, is_loaded = modulemanager.load, modulemanager.is_loaded;

local hosts = _G.hosts;
local s2s_make_authenticated = require "core.s2smanager".make_authenticated;

local log = module._log;
local st = require "util.stanza";
local sha256_hash = require "util.hashes".sha256;
local nameprep = require "util.encodings".stringprep.nameprep;

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

-- // Hooks

local function preverify_hook(event)
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
			type = "valid"
		else
			type = "invalid"
			origin.log("warn", "Asked to verify a dialback key that was incorrect. An imposter is claiming to be %s?", attr.to);
		end
		origin.log("debug", "verified dialback key... it is %s", type);
		origin.sends2s(st.stanza("db:verify", { from = attr.to, to = attr.from, id = attr.id, type = type }):text(stanza[1]));
		return true;
	end
end

local function preresult_hook(event)
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
end

local function verify_hook(event)
	local origin, stanza = event.origin, event.stanza;
	
	if origin.type == "s2sout_unauthed" or origin.type == "s2sout" then
		local attr = stanza.attr;
		local dialback_verifying = dialback_requests[attr.from.."/"..(attr.id or "")];
		if dialback_verifying and attr.from == origin.to_host then
			local valid;
			if attr.type == "valid" then
				s2s_make_authenticated(dialback_verifying, attr.from);
				valid = "valid";
			else
				log("warn", "authoritative server for %s denied the key", attr.from or "(unknown)");
				valid = "invalid";
			end
			if dialback_verifying.destroyed then
				log("warn", "Incoming s2s session %s was closed in the meantime, so we can't notify it of the db result", tostring(dialback_verifying):match("%w+$"));
			else
				dialback_verifying.sends2s(
						st.stanza("db:result", { from = attr.to, to = attr.from, id = attr.id, type = valid })
								:text(dialback_verifying.hosts[attr.from].dialback_key));
			end
			dialback_requests[attr.from.."/"..(attr.id or "")] = nil;
		end
		return true;
	end
end

local function result_hook(event)
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
			s2s_make_authenticated(origin, attr.from);
		else
			origin:close("not-authorized", "dialback authentication failed");
		end
		return true;
	end
end

local function sasl_failure_hook(origin, stanza)
	if origin.external_auth == "failed" then
		module:log("debug", "SASL EXTERNAL failed, falling back to dialback");
		initiate_dialback(origin);
		return true;
	end
end

local function stream_features_hook(origin, stanza)
	if not origin.external_auth or origin.external_auth == "failed" then
		module:log("debug", "Initiating dialback...");
		initiate_dialback(origin);
		return true;
	end
end

local function s2s_auth_legacy_hook(event)
	module:log("debug", "Initiating dialback...");
	initiate_dialback(event.origin);
	return true;
end

local function s2s_features_hook(data) 
	data.features:tag("dialback", { xmlns = "urn:xmpp:features:dialback" }):up();
end

-- // Methods

function module.add_host(module)
	module:hook("stanza/jabber:server:dialback:verify", preverify_hook);
	module:hook("stanza/jabber:server:dialback:result", preresult_hook);
	module:hook("stanza/jabber:server:dialback:verify", verify_hook);
	module:hook("stanza/jabber:server:dialback:result", result_hook);
	module:hook_stanza("urn:ietf:params:xml:ns:xmpp-sasl", "failure", sasl_failure_hook, 100);
	module:hook_stanza(xmlns_stream, "features", stream_features_hook, 100);
	module:hook("s2s-authenticate-legacy", s2s_auth_legacy_hook, 100);
	module:hook("s2s-stream-features", s2s_features_hook);
end

function module.loaded()
	-- ensure module is loaded on every host / component
	local hosts = hosts;
	for host in pairs(hosts) do
		if not is_loaded(host, "dialback") then load_module(host, "dialback") end
	end
end
