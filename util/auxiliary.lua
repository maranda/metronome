-- * Metronome IM *
--
-- This file is part of the Metronome XMPP server and is released under the
-- ISC License, please see the LICENSE file in this source package for more
-- information about copyright and licensing.

-- This contains the auxiliary utility functions for Metronome's env.

local CFG_SOURCEDIR, open, metronome, type = _G.CFG_SOURCEDIR, io.open, _G.metronome, type;

module "auxiliary"

function read_version()
	local version_file = open((CFG_SOURCEDIR or ".").."/metronome.version");
	if version_file then
		metronome.version = version_file:read("*a"):gsub("%s*$", "");
		version_file:close();
	else
		metronome.version = "unknown";
	end
end

function ripairs(t)
	local function reverse(t,index)
		index = index-1;
		local value = t[index];
		if value == nil then return value; end
		return index, value;
	end
	return reverse, t, #t+1;
end

function clone_table(t)
	local clone = {};
	for key, value in pairs(t) do
		if type(t) == "table" then
			clone[key] = clone_table(value);
		else
			clone[key] = value;
		end
	end
	return clone;
end

return _M;
