-- * Metronome IM *
--
-- This file is part of the Metronome XMPP server and is released under the
-- ISC License, please see the LICENSE file in this source package for more
-- information about copyright and licensing.

local hosts = hosts;
local jid_bare, jid_join, jid_section = require "util.jid".bare, require "util.jid".join, require "util.jid".section;

local gdpr = storagemanager.open(module.host, "gdpr");

local st = require "util.stanza";
local error_reply = require "util.stanza".error_reply;
local ipairs, pairs, tostring = ipairs, pairs, tostring;

local gdpr_signed = {};
local gdpr_agreement_sent = {};
local gdpr_warned = {};

local gdpr_addendum = module:get_option_string("gdpr_addendum");

local header = st.message({ from = module.host, type = "chat" },
		"Greetings, to comply with EU's General Data Protection Regulation (GDPR) before using server-to-server communication " ..
		"with remote entities the "..module.host.." instant messaging service requires to inform you of the following:"
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
		"D) Should you not accept this agreement, you should remove any roster contact not pertaining to this service and not use any Multi-User Chat, each time you " ..
		"will send a stanza or join a groupchat room you will be appropriately warned at least once. This is just an informative provision, for how currently XMPP is " ..
		"concepted and it's decentralised nature it's impossible to guarantee perfect compliance to GDPR. If you aren't fine with that feel free to deregister your " ..
		"account, that will cause all your data on this service to be removed accordingly, at least."
);
local e = st.message({ from = module.host, type = "chat" },
		"E) If you're not an EU citizen you can simply invoke non appliance by replying: Not from EU"
);
local agreement = {
	header, a, b, c, d, e
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
		local full_from = origin.full_jid;
		local name, type = stanza.name, stanza.attr.type;

		if name == "presence" and (type == "unsubscribe" or type == "unsubscribed") then
			return;
		end

		if gdpr_signed[from] == nil then
			if not gdpr_agreement_sent[from] and not origin.halted then
				module:log("info", "sending gdpr agreement to %s", from);
				send_agreement(origin, from);
			elseif not gdpr_warned[full_from] and not origin.halted then
				module:log("info", "sending gdpr stanza warn to %s", full_from);
				origin.send(st.message({ from = module.host, to = full_from, type = "chat" }, 
					"*Privacy Warn* you're sending stanzas to "..jid_bare(stanza.attr.to).." this entity's third party service host " ..
					"(be it a real user or component entity like a groupchat) is beyond the boundaries of this service and will be now " ..
					"processing the data you sent 'em. Should you not be willing to allow that again just stop sending adding contacts " ..
					"or joining rooms that don't end by *\""..module.host.."\"*, should you be fine with that and remove these warnings " ..
					"just accept the GDPR agreement by replying to this message with: I consent\n" ..
					"Alternatively if you're not an european citizen, you can invoke non appliance by replying with: Not from EU"
				));
				gdpr_warned[full_from] = true;
			end
		end
	end
end

local function gdpr_handle_consent(event)
	local origin, stanza = event.origin, event.stanza;

	if origin and origin.type == "c2s" and stanza.name == "message" then
		local from = jid_bare(stanza.attr.from) or jid_join(origin.username, origin.host);
		local body = stanza:get_child_text("body");

		if body and gdpr_signed[from] == nil then
			if body:match(".*I consent.*") then
				gdpr_signed[from] = true;
			elseif body:match(".*Not from EU.*") then
				gdpr_signed[from] = false;
			else
				return;
			end
			gdpr_agreement_sent[from] = nil;
			gdpr:set(nil, gdpr_signed);
			module:log("info", "%s signed the GDPR agreement (%s)", from, gdpr_signed[from] and "consensual" or "unapplicable");
			origin.send(st.message({ to = origin.full_jid, from = module.host, type = "chat" }, "Thank you."));
			return true;
		end
	end
end

module:depends("adhoc");
local adhoc_new = module:require "adhoc".new;

local function adhoc_send_agreement(self, data, state)
	local from = jid_bare(data.from);
	local session = module:get_full_session(data.from);

	if not gdpr_signed[from] then
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
		gdpr:set(nil, gdpr_signed);
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
	
	if origin.type == "c2s" and not stanza.attr.type and gdpr_signed[jid_join(origin.username, origin.host)] == nil and 
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
	gdpr_warned[event.session.full_jid] = nil;
	if not module:get_bare_session(jid) then gdpr_agreement_sent[jid] = nil; end
end);

module.load = function()
	module:log("debug", "initializing GDPR compliance module... loading signatures table");
	gdpr_signed = gdpr:get() or {};
end
module.save = function() return { gdpr_signed = gdpr_signed }; end
module.restore = function(data) gdpr_signed = data.gdpr_signed or {}; end
module.unload = function()
	module:log("debug", "unloading GDPR compliance module... saving signatures table");
	gdpr:set(nil, gdpr_signed);
end
