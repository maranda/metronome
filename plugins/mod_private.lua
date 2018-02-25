-- * Metronome IM *
--
-- This file is part of the Metronome XMPP server and is released under the
-- ISC License, please see the LICENSE file in this source package for more
-- information about copyright and licensing.
--
-- As per the sublicensing clause, this file is also MIT/X11 Licensed.
-- ** Copyright (c) 2008-2010, Matthew Wild, Waqas Hussain

if hosts[module.host].anonymous_host then
	module:log("error", "Private Storage won't be available on anonymous hosts as storage is explicitly disabled");
	modulemanager.unload(module.host, "private");
	return;
end

local st = require "util.stanza"

local datamanager = require "util.datamanager"

module:add_feature("jabber:iq:private");

module:hook("iq/self/jabber:iq:private:query", function(event)
	local origin, stanza = event.origin, event.stanza;
	local type = stanza.attr.type;
	local query = stanza.tags[1];
	if #query.tags == 1 then
		local tag = query.tags[1];
		local key = tag.name..":"..tag.attr.xmlns;
		local data, err = datamanager.load(origin.username, origin.host, "private");
		if err then
			origin.send(st.error_reply(stanza, "wait", "internal-server-error", err));
			return true;
		end
		if stanza.attr.type == "get" then
			if data and data[key] then
				origin.send(st.reply(stanza):tag("query", {xmlns = "jabber:iq:private"}):add_child(st.deserialize(data[key])));
			else
				origin.send(st.reply(stanza):add_child(stanza.tags[1]));
			end
		else
			if not data then data = {}; end;
			if #tag == 0 then
				data[key] = nil;
			else
				data[key] = st.preserialize(tag);
			end
			data, err = datamanager.store(origin.username, origin.host, "private", data);
			if data then
				origin.send(st.reply(stanza));
			else
				origin.send(st.error_reply(stanza, "wait", "internal-server-error", err));
			end
		end
	else
		origin.send(st.error_reply(stanza, "modify", "bad-format"));
	end
	return true;
end);
