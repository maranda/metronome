local _G = _G;
local metronome = _G.metronome;
local st = require "util.stanza";
local adhoc_new = module:require "adhoc".new;

function uptime()
	local t = tostring(io.popen("cat /proc/uptime"):read():match("^%d*"))
	local seconds = t%60;
	t = (t - seconds)/60;
	local minutes = t%60;
	t = (t - minutes)/60;
	local hours = t%24;
	t = (t - hours)/24;
	local days = t;
	return string.format("This server has been running for %d day%s, %d hour%s and %d minute%s (since %s)", 
		days, (days ~= 1 and "s") or "", hours, (hours ~= 1 and "s") or "", 
		minutes, (minutes ~= 1 and "s") or "", os.date("%c", tostring(os.time()-io.popen("cat /proc/uptime"):read():match("^%d*"))));
end

function uptime_command_handler (self, data, state)
	return { info = uptime(), status = "completed" };
end

local descriptor = adhoc_new("Get uptime", "uptime", uptime_command_handler);

module:add_item ("adhoc", descriptor);
