-- * Metronome IM *
--
-- This file is part of the Metronome XMPP server and is released under the
-- ISC License, please see the LICENSE file in this source package for more
-- information about copyright and licensing.

-- This module implements Access Control Decision Function (ACDF) for Security Labels

local type = type;
local st = require "util.stanza";
local bare, section, split =
	require "util.jid".bare, require "util.jid".section, require "util.jid".split;
local is_contact_subscribed = require "util.rostermanager".is_contact_subscribed;

local hosts = hosts;

local labels_xmlns = "urn:xmpp:sec-label:0";

local function apply_policy(label, session, stanza, actions, no_reply)
	local breaks_policy;
	local from, to = stanza.attr.from, stanza.attr.to;
	if type(actions) == "table" then
		if actions.type and stanza.attr.type ~= actions.type then
			breaks_policy = true;
		elseif type(actions.host) == "table" then
			local _from, _to;
			if actions.include_subdomains then
				_from = from and section(from, "host"):match("%.([^%.].*)");
				_to = to and section(to, "host"):match("%.([^%.].*)");
			else
				_from, _to = section(from, "host"), section(to, "host");
			end
			if _from ~= (actions.host[1] or actions.host[2]) or _to ~= (actions.host[1] or actions.host[2]) then
				breaks_policy = true;
			end
		elseif actions.host and
			(actions.direction == "to" and section(to, "host") == actions.host) then
			breaks_policy = true;
		elseif actions.host and
			(actions.direction == "from" and section(from, "host") == actions.host) then
			breaks_policy = true;
		end
	elseif actions == "roster" then
		local from_node, from_host = split(from);
		local to_node, to_host = split(to);
		if from_node and hosts[from_host] then
			if not is_contact_subscribed(from_node, from_host, bare(to)) then breaks_policy = true; end
		elseif to_node and hosts[to_host] then
			if not is_contact_subscribed(to_node, to_host, bare(from)) then breaks_policy = true; end
		end
	end

	if breaks_policy then
		if not no_reply then
			module:log("warn", "%s message to %s was blocked because it breaks the provided security label policy (%s)",
				from or session.full_jid, to, label);
			session.send(st.error_reply(stanza, "cancel", "policy-violation", "Message breaks security label "..label.." policy"));
		end
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

module:hook("check-acdf", function(event)
	local name, actions, session, dummy = event.name, event.actions, event.session, dummy;
	if actions and actions ~= "none" then
		return apply_policy(name, session, dummy, actions, true);
	end
end);

module:hook("message/bare", incoming_message_handler, 90);
module:hook("message/full", incoming_message_handler, 90);
module:hook("pre-message/bare", outgoing_message_handler, 90);
module:hook("pre-message/full", outgoing_message_handler, 90);