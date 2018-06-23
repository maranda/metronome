-- * Metronome IM *
--
-- This file is part of the Metronome XMPP server and is released under the
-- ISC License, please see the LICENSE file in this source package for more
-- information about copyright and licensing.

local hosts = hosts;
local bare_sessions, full_sessions = bare_sessions, full_sessions;
local jid_bare, jid_join, jid_section = require "util.jid".bare, require "util.jid".join, require "util.jid".section;
local load, save = require "util.datamanager".load, require "util.datamanager".store;

local st = require "util.stanza";
local error_reply = require "util.stanza".error_reply;
local ipairs, pairs, tostring = ipairs, pairs, tostring;
local rostermanager = require "util.rostermanager";

local gdpr_signed = {};
local gdpr_agreement_sent = {};

local gdpr_addendum = module:get_option_string("gdpr_addendum");

local header = st.message({ from = module.host, type = "chat" },
		"Greetings, to comply with EU's General Data Protection Regulation (GDPR) before enabling server-to-server communication " ..
		"with remote entities the "..module.host.." instant messaging service requires you the following:"
);
local a = st.message({ from = module.host, type = "chat" },
		"A) That you're hereby aware that whenever _any data or meta-data pertaining_ to you (the user) leaves this service (formally "..module.host..") boundaries, " ..
		"this service operator won't be in anyway able to assert its usage, and won't be *responsible* for _any_ *possible misuse* nor able to stop it."
);
local b = st.message({ from = module.host, type = "chat" },
		"B) That you hereby formally consent 3rd parties to treat _any data_ sent to them via server-to-server communication mean, and that it's _your sole " ..
		"responsibility_, and not this service operator, to assert _its usage_ and perhaps deal with _any possible consequences_ deriving from the data you share."
);
local c = st.message({ from = module.host, type = "chat" },
		"C) Should you accept this agreement, you fully legally disclaim this service operator for what is mentioned above. Just reply these messages with: I consent"
);
local d = st.message({ from = module.host, type = "chat" },
		"D) Should you not accept this agreement, server-to-server communication will be disabled and any current remote contact you have in your roster removed and unsubscribed. " ..
		"Just reply these messages with: I don't consent"
);
local agreement = {
	header, a, b, c, d
};
if gdpr_addendum then agreement[#agreement + 1] = st.message({ from = module.host, type = "chat" }, gdpr_addendum); end

local function send_agreement(origin, from)
	gdpr_agreement_sent[from] = true;
	for _, stanza in ipairs(agreement) do
		local message = st.clone(stanza);
		message.attr.to = origin.full_jid;
		origin.send(message);
	end
end

local function gdpr_s2s_check(event)
	local origin, stanza = event.origin, event.stanza;
	if origin and origin.type == "c2s" then
		local from = jid_join(origin.username, origin.host);
		local name, type = stanza.name, stanza.attr.type;

		if name == "presence" and (type == "unsubscribe" or type == "unsubscribed") then
			return;
		end

		if gdpr_signed[from] == nil then
			module:log("debug", "blocked stanza %s (type: %s) from %s, agreement not yet accepted", name, type or "absent", from);
			origin.send(error_reply(stanza, "cancel", "policy-violation", 
				"GDPR agreement needs to be accepted before communicating with a remote server"));
			if not gdpr_agreement_sent[from] then send_agreement(origin, from); end
			return true;
		elseif gdpr_signed[from] == false then
			module:log("debug", "blocked stanza %s (type: %s) from %s, agreement refused", name, type or "absent", from);
			origin.send(error_reply(stanza, "cancel", "policy-violation", 
				"You refused the GDPR agreement, therefore s2s communication is disabled... " ..
				"should you decide to enable it, send a message directly to "..module.host.." " ..
				"with wrote: I consent"
			));
			return true;
		end
	end
end

local function gdpr_handle_consent(event)
	local origin, stanza = event.origin, event.stanza;

	local from = jid_bare(stanza.attr.from) or jid_join(origin.username, origin.host);
	local body = stanza:get_child_text("body");

	if origin and origin.type == "c2s" and body and gdpr_agreement_sent[from] then
		if body:match(".*I consent.*") then
			gdpr_signed[from] = true;
			gdpr_agreement_sent[from] = nil;
			save(nil, module.host, "gdpr", gdpr_signed);
			module:log("info", "%s signed the GDPR agreement, enabling s2s communication", from);
			origin.send(st.message({ to = origin.full_jid, from = module.host, type = "chat" }, "Thank you."));
			return true;
		elseif body:match(".*I don't consent.*") then
			module:log("info", "%s refused the GDPR agreement, disabling s2s communication and clearing eventual remote contacts", from);
			origin.send(st.message({ to = origin.full_jid, from = module.host, type = "chat" },
				"Acknowledged, disabling s2s and removing remote contact entries, " ..
				"remember you can consent by sending \"I consent\" to the service host anytime."));
			local roster = origin.roster;
			if roster then
				for jid, item in pairs(roster) do
					if jid ~= false and jid ~= "pending" and not hosts[jid_section(jid, "host")] then
						if item.subscription == "both" or item.subscription == "from" or (roster.pending and roster.pending[jid]) then
							module:fire_global_event("route/post", origin, st.presence({ type = "unsubscribed", from = origin.full_jid, to = jid }));
						end
						if item.subscription == "both" or item.subscription == "to" or item.ask then
							module:fire_global_event("route/post", origin, st.presence({ type = "unsubscribe", from = origin.full_jid, to = jid }));
						end
						local success = rostermanager.remove_from_roster(origin, jid);
						if success then rostermanager.roster_push(origin.username, origin.host, jid); end
					end
				end
			end
			gdpr_signed[from] = false;
			save(nil, module.host, "gdpr", gdpr_signed);
			return true;
		end
	end
end

module:depends("adhoc");
local adhoc_new = module:require "adhoc".new;

local function adhoc_send_agreement(self, data, state)
	local from = data.from;
	local session = full_sessions[from];

	if not gdpr_signed[jid_bare(from)] then
		send_agreement(session, from);
		return { status = "completed", info = "GDPR agreement sent" };
	else
		return { status = "completed", error = { message = "You already signed, you need to first revoke the signature" } };
	end
end

local function revoke_signature(self, data, state)
	local from = jid_bare(data.from);
		
	if gdpr_signed[from] == nil then
		return { status = "completed", error = { message = "You didn't sign the agreement yet" } };
	else
		gdpr_signed[from] = nil;
		save(nil, module.host, "gdpr", gdpr_signed);
		return { status = "completed", info = "Revoked GDPR sign status, you'll be able to pick your choice again" };
	end
end

local adhoc_send_agreement_descriptor = adhoc_new(
	"Send GDPR agreement", "send_gdpr_agreement", adhoc_send_agreement, "local_user"
);
local revoke_signature_descriptor = adhoc_new(
	"Revoke GDPR signature for S2S communication", "revoke_gdpr_signature", revoke_signature, "local_user"
);
module:provides("adhoc", adhoc_send_agreement_descriptor);
module:provides("adhoc", revoke_signature_descriptor);

module:hook("route/remote", gdpr_s2s_check, 450);
module:hook("message/host", gdpr_handle_consent, 450);
module:hook("pre-presence/full", function(event)
	local origin, stanza = event.origin, event.stanza;
	local to = stanza.attr.to;
	
	if origin.type == "c2s" and not stanza.attr.type and not gdpr_signed[jid_join(origin.username, origin.host)] and 
		not origin.directed_bare[jid_bare(to)] then
		local host = hosts[jid_section(to, "host")];
		if host and host.muc then
			origin.send(st.message({ from = module.host, to = origin.full_jid, type = "chat" }, 
				"*Privacy Warn* When using a local MUC groupchat (like "..jid_bare(to)..") users from a remote server may join, " ..
				"see your messages and process your data. If you don't agree with that you should leave the room or make it members " ..
				"only if you just created it."
			));
		end
	end
end, 100);
module:hook("resource-unbind", function(event)
	local username, host = event.session.username, event.session.host;
	local jid = username.."@"..host;
	if not bare_sessions[jid] then gdpr_agreement_sent[jid] = nil; end
end);

module.load = function()
	module:log("debug", "initializing GDPR compliance module... loading signatures table");
	gdpr_signed = load(nil, module.host, "gdpr") or {};
end
module.save = function() return { gdpr_signed = gdpr_signed, gdpr_agreement_sent = gdpr_agreement_sent }; end
module.restore = function(data) gdpr_signed = data.gdpr_signed or {}, data.gdpr_agreement_sent or {}; end
module.unload = function()
	module:log("debug", "unloading GDPR compliance module... saving signatures table");
	save(nil, module.host, "gdpr", gdpr_signed);
end
