-- * Metronome IM *
--
-- This file is part of the Metronome XMPP server and is released under the
-- ISC License, please see the LICENSE file in this source package for more
-- information about copyright and licensing.
--
-- As per the sublicensing clause, this file is also MIT/X11 Licensed.
-- ** Copyright (c) 2009-2010, Matthew Wild, Rob Hoelz, Waqas Hussain

local datamanager = require "util.datamanager";
local st = require "util.stanza";
local datetime = require "util.datetime";
local ipairs = ipairs;
local jid_split = require "util.jid".split;
local limit = module:get_option_number("offline_store_limit", 40);

module:add_feature("msgoffline");

module:hook("message/offline/overcap", function(event)
	local node = event.node;
	local archive = datamanager.list_load(node, module.host, "offline");
	
	if not archive then
		return false;
	elseif #archive >= limit then
		return true;
	end
	
	return false;
end);

module:hook("message/offline/handle", function(event)
	local origin, stanza = event.origin, event.stanza;
	local to = stanza.attr.to;
	local node, host;
	if to then
		node, host = jid_split(to);
	else
		node, host = origin.username, origin.host;
	end
	
	local archive = datamanager.list_load(node, host, "offline");
	if archive and #archive >= limit then
		origin.send(st.error_reply(stanza, "cancel", "service-unavailable", "User's offline message queue is full!"));
		return true;
	else
		stanza.attr.stamp, stanza.attr.stamp_legacy = datetime.datetime(), datetime.legacy();
		local result = datamanager.list_append(node, host, "offline", st.preserialize(stanza));
		stanza.attr.stamp, stanza.attr.stamp_legacy = nil, nil;
		return result;
	end
end);

module:hook("message/offline/broadcast", function(event)
	local origin = event.origin;

	local node, host = origin.username, origin.host;

	local data = datamanager.list_load(node, host, "offline");
	if not data then return true; end
	for _, stanza in ipairs(data) do
		stanza = st.deserialize(stanza);
		stanza:tag("delay", {xmlns = "urn:xmpp:delay", from = host, stamp = stanza.attr.stamp}):up(); -- XEP-0203
		stanza:tag("x", {xmlns = "jabber:x:delay", from = host, stamp = stanza.attr.stamp_legacy}):up(); -- XEP-0091 (deprecated)
		stanza.attr.stamp, stanza.attr.stamp_legacy = nil, nil;
		origin.send(stanza);
	end
	datamanager.list_store(node, host, "offline", nil);
	return true;
end);
