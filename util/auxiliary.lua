-- * Metronome IM *
--
-- This file is part of the Metronome XMPP server and is released under the
-- ISC License, please see the LICENSE file in this source package for more
-- information.

-- This contains the auxiliary utility functions for Metronome's env.

local CFG_SOURCEDIR, open, metronome = _G.CFG_SOURCEDIR, io.open, _G.metronome;

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

return _M;
