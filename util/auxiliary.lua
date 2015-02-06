-- * Metronome IM *
--
-- This file is part of the Metronome XMPP server and is released under the
-- ISC License, please see the LICENSE file in this source package for more
-- information about copyright and licensing.

-- This contains the auxiliary utility functions for Metronome's env.

local CFG_SOURCEDIR, metronome = _G.CFG_SOURCEDIR, _G.metronome;
local open, popen = io.open, io.popen;
local char, next, pairs, tonumber, type = string.char, next, pairs, tonumber, type;

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

function get_openssl_version()
	-- will possibly work only on linux likes which have a globally installed
	-- openssl.
	local version = popen("openssl version"):read();
	if version then
		version = version:match("^OpenSSL%s([%d%p]+)"):gsub("%p", "");
		return tonumber(version);
	else
		return false;
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
		if type(value) == "table" then
			clone[key] = clone_table(value);
		else
			clone[key] = value;
		end
	end
	return clone;
end

function clean_table(t)
	for key, value in pairs(t) do
		if type(value) == "table" and not next(value) then
			t[key] = nil;
		elseif type(value) == "table" then
			clean_table(value);
			if not next(value) then t[key] = nil; end
		end
	end
end

function escape_magic_chars(string)
	-- escape magic characters
	string = string:gsub("%(", "%%(")
	string = string:gsub("%)", "%%)")
	string = string:gsub("%.", "%%.")
	string = string:gsub("%%", "%%")
	string = string:gsub("%+", "%%+")
	string = string:gsub("%-", "%%-")
	string = string:gsub("%*", "%%*")
	string = string:gsub("%?", "%%?")
	string = string:gsub("%[", "%%[")
	string = string:gsub("%]", "%%]")
	string = string:gsub("%^", "%%^")
	string = string:gsub("%$", "%%$")

	return string
end

function html_escape(t)
	if t then
		t = t:gsub("<", "&lt;");
		t = t:gsub(">", "&gt;");
		t = t:gsub("(http://[%a%d@%.:/&%?=%-_#%%~]+)", function(h)
			h = h:gsub("+", " ");
			h = h:gsub("%%(%x%x)", function(h) return char(tonumber(h,16)) end);
			h = h:gsub("\r\n", "\n");
			return "<a href='" .. h .. "'>" .. h .. "</a>";
		end);
		t = t:gsub("\n", "<br />");
		t = t:gsub("%%", "%%%%");
	else
		t = "";
	end
	return t;
end

function load_file(f, mode)
	local file, err, ret = open(f, mode or "r");
	if file then
		ret = file:read("*a");
		file:close();
	end
	return ret, err;
end

return _M;
