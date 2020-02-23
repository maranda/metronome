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
local uuid = require "util.uuid".generate;
local pairs = pairs;

local _ENV = nil;

local event = server.event;
local event_base = server.event_base;
local EVENT_LEAVE = (event.core and event.core.LEAVE) or -1;

task_list = {};
local _M;

function _M.add_task(delay, callback, origin, host)
	local uuid, event_handle = uuid();
	task_list[uuid] = { delay = delay, callback = callback, origin = origin, host = host };
	event_handle = event_base:addevent(nil, 0, function ()
		if not task_list[uuid] then return EVENT_LEAVE; end

		local ret = callback(get_time());
		if ret then
			return 0, ret;
		elseif event_handle then
			task_list[uuid] = nil;
			return EVENT_LEAVE;
		end
	end
	, delay);
	return uuid;
end

function _M.remove_task(uuid)
	if uuid and task_list[uuid] then
		task_list[uuid] = nil;
		return true;
	else
		return false;
	end
end

function _M.remove_tasks_from_origin(origin, host)
	if not (origin and host) then return 0; end
	local count = 0;
	for uuid, task in pairs(task_list) do
		if task.origin == origin and task.host == host then
			task_list[uuid] = nil;
			count = count + 1;
		end
	end
	return count;
end

return _M;
