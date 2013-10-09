-- * Metronome IM *
--
-- This file is part of the Metronome XMPP server and is released under the
-- ISC License, please see the LICENSE file in this source package for more
-- information about copyright and licensing.
--
-- As per the sublicensing clause, this file is also MIT/X11 Licensed.
-- ** Copyright (c) 2008-2012, Matthew Wild, Waqas Hussain

local t_concat, t_insert = table.concat, table.insert;
local char, format = string.char, string.format;
local tonumber = tonumber;
local ipairs = ipairs;
local io_write = io.write;

module "termcolours"

local stylemap = {
	reset = 0; bright = 1, dim = 2, underscore = 4, blink = 5, reverse = 7, hidden = 8;
	black = 30; red = 31; green = 32; yellow = 33; blue = 34; magenta = 35; cyan = 36; white = 37;
	["black background"] = 40; ["red background"] = 41; ["green background"] = 42; ["yellow background"] = 43; ["blue background"] = 44; ["magenta background"] = 45; ["cyan background"] = 46; ["white background"] = 47;
	bold = 1, dark = 2, underline = 4, underlined = 4, normal = 0;
};

local cssmap = {
	[1] = "font-weight: bold", [2] = "opacity: 0.5", [4] = "text-decoration: underline", [8] = "visibility: hidden",
	[30] = "color:black", [31] = "color:red", [32]="color:green", [33]="color:#FFD700",
	[34] = "color:blue", [35] = "color: magenta", [36] = "color:cyan", [37] = "color: white",
	[40] = "background-color:black", [41] = "background-color:red", [42]="background-color:green",
	[43]="background-color:yellow",	[44] = "background-color:blue", [45] = "background-color: magenta",
	[46] = "background-color:cyan", [47] = "background-color: white";
};

local fmt_string = char(0x1B).."[%sm%s"..char(0x1B).."[0m";
function getstring(style, text)
	if style then
		return format(fmt_string, style, text);
	else
		return text;
	end
end

function getstyle(...)
	local styles, result = { ... }, {};
	for i, style in ipairs(styles) do
		style = stylemap[style];
		if style then
			t_insert(result, style);
		end
	end
	return t_concat(result, ";");
end

local last = "0";
function setstyle(style)
	style = style or "0";
	if style ~= last then
		io_write("\27["..style.."m");
		last = style;
	end
end

local function ansi2css(ansi_codes)
	if ansi_codes == "0" then return "</span>"; end
	local css = {};
	for code in ansi_codes:gmatch("[^;]+") do
		t_insert(css, cssmap[tonumber(code)]);
	end
	return "</span><span style='"..t_concat(css, ";").."'>";
end

function tohtml(input)
	return input:gsub("\027%[(.-)m", ansi2css);
end

return _M;
