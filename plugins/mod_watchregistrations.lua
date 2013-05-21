-- * Metronome IM *
--
-- This file is part of the Metronome XMPP server and is released under the
-- ISC License, please see the LICENSE file in this source package for more
-- information about copyright and licensing.
--
-- As per the sublicensing clause, this file is also MIT/X11 Licensed.
-- ** Copyright (c) 2009-2012, Kim Alvefur, Matthew Wild, Waqas Hussain

local host = module:get_host();
local jid_prep = require "util.jid".prep;

local registration_watchers = module:get_option_set("registration_watchers", module:get_option("admins", {})) / jid_prep;
local registration_notification = module:get_option("registration_notification", "User $username just registered on $host from $ip");

local st = require "util.stanza";

module:hook("user-registered", function (user)
	module:log("debug", "Notifying of new registration");
	local message = st.message{ type = "chat", from = host }
		:tag("body")
			:text(registration_notification:gsub("%$(%w+)", function (v)
				return user[v] or user.session and user.session[v] or nil;
			end));
	for jid in registration_watchers do
		module:log("debug", "Notifying %s", jid);
		message.attr.to = jid;
		module:send(message);
	end
end);
