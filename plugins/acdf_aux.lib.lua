-- * Metronome IM *
--
-- This file is part of the Metronome XMPP server and is released under the
-- ISC License, please see the LICENSE file in this source package for more
-- information about copyright and licensing.

-- This library contains shared code for Access Control Decision Function.

local type = type;
local error_reply = require "util.stanza".error_reply;
local bare, section, split =
	require "util.jid".bare, require "util.jid".section, require "util.jid".split;
local is_contact_subscribed = require "util.rostermanager".is_contact_subscribed;

local hosts = hosts;

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
			if _from ~= (actions.host[1] or actions.host[2]) and _to ~= (actions.host[1] or actions.host[2]) then
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
			session.send(error_reply(stanza, "cancel", "policy-violation", "Message breaks security label "..label.." policy"));
		end
		return true;
	end
end

return { apply_policy = apply_policy };