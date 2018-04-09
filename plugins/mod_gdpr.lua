-- * Metronome IM *
--
-- This file is part of the Metronome XMPP server and is released under the
-- ISC License, please see the LICENSE file in this source package for more
-- information about copyright and licensing.

local hosts = hosts;
local jid_bare, jid_join, jid_section = require "util.jid".bare, require "util.jid".join, require "util.jid".section;
local load, save = require "util.datamanager".load, require "util.datamanager".save;

local st = require "util.stanza";
local error_reply = require "util.stanza".error_reply;
local ipairs, pairs, tostring = ipairs, pairs, tostring;
local rostermanager = require "util.rostermanager";

local gdpr_signed = {};
local gdpr_agreement_sent = {};

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

local function send_agreement(origin, from)
	gdpr_agreement_sent[from] = true;
	for _, stanza in ipairs(agreement) do
		local message = st.clone(stanza);
		message.attr.to = from;
		origin.send(message);
	end
end

local function gdpr_s2s_check(event)
	local origin = event.origin;
	if origin.type == "c2s" then
		local from = jid_join(session.username, session.host);

		if gdpr_signed[from] == nil then
			origin.send(error_reply(event.stanza, "cancel", "policy-violation", 
				"GDPR agreement needs to be accepted before communicating with a remote server"));
			if not gdpr_agreement_sent[from] then send_agreement(origin, origin.full_jid); end
			return true;
		elseif gdpr_signed[from] == false then
			origin.send(error_reply(event.stanza, "cancel", "policy-violation", 
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

	if stanza.attr.to ~= module.host then return; end

	local from = jid_bare(stanza.attr.from) or jid_join(origin.username, origin.host);
	local body = stanza:child_with_name("body");

	if origin.type == "c2s" and body and gdpr_agreement_sent[from] then
		if body:match("^I consent$") then
			gdpr_signed[from] = true;
			gdpr_agreement_sent[from] = nil;
			save(nil, module.host, "gdpr", gdpr_signed);
			module:log("info", "%s signed the GDPR agreement, enabling s2s communication", from);
			origin.send(st.message({ to = from, from = module.host, type = "chat" }, "Thank you."));
			return true;
		elseif body:match("^I don't consent$") then
			module:log("info", "%s refused the GDPR agreement, disabling s2s communication and clearing eventual remote contacts", from);
			origin.send(st.message({ to = from, from = module.host, type = "chat" },
				"Acknowledged, disabling s2s and removing remote contact entries, " ..
				"remember you can consent by sending \"I consent\" to the service host anytime."));
			local roster = origin.roster;
			if roster then
				for jid, item in pairs(roster) do
					if jid ~= false or jid ~= "pending" and hosts[jid_section(jid, "host")] then
						if item.subscription == "both" or item.subscription == "from" or (roster.pending and roster.pending[jid]) then
							module:fire_global_event("route/post", origin, st.presence({type="unsubscribed", from=origin.full_jid, to=to_bare}));
						elseif item.subscription == "both" or item.subscription == "to" or item.ask then
							module:fire_global_event("route/post", origin, st.presence({type="unsubscribe", from=origin.full_jid, to=to_bare}));
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

module:hook("route/remote", gdpr_s2s_check, 450);
module:hook("message/host", gdpr_handle_consent, 450);

module.load = function()
	module:log("debug", "initializing GDPR compliance module... loading signatures table");
	gdpr_signed = load(nil, module.host, "gdpr");
end
module.save = function() return { gdpr_signed = gdpr_signed, gdpr_agreement_sent = gdpr_agreement_sent }; end
module.restore = function(data) gdpr_signed = data.gdpr_signed or {}, data.gdpr_agreement_sent or {}; end
module.unload = function()
	module:log("debug", "unloading GDPR compliance module... saving signatures table");
	save(nil, module.host, "gdpr", gdpr_signed);
end
