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
local jid_bare, jid_split = require "util.jid".bare, require "util.jid".split;
local mam_add_to_store = module:require("mam", "mam").add_to_store;
local limit = module:get_option_number("offline_store_limit", 100);

module:add_feature("msgoffline");

module:hook("message/offline/handle", function(event)
	local origin, stanza = event.origin, event.stanza;

	if not stanza:get_child("no-store", "urn:xmpp:hints") then
		local to = stanza.attr.to;
		local node, host;
		if to then
			node, host = jid_split(to);
		else
			node, host = origin.username, origin.host;
		end

		local archive = datamanager.list_load(node, host, "offline");
		local mam_store, handled_by_mam = module:fire_event("mam-get-store", node);
		if mam_store and mam_add_to_store(mam_store, node, jid_bare(to)) then handled_by_mam = true; end
		
		if archive and #archive >= limit then
			if not handled_by_mam then
				origin.send(st.error_reply(stanza, "cancel", "service-unavailable", "User's offline message queue is full!"));
			end
			return true;
		else
			stanza.attr.stamp = datetime.datetime();
			local result = datamanager.list_append(node, host, "offline", st.preserialize(stanza));
			stanza.attr.stamp = nil;
			return result;
		end
	end
end);

module:hook("message/offline/broadcast", function(event)
	local origin = event.origin;

	local node, host = origin.username, origin.host;

	local data = datamanager.list_load(node, host, "offline");
	if not data then return true; end
	if origin.bind_version ~= 2 then
		for _, stanza in ipairs(data) do
			stanza = st.deserialize(stanza);
			stanza:tag("delay", {xmlns = "urn:xmpp:delay", from = host, stamp = stanza.attr.stamp}):up(); -- XEP-0203
			stanza.attr.stamp = nil;
			origin.send(stanza);
		end
	end
	datamanager.list_store(node, host, "offline", nil);
	return true;
end);
