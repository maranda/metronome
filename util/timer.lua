local server = require "net.server";
local math_min = math.min;
local math_huge = math.huge;
local get_time = require "socket".gettime;
local t_insert = table.insert;
local pairs = pairs;
local type = type;

local data = {};
local new_data = {};

module "timer"

function add_task(delay, callback)
	local current_time = get_time();
	delay = delay + current_time;
	if delay >= current_time then
		t_insert(new_data, {delay, callback});
	else
		local r = callback(current_time);
		if r and type(r) == "number" then
			return add_task(r, callback);
		end
	end
end

server._addtimer(function()
	local current_time = get_time();
	if #new_data > 0 then
		for _, d in pairs(new_data) do
			t_insert(data, d);
		end
		new_data = {};
	end
		
	local next_time = math_huge;
	for i, d in pairs(data) do
		local t, callback = d[1], d[2];
		if t <= current_time then
			data[i] = nil;
			local r = callback(current_time);
			if type(r) == "number" then
				add_task(r, callback);
				next_time = math_min(next_time, r);
			end
		else
			next_time = math_min(next_time, t - current_time);
		end
	end
	return next_time;
end);

return _M;
