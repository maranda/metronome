-- Copyright (C) 2009 Thilo Cestonaro
-- 
-- This file is MIT/X11 licensed. Please see the
-- COPYING file in the source package for more information.
--

local st = require "util.stanza";
local adhoc_new = module:require "adhoc".new;

function ping_command_handler (self, data, state)
	local now = os.date("%Y-%m-%dT%X");
	return { info = "Pong\n"..now, status = "completed" };
end

local descriptor = adhoc_new("Ping", "ping", ping_command_handler);

module:add_item ("adhoc", descriptor);

