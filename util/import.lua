-- * Metronome IM *
--
-- This file is part of the Metronome XMPP server and is released under the
-- ISC License, please see the LICENSE file in this source package for more
-- information about copyright and licensing.
--
-- As per the sublicensing clause, this file is also MIT/X11 Licensed.
-- ** Copyright (c) 2009-2010, Matthew Wild

local t_insert = table.insert;
function import(module, ...)
	local m = package.loaded[module] or require(module);
	if type(m) == "table" and ... then
		local ret = {};
		for _, f in ipairs{...} do
			t_insert(ret, m[f]);
		end
		return unpack(ret);
	end
	return m;
end
