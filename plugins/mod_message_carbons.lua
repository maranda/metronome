-- * Metronome IM *
--
-- This file is part of the Metronome XMPP server and is released under the
-- ISC License, please see the LICENSE file in this source package for more
-- information about copyright and licensing.

-- This module implements XEP-0280: Message Carbons

local st = require "util.stanza";
local jid_bare = require "util.jid".bare;
local jid_join = require "util.jid".join;
local jid_section = require "util.jid".section;
local t_remove = table.remove;

local bare_sessions, full_sessions = bare_sessions, full_sessions;

local xmlns = "urn:xmpp:carbons:2";

module:add_feature(xmlns);

local received = st.stanza("received", { xmlns = xmlns });
local sent = st.stanza("sent", { xmlns = xmlns });

local function clear_flag(session)
	local has_carbons;
	local bare_session = bare_sessions[jid_join(session.username, session.host)];
	if not bare_session then return; end
	for _, _session in pairs(bare_session.sessions) do
		if _session.carbons then has_carbons = true; break; end
	end
	if not has_carbons then bare_session.has_carbons = nil; end
end

local function fwd(bare, session, stanza, s)
	local to = jid_join(session.username, session.host, session.resource);
	local f = st.clone(s and sent or received):tag("forwarded", { xmlns = "urn:xmpp:forward:0" }):add_child(stanza);
	local message = st.message({ from = bare, to = to }):add_child(f);
	module:log("debug", "Forwarding carbon copy of message from %s to %s", stanza.attr.from or "self", to);
	session.send(message);
end

local function process_message(origin, stanza, s, t)
	local to_bare = t or jid_bare(stanza.attr.to);
	local from_bare = s and jid_bare(origin.full_jid);
	local bare_session = bare_sessions[from_bare or to_bare];
	
	if bare_session and bare_session.has_carbons and stanza.attr.type == "chat" then
		local private = s and stanza:get_child("private", xmlns) and true;
		local r = s and jid_section(origin.full_jid, "resource") or jid_section(stanza.attr.to, "resource");
		local is_muc_sent, muc_nick = origin.joined_mucs and origin.joined_mucs[to_bare];

		if is_muc_sent then
			for entry in pairs(origin.directed) do
				if jid_bare(entry) == to_bare then muc_nick = entry; break; end
			end
		end
			
		if not private and not stanza:get_child("no-copy", "urn:xmpp:hints") then
			for resource, session in pairs(bare_session.sessions) do 
				if session.carbons and resource ~= r and (not is_muc_sent or (is_muc_sent and session.directed[muc_nick])) then
					fwd(from_bare or to_bare, session, stanza, s);
				end
			end
		elseif private then -- just strip the tag;
			local index;
			for i, tag in ipairs(stanza) do
				if tag.name == "private" and tag.attr.xmlns == xmlns then 
					index = i; t_remove(stanza, i); break; 
				end
			end
			t_remove(stanza.tags, index);
		end
	end
end

module:hook("iq-set/self/"..xmlns..":enable", function(event)
	local origin, stanza = event.origin, event.stanza;
	if not origin.full_jid then
		return origin.send(st.error_reply(
			stanza, "auth", "not-allowed", "A resource needs to be bound before enabling Message Carbons"
		));
	elseif origin.carbons then
		return origin.send(st.error_reply(stanza, "cancel", "forbidden", "Message Carbons are already enabled"));
	else
		origin.carbons = true;
		bare_sessions[jid_join(origin.username, origin.host)].has_carbons = true;
		return origin.send(st.reply(stanza));
	end
end);
	
module:hook("iq-set/self/"..xmlns..":disable", function(event)
	local origin, stanza = event.origin, event.stanza;
	if not origin.full_jid then
		return origin.send(st.error_reply(stanza, "cancel", "bad-request"));
	elseif not origin.carbons then
		return origin.send(st.error_reply(stanza, "cancel", "forbidden", "Message Carbons are already disabled"));
	else
		origin.carbons = nil;
		clear_flag(origin);
		
		return origin.send(st.reply(stanza));
	end
end);

module:hook("message/bare", function(event)
	local origin, stanza = event.origin, event.stanza;
	local bare_session = bare_sessions[stanza.attr.to];

	if bare_session and stanza.attr.type == "chat" then
		local clone = st.clone(stanza);
		local top_resource = bare_session.top_resources and bare_session.top_resources[1];
		for resource, session in pairs(bare_session.sessions) do
			if session.carbons and session ~= top_resource then
				clone.attr.to = jid_join(session.username, session.host, resource);
				module:log("debug", "Forking message from %s to %s", stanza.attr.from, clone.attr.to);
				session.send(clone);
			end
		end
	end
end, 1);

module:hook("message/full", function(event)
	local origin, stanza = event.origin, event.stanza;
	local bare_from = jid_bare(stanza.attr.from);
	local full_session = full_sessions[stanza.attr.to];
	if full_session and (not full_session.joined_mucs or not full_session.joined_mucs[bare_from]) then
		process_message(origin, stanza);
	end
end, 1);
module:hook("pre-message/bare", function(event) process_message(event.origin, event.stanza, true); end, 1);
module:hook("pre-message/full", function(event)
	local origin, stanza = event.origin, event.stanza;
	local bare_to = jid_bare(stanza.attr.to);
	process_message(origin, stanza, true, bare_to);
end, 1);
module:hook("resource-unbind", function(event) clear_flag(event.session); end);

function module.unload(reload)
	if not reload then 
		-- cleanup
		for _, full_session in pairs(full_sessions) do full_session.carbons = nil; end
		for _, bare_session in pairs(bare_sessions) do bare_session.has_carbons = nil; end
	end
end
