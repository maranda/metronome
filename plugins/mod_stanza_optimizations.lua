-- * Metronome IM *
--
-- This file is part of the Metronome XMPP server and is released under the
-- ISC License, please see the LICENSE file in this source package for more
-- information about copyright and licensing.

-- This module implements a part of XEP-273 and XEP-352 to queue and filter
-- incoming presences and messages, particularly useful for mobile clients.

local NULL = {};
local pairs, t_insert, t_remove = pairs, table.insert, table.remove;
local jid_join = require "util.jid".join;
local st = require "util.stanza";
	
module:add_feature("urn:xmpp:csi:0");
module:add_feature("urn:xmpp:sift:2");
module:add_feature("urn:xmpp:sift:senders:remote");
module:add_feature("urn:xmpp:sift:stanzas:message");
module:add_feature("urn:xmpp:sift:stanzas:presence");

-- Define queue data structure

local queue_mt = {}; queue_mt.__index = queue_mt

function queue_mt:pop(from, stanza)
	local idx, queue, session = self._idx, self._queue, self._session;
	module:log("debug", "queuing presence for %s: %s", session.full_jid, stanza:top_tag());
	if not queue[from] then
		queue[from] = st.clone(stanza); t_insert(idx, from);
	else
		for i, _from in ipairs(idx) do
			if _from == from then t_remove(idx, i); break; end
		end
		queue[from] = st.clone(stanza); t_insert(idx, from);
	end
end

function queue_mt:flush(clean)
	local send, session, idx, queue = self._send, self._session, self._idx, self._queue;
	if #idx > 0 then -- flush queue
		module:log("debug", "flushing queued stanzas to %s", session.full_jid);
		for i = 1, #idx do
			local stanza = queue[idx[i]];
			module:log("debug", "sending presence: %s", stanza:top_tag());
			send(stanza);
		end
	end
	if clean and #idx > 0 then
		self._idx, self._queue = {}, {};
		idx, queue = nil, nil;
	end
end

function queue_mt:wrap_sm()
	self._send = self._session.send;
end

local function new_queue(session)
	return setmetatable({
		_idx = {},
		_queue = {},
		_session = session;
		_send = session.send;
	}, queue_mt);
end

-- Hooks

module:hook("stream-features", function(event)
	if event.origin.type == "c2s" then event.features:tag("csi", { xmlns = "urn:xmpp:csi:0" }):up(); end
end, 96);
	
module:hook("iq-set/self/urn:xmpp:sift:2:sift", function(event)
	local stanza, session = event.stanza, event.origin;

	local sift = stanza.tags[1];
	local message = sift:child_with_name("message");
	local presence = sift:child_with_name("presence");
	local iq = sift:child_with_name("iq");
	local message_sender = message.attr.sender;
	local presence_sender = presence.attr.sender;

	if session.csi and presence then
		session.send(st.error_reply(stanza, "cancel", "forbidden", "Can't handle presence filtering via SIFT when Client State Indication is used"));
		return true;
	end

	if (message_sender and message_sender ~= "remote") or (presence_sender and presence_sender ~= "remote") then
		session.send(st.error_reply(stanza, "cancel", "feature-not-implemented", "Only sifting of remote entities is currently supported"));
		return true;
	end

	if iq or #message.tags ~= 0 or #presence.tags ~= 0 then
		session.send(st.error_reply(stanza, "cancel", "feature-not-implemented",
			iq and "Sifting of IQ stanza is not supported" or "Element and Namespace filtering is not supported"
		));
		return true;
	end
	
	if message and not presence then
		module:log("info", "%s removing presence SIFT filters", session.full_jid);
		session.presence_block = nil;
		for st in pairs(session.to_block) do
			if st.name == "presence" then session.to_block[st] = nil; end
		end
	elseif presence and not message then
		module:log("info", "%s removing message SIFT filters", session.full_jid);
		session.message_block = nil;
		for st in pairs(session.to_block) do
			if st.name == "message" then session.to_block[st] = nil; end
		end
	elseif #sift.tags == 0 then
		module:log("info", "%s removing all SIFT filters", session.full_jid);
		session.presence_block, session.message_block, session.to_block = nil, nil, nil;
		session.send(st.reply(stanza));
		return true;
	end
	
	module:log("info", "%s enabling SIFT filtering of %s", session.full_jid,
		(
			(presence and messages) and (
				(message_sender and presence_sender and "remote messages and remote presences") or 
				(message_sender and "remote messages and all presences") or
				(presence_sender and "all messages and remote presences") or
				"all messages and presences"
			) or
			presence and (
				presence_sender and "remote presences" or "all presences"
			) or
			messages and (
				message_sender and "remote messages" or "all messages"
			)
		)
	);
	if message then session.message_block = message_sender or true; end
	if presence then session.presence_block = presence_sender or true; end
	session.to_block = {};
	session.send(st.reply(stanza));
	return true;
end);

