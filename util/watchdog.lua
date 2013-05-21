-- * Metronome IM *
--
-- This file is part of the Metronome XMPP server and is released under the
-- ISC License, please see the LICENSE file in this source package for more
-- information about copyright and licensing.
--
-- As per the sublicensing clause, this file is also MIT/X11 Licensed.
-- ** Copyright (c) 2011-2012, Matthew Wild

local timer = require "util.timer";
local setmetatable = setmetatable;
local os_time = os.time;

module "watchdog"

local watchdog_methods = {};
local watchdog_mt = { __index = watchdog_methods };

function new(timeout, callback)
	local watchdog = setmetatable({ timeout = timeout, last_reset = os_time(), callback = callback }, watchdog_mt);
	timer.add_task(timeout+1, function (current_time)
		local last_reset = watchdog.last_reset;
		if not last_reset then
			return;
		end
		local time_left = (last_reset + timeout) - current_time;
		if time_left < 0 then
			return watchdog:callback();
		end
		return time_left + 1;
	end);
	return watchdog;
end

function watchdog_methods:reset()
	self.last_reset = os_time();
end

function watchdog_methods:cancel()
	self.last_reset = nil;
end

return _M;
