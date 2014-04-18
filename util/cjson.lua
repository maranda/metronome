-- * Metronome IM *
--
-- This file is part of the Metronome XMPP server and is released under the
-- ISC License, please see the LICENSE file in this source package for more
-- information about copyright and licensing.

local open, pcall, select = io.open, pcall, select;
local cjson = select(2, pcall(require, "cjson"));
if type(cjson) ~= "table" then -- error
	return false;
end
local decode = cjson.decode;

local function loadfile(file)
	local f = open(file);
	if f then
		local str = f:read("*all");
		local ok, ret = pcall(decode, str);
		if ok then
			return ret;
		else
			return nil, ret;
		end
	end
end

return { loadfile = loadfile, serialize = cjson.encode };
