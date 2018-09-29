-- * Metronome IM *
--
-- This file is part of the Metronome XMPP server and is released under the
-- ISC License, please see the LICENSE file in this source package for more
-- information about copyright and licensing.

-- This module implements Access Control Decision Function (ACDF) for Security Labels

local type = type;
local st = require "util.stanza";
local bare, split = require "util.jid".bare, require "util.jid".split;
local is_contact_subscribed = require "util.rostermanager".is_contact_subscribed;

local hosts = hosts;

local labels_xmlns = "urn:xmpp:sec-label:0";

local function apply_policy(label, session, stanza, actions)
	local breaks_policy;
	if type(actions) == "table" then
		if actions.type and stanza.type ~= actions.type then
			breaks_policy = true;
		elseif type(actions.host) == "table" then
			if stanza.attr.from == (actions.host[1] or actions.host[2]) and
				stanza.attr.to == (actions.host[1] or actions.host[2]) then
				breaks_policy = true;
			end
		elseif actions.host and (actions.direction == "to" and stanza.attr.to == actions.host) then
			breaks_policy = true;
		elseif actions.host and (actions.direction == "from" and stanza.attr.from == actions.host) then
			breaks_policy = true;
		end
	elseif actions == "roster" then
		local from_node, from_host = split(stanza.attr.from);
		local to_node, to_host = split(stanza.attr.to);
		if from_node and hosts[from_host] then
			if not is_contact_subscribed(from_node, from_host, bare(stanza.attr.to)) then breaks_policy = true; end
		elseif to_node and hosts[to_host] then
			if not is_contact_subscribed(to_node, to_host, bare(stanza.attr.from)) then breaks_policy = true; end
		end
	end

	if breaks_policy then
		module:log("warn", "%s message to %s was blocked because it breaks the provided security label policy (%s)",
			stanza.attr.from or session.full_jid, stanza.attr.to, label);
		session.send(st.error_reply(stanza, "cancel", "policy-violation", "Message breaks security label "..label.." policy"));
		return true;
	end
end

local function incoming_message_handler(event)
	local session, stanza = event.origin, event.stanza;
	local label = stanza:get_child("securitylabel", labels_xmlns);

	if label then
		local text = label:get_child_text("displaymarking");
		local actions = module:fire_event("sec-labels-fetch-actions", text);
		if actions then return apply_policy(text, session, stanza, actions); end
	end
end

local function outgoing_message_handler(event)
	local session, stanza = event.origin, event.stanza;
	local label = stanza:get_child("securitylabel", labels_xmlns);

	if label then
		local text = label:get_child_text("displaymarking");
		local actions = module:fire_event("sec-labels-fetch-actions", text);
		if actions then return apply_policy(text, session, stanza, actions); end
	end
end

module:hook("message/bare", incoming_message_handler, 90);
module:hook("message/full", incoming_message_handler, 90);
module:hook("pre-message/bare", outgoing_message_handler, 90);
module:hook("pre-message/full", outgoing_message_handler, 90);