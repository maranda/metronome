-- * Metronome IM *
--
-- This file is part of the Metronome XMPP server and is released under the
-- ISC License, please see the LICENSE file in this source package for more
-- information about copyright and licensing.

-- This library contains shared code for Access Control Decision Function.

local ipairs, type = ipairs, type;
local clone, error_reply = require "util.stanza".clone, require "util.stanza".error_reply;
local bare, section, split, t_remove =
	require "util.jid".bare, require "util.jid".section, require "util.jid".split, table.remove;
local is_contact_subscribed = require "util.rostermanager".is_contact_subscribed;

local function get_match(affiliation, responses)
	for _, response in ipairs(responses) do
		if response == affiliation then return true; end
	end
end

local function apply_policy(label, session, stanza, actions, check_acl)
	local breaks_policy;
	local from, to = stanza.attr.from, stanza.attr.to;
	if type(actions) == "table" then
		local _from, _to;
		if type(check_acl) == "table" then -- assume it's a MAM ACL request
			_from = section(check_acl.attr.from or session.full_jid, "host");
			_to = section(check_acl.attr.to, "host");
			if not to then to = check_acl.attr.from or session.full_jid; end
		else
			_from, _to = section(from, "host"), section(to, "host");
		end
		if actions.type and stanza.attr.type ~= actions.type then
			breaks_policy = true;
		elseif actions.muc_callback == "affiliation" then
			local muc_to, muc_from;
			if module:host_is_muc(_to) then
				muc_to = true; 
			elseif module:host_is_muc(_from) then
				muc_from = true;
			end

			local rooms;
			if muc_to then
				rooms = module:get_host_session(to_host).muc.rooms;
				local room = rooms[bare(to)];
				if stanza.attr.type == "groupchat" then
					local affiliation, match = room:get_affiliation(from);
					match = get_match(affiliation, actions.response);
					if not match then breaks_policy = true; end
				else
					local affiliation_from, match_from, affiliation_to, match_to;
					affiliation_from = room:get_affiliation(from);
					match_from = get_match(affiliation_from, actions.response);
					affiliation_to = room:get_affiliation(room._occupants[to].jid);
					match_to = get_match(affiliation_to, actions.response);
					if not (match_to and match_from) then breaks_policy = true; end
				end
			elseif muc_from then
				rooms = module:get_host_session(from_host).muc.rooms;
				local room = rooms[bare(from)];
				if stanza.attr.type == "groupchat" then
					local affiliation, match = room:get_affiliation(to);
					match = get_match(affiliation, actions.response);
					if not match then breaks_policy = true; end
				else
					local affiliation_from, match_from, affiliation_to, match_to;
					affiliation_from = room:get_affiliation(room._occupants[from].jid);
					match_from = get_match(affiliation_from, actions.response);
					affiliation_to = room:get_affiliation(to);
					match_to = get_match(affiliation_to, actions.response);
					if not (match_to and match_from) then breaks_policy = true; end
				end
			end
		elseif type(actions.host) == "table" then
			if actions.include_muc_subdomains then
				if module:host_is_muc(_from) and module:get_host_session(_from:match("%.([^%.].*)")) then
					_from = _from:match("%.([^%.].*)");
				end
				if module:host_is_muc(_to) and module:get_host_session(_to:match("%.([^%.].*)")) then
					_to = _to:match("%.([^%.].*)");
				end
			end

			if _from ~= (actions.host[1] or actions.host[2]) or _to ~= (actions.host[1] or actions.host[2]) then
				breaks_policy = true;
			end
		end
	elseif actions == "roster" then
		local from_node, from_host = split(from);
		local to_node, to_host = split(to);
		if from_node and module:get_host_session(from_host) then
			if not is_contact_subscribed(from_node, from_host, bare(to)) then breaks_policy = true; end
		elseif to_node and module:get_host_session(to_host) then
			if not is_contact_subscribed(to_node, to_host, bare(from)) then breaks_policy = true; end
		end
	end

	if breaks_policy then
		if not check_acl then
			module:log("warn", "%s message to %s was blocked because it breaks the provided security label policy (%s)",
				from or session.full_jid, to, label);
			session.send(error_reply(stanza, "cancel", "policy-violation", "Message breaks security label "..label.." policy"));
		end
		return true;
	end
end

local policy_cache = {};
local function get_actions(host, label)
	local host_object = module:get_host_session(host);
	if host_object and label then
		if not policy_cache[host] then policy_cache[host] = setmetatable({}, { __mode = "v" }); end
		local cache = policy_cache[host];
		if not cache[label] then
			cache[label] = host_object.events.fire_event("sec-labels-fetch-actions", label);
		end
		return cache[label];
	end
end

local function check_policy(label, jid, stanza, request_stanza)
	local host, actions = section(stanza.attr.from, "host");

	local actions = get_actions(host, label);
	if actions then
		return apply_policy(label, { full_jid = jid }, stanza, actions, request_stanza or true);
	end
end

local function censor_body(stanza)
	local _clone = clone(stanza);
	local body = _clone:get_child("body");
	if body then
		t_remove(body, 1);
		body:text("[You're not authorized to see this message content]");
	end
	return _clone;
end

return { apply_policy = apply_policy, censor_body = censor_body, check_policy = check_policy, get_actions = get_actions };