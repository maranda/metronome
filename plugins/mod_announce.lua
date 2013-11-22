-- * Metronome IM *
--
-- This file is part of the Metronome XMPP server and is released under the
-- ISC License, please see the LICENSE file in this source package for more
-- information about copyright and licensing.
--
-- As per the sublicensing clause, this file is also MIT/X11 Licensed.
-- ** Copyright (c) 2009-2013, Kim Alvefur, Florian Zeitz, Matthew Wild, Waqas Hussain

local st = require "util.stanza";

function send_to_online(message, host)
	local c = 0;
	local host_sessions = hosts[host].sessions;
	message.attr.from = host;
	
	for node in pairs(host_sessions) do
		c = c + 1;
		message.attr.to = node .. "@" .. host;
		module:send(message);
	end

	return c;
end

-- Ad-hoc command (XEP-0133)
local dataforms_new = require "util.dataforms".new;
local announce_layout = dataforms_new{
	title = "Making an Announcement";
	instructions = "Fill out this form to make an announcement to all\nactive users of this service.";

	{ name = "FORM_TYPE", type = "hidden", value = "http://jabber.org/protocol/admin" };
	{ name = "subject", type = "text-single", label = "Subject" };
	{ name = "announcement", type = "text-multi", required = true, label = "Announcement" };
};

function announce_handler(self, data, state)
	if state then
		if data.action == "cancel" then
			return { status = "canceled" };
		end

		local fields = announce_layout:data(data.form);
		
		if fields.announcement == "" then
			return { status = "completed", error = { message = "Please supply a message to broadcast" } };
		end

		module:log("info", "Sending server announcement to all online users");
		local message = st.message({type = "headline"}, fields.announcement):up()
			:tag("subject"):text(fields.subject or "Announcement");
		
		local count = send_to_online(message, data.to);
		
		module:log("info", "Announcement sent to %d online users", count);
		return { status = "completed", info = ("Announcement sent to %d online users"):format(count) };
	else
		return { status = "executing", actions = {"next", "complete", default = "complete"}, form = announce_layout }, "executing";
	end

	return true;
end

local adhoc_new = module:require "adhoc".new;
local announce_desc = adhoc_new("Send Announcement to Online Users", "http://jabber.org/protocol/admin#announce", announce_handler, "admin");
module:provides("adhoc", announce_desc);