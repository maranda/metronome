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

local function fwd(bare, session, stanza, s)
	local to = jid_join(session.username, session.host, session.resource);
	local f = st.clone(s and sent or received):tag("forwarded", { xmlns = "urn:xmpp:forward:0" }):add_child(stanza);
	local message = st.message({ from = bare, to = to }):add_child(f);
	module:log("debug", "Forwarding carbon copy of message from %s to %s", stanza.attr.from or "self", to);
	session.send(message);
end

local function process_message(origin, stanza, s)
	local to_bare = jid_bare(stanza.attr.to);
	local from_bare = s and jid_bare(origin.full_jid);
	local bare_session = bare_sessions[from_bare or to_bare];
	
	if bare_session and stanza.attr.type == "chat" then
		local private = s and stanza:get_child("private", xmlns) and true;
		local r = s and jid_section(origin.full_jid, "resource") or jid_section(stanza.attr.to, "resource");
			
		if not private then
			for resource, session in pairs(bare_session.sessions) do 
				if session.carbons and resource ~= r then 
					fwd(from_bare or to_bare, session, stanza, s);
				end
			end
		else -- just strip the tag;
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
		return origin.send(st.reply(stanza));
	end
end);

module:hook("message/bare", function(event)
	local origin, stanza = event.origin, event.stanza;
	local bare_session = bare_sessions[stanza.attr.to];

	if bare_session and stanza.attr.type == "chat" then
		local clone = st.clone(stanza);
		local top_resource = bare_session.top_resources[1];
		for resource, session in pairs(bare_session.sessions) do
			if session.carbons and not session == top_resource then
				clone.attr.to = jid_join(session.username, session.host, resource);
				session.send(clone);
			end
		end
	end
end, 1);

module:hook("message/full", function(event) process_message(event.origin, event.stanza); end, 1);
module:hook("pre-message/bare", function(event) process_message(event.origin, event.stanza, true); end, 1);
module:hook("pre-message/full", function(event) process_message(event.origin, event.stanza, true); end, 1);

function module.unload(reload)
	if not reload then 
		for jid, session in pairs(full_sessions) do session.carbons = nil; end -- cleanup
	end
end