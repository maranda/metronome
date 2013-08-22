-- * Metronome IM *
--
-- This file is part of the Metronome XMPP server and is released under the
-- ISC License, please see the LICENSE file in this source package for more
-- information about copyright and licensing.
--
-- As per the sublicensing clause, this file is also MIT/X11 Licensed.
-- ** Copyright (c) 2013, Florian Zeitz (rfc6724.lua)

local match_prefix = require"util.ip".match_prefix;
local compare_sources = require"util.ip".compare_sources;

local function t_sort(t, comp)
	for i = 1, (#t - 1) do
		for j = (i + 1), #t do
			local a, b = t[i], t[j];
			if not comp(a,b) then
				t[i], t[j] = b, a;
			end
		end
	end
end

local function source(dest, candidates)
	t_sort(candidates, compare_sources);
	return candidates[1];
end

local function destination(candidates, sources)
	local sourceAddrs = {};
	local function comp(ipA, ipB)
		local ipAsource = sourceAddrs[ipA];
		local ipBsource = sourceAddrs[ipB];
		-- Rule 2: Prefer matching scope
		if ipA.scope == ipAsource.scope and ipB.scope ~= ipBsource.scope then
			return true;
		elseif ipA.scope ~= ipAsource.scope and ipB.scope == ipBsource.scope then
			return false;
		end

		-- Rule 5: Prefer matching label
		if ipAsource.label == ipA.label and ipBsource.label ~= ipB.label then
			return true;
		elseif ipBsource.label == ipB.label and ipAsource.label ~= ipA.label then
			return false;
		end

		-- Rule 6: Prefer higher precedence
		if ipA.precedence > ipB.precedence then
			return true;
		elseif ipA.precedence < ipB.precedence then
			return false;
		end

		-- Rule 8: Prefer smaller scope
		if ipA.scope < ipB.scope then
			return true;
		elseif ipA.scope > ipB.scope then
			return false;
		end

		-- Rule 9: Use longest matching prefix
		if match_prefix(ipA, ipAsource) > match_prefix(ipB, ipBsource) then
			return true;
		elseif match_prefix(ipA, ipAsource) < match_prefix(ipB, ipBsource) then
			return false;
		end

		-- Rule 10: Otherwise, leave order unchanged
		return true;
	end
	for _, ip in ipairs(candidates) do
		sourceAddrs[ip] = source(ip, sources);
	end

	t_sort(candidates, comp);
	return candidates;
end

return { source = source, destination = destination };