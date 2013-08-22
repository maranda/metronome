-- * Metronome IM *
--
-- This file is part of the Metronome XMPP server and is released under the
-- ISC License, please see the LICENSE file in this source package for more
-- information about copyright and licensing.
--
-- As per the sublicensing clause, this file is also MIT/X11 Licensed.
-- ** Copyright (c) 2013, Florian Zeitz (rfc6724.lua)

local match_prefix = require"util.ip".match_prefix;
local compare_destination = require"util.ip".compare_destination;
local compare_source = require"util.ip".compare_source;

local function t_sort(t, comp, param)
	for i = 1, (#t - 1) do
		for j = (i + 1), #t do
			local a, b = t[i], t[j];
			if not comp(a, b, param) then
				t[i], t[j] = b, a;
			end
		end
	end
end

local function source(dest, candidates)
	t_sort(candidates, compare_source, dest);
	return candidates[1];
end

local function destination(candidates, sources)
	local sourceAddrs = {};
	for _, ip in ipairs(candidates) do
		sourceAddrs[ip] = source(ip, sources);
	end

	t_sort(candidates, compare_destination, sourceAddrs);
	return candidates;
end

return { source = source, destination = destination };