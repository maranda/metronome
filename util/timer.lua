-- * Metronome IM *
--
-- This file is part of the Metronome XMPP server and is released under the
-- ISC License, please see the LICENSE file in this source package for more
-- information about copyright and licensing.
--
-- As per the sublicensing clause, this file is also MIT/X11 Licensed.
-- ** Copyright (c) 2009-2011, Matthew Wild, Waqas Hussain

local server = require "net.server";
local math_min = math.min;
local math_huge = math.huge;
local get_time = require "socket".gettime;

module "timer"

local event = server.event;
local event_base = server.event_base;
local EVENT_LEAVE = (event.core and event.core.LEAVE) or -1;

function add_task(delay, callback)
	local event_handle;
	event_handle = event_base:addevent(nil, 0, function ()
		local ret = callback(get_time());
		if ret then
			return 0, ret;
		elseif event_handle then
			return EVENT_LEAVE;
		end
	end
	, delay);
end

return _M;
