-- * Metronome IM *
--
-- This file is part of the Metronome XMPP server and is released under the
-- ISC License, please see the LICENSE file in this source package for more
-- information about copyright and licensing.
--
-- As per the sublicensing clause, this file is also MIT/X11 Licensed.
-- ** Copyright (c) 2014 Kim Alvefur

local next, count = next, require "util.iterators".count;

local max_resources = module:get_option_number("max_resources", 10);

local sessions = hosts[module.host].sessions;
module:hook("resource-bind", function(event)
        local session = event.session;
        if count(next, sessions[session.username].sessions) > max_resources then
                session:close{ condition = "policy-violation", text = "Too many resources" };
                return false
        end
end, -1);
