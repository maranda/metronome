-- * Metronome IM *
--
-- This file is part of the Metronome XMPP server and is released under the
-- ISC License, please see the LICENSE file in this source package for more
-- information about copyright and licensing.
--
-- As per the sublicensing clause, this file is also MIT/X11 Licensed.
-- ** Copyright (c) 2009-2012, Matthew Wild

local debug = require "util.debug";

module("helpers", package.seeall);

-- Helper functions for debugging

local log = require "util.logger".init("util.debug");

function log_events(events, name, logger)
	local f = events.fire_event;
	if not f then
		error("Object does not appear to be a util.events object");
	end
	logger = logger or log;
	name = name or tostring(events);
	function events.fire_event(event, ...)
		logger("debug", "%s firing event: %s", name, event);
		return f(event, ...);
	end
	events[events.fire_event] = f;
	return events;
end

function revert_log_events(events)
	events.fire_event, events[events.fire_event] = events[events.fire_event], nil; -- :))
end

function show_events(events, specific_event)
	local event_handlers = events._handlers;
	local events_array = {};
	local event_handler_arrays = {};
	for event in pairs(events._event_map) do
		local handlers = event_handlers[event];
		if handlers and (event == specific_event or not specific_event) then
			table.insert(events_array, event);
			local handler_strings = {};
			for i, handler in ipairs(handlers) do
				local upvals = debug.string_from_var_table(debug.get_upvalues_table(handler));
				handler_strings[i] = "  "..i..": "..tostring(handler)..(upvals and ("\n        "..upvals) or "");
			end
			event_handler_arrays[event] = handler_strings;
		end
	end
	table.sort(events_array);
	local i = 1;
	while i <= #events_array do
		local handlers = event_handler_arrays[events_array[i]];
		for j=#handlers, 1, -1 do
			table.insert(events_array, i+1, handlers[j]);
		end
		if i > 1 then events_array[i] = "\n"..events_array[i]; end
		i = i + #handlers + 1
	end
	return table.concat(events_array, "\n");
end

function get_upvalue(f, get_name)
	local i, name, value = 0;
	repeat
		i = i + 1;
		name, value = debug.getupvalue(f, i);
	until name == get_name or name == nil;
	return value;
end

return _M;