module:hook("stanza/urn:xmpp:csi:0:active", function(event)
	local session = event.origin;
	if session.type == "c2s" and session.csi ~= "active" then
		local jid = session.full_jid or jid_join(session.username, session.host);
		module:log("info", "%s signaling client is active", jid);
		session.csi = "active";
		if session.csi_queue then session.csi_queue:flush(); end
		session.csi_queue, session.presence_block = nil, nil;
		if not session.message_block then session.to_block = nil; end
		module:fire_event("client-state-changed", { session = session, state = session.csi });
	end
	return true;
end);

module:hook("stanza/urn:xmpp:csi:0:inactive", function(event)
	local session = event.origin;
	if session.type == "c2s" and session.csi ~= "inactive" then
		module:log("info", "%s signaling client is inactive blocking and queuing incoming presences", 
			session.full_jid or jid_join(session.username, session.host));
		session.csi = "inactive";
		session.csi_queue, session.to_block, session.presence_block = new_queue(session), session.to_block or {}, true;
		module:fire_event("client-state-changed", { session = session, state = session.csi });
	end
	return true;
end);

module:hook("message/bare", function(event)
	local stanza, origin = event.stanza, event.origin;

	local to_bare = bare_sessions[stanza.attr.to];
	if not to_bare then
		return;
	else
		for _, resource in pairs(to_bare.sessions or NULL) do
			if resource.message_block == true or resource.message_block == "remote" and
				(origin.type == "s2sin" or origin.type == "bidirectional") then
				resource.to_block[stanza] = true;
			end
		end
	end
end, 100);

module:hook("presence/bare", function(event)
	local stanza, origin = event.stanza, event.origin;
	local t = stanza.attr.type;
	if not (t == nil or t == "unavailable") then return; end

	local to_bare = bare_sessions[stanza.attr.to];
	if not to_bare then
		return;
	else
		for _, resource in pairs(to_bare.sessions or NULL) do
			if resource.presence_block == true then
				if resource.csi == "inactive" then
					resource.csi_queue:pop(stanza.attr.from, stanza);
				end
				resource.to_block[stanza] = true;
			elseif resource.presence_block == "remote" and (origin.type == "s2sin" or origin.type == "bidirectional") then
				resource.to_block[stanza] = true;
			end
		end
	end
end, 100);

local function full_handler(event)
	local stanza, origin = event.stanza, event.origin;
	local t = stanza.attr.type;
	local st_name = stanza.name;
	if st_name == "presence" and not (t == nil or t == "unavailable") then return; end
	
	local to_full = full_sessions[stanza.attr.to];
	if to_full then
		if to_full.csi == "inactive" and st_name == "presence" then
			to_full.csi_queue:pop(stanza.attr.from, stanza);
		end
		if to_full[st_name.."_block"] == true or to_full[st_name.."_block"] == "remote" and 
			(origin.type == "s2sin" or origin.type == "bidirectional") then
			return true;
		end
		if to_full.csi == "inactive" and (st_name == "message" or st_name == "iq") then
			if st_name == "message" and not stanza:child_with_name("body") and
				not stanza:get_child("received", "urn:xmpp:carbons:2") and
				not stanza:get_child("result", "urn:xmpp:mam:2") then
				module:log("debug", "filtering bodyless message for %s: %s", to_full.full_jid, stanza:top_tag());
				return true;
			end
			to_full.csi_queue:flush(true);
		end
	end
end

module:hook("iq/full", full_handler, 100);
module:hook("message/full", full_handler, 100);
module:hook("presence/full", full_handler, 100);

module:hook("c2s-sm-enabled", function(session)
	if session.csi_queue then session.csi_queue:wrap_sm(); end
end);

function module.unload(reload)
	if not reload then 
		for _, full_session in pairs(full_sessions) do 
			full_session.csi = nil;
			if full_session.csi_queue then
				full_session.csi_queue:flush();
				full_session.csi_queue = nil;
			end
			full_session.presence_block = nil;
			full_session.message_block = nil;
			full_session.to_block = nil;
		end
	end
end