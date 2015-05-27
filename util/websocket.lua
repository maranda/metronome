-- * Metronome IM *
--
-- This file is part of the Metronome XMPP server and is released under the
-- ISC License, please see the LICENSE file in this source package for more
-- information about copyright and licensing.
--
-- As per the sublicensing clause, this file is also MIT/X11 Licensed.
-- ** Copyright (c) 2012-2013, Florian Zeitz
--
-- This is an object adaptation of websocket parsing routines in mod_websocket
-- from Prosody Modules.

local log = require "util.logger".init("websocket");
local softreq = require "util.dependencies".softreq;

local bit;
do
	pcall(function() bit = require"bit"; end);
	bit = bit or softreq"bit32";
end
if not bit then error("This library requires either LuaJIT 2, lua-bitop or Lua 5.2"); end
local band = bit.band;
local bxor = bit.bxor;
local rshift = bit.rshift;

local byte = string.byte;
local char = string.char;
local concat = table.concat;
local setmetatable = setmetatable;

module "websocket";

local ws = {};
local mt = { __index = ws };

function ws:build(desc)
	local length;
	local result = {};
	local data = desc.data or "";

	result[#result+1] = char(0x80 * (desc.FIN and 1 or 0) + desc.opcode);

	length = #data;
	if length <= 125 then -- 7-bit length
		result[#result+1] = char(length);
	elseif length <= 0xFFFF then -- 2-byte length
		result[#result+1] = char(126);
		result[#result+1] = char(rshift(length, 8)) .. char(length%0x100);
	else -- 8-byte length
		result[#result+1] = char(127);
		local length_bytes = {};
		for i = 8, 1, -1 do
			length_bytes[i] = char(length % 0x100);
			length = rshift(length, 8);
		end
		result[#result+1] = concat(length_bytes, "");
	end

	result[#result+1] = data;

	return concat(result, "");
end
		
function ws:close(code, message)
	local data = char(rshift(code, 8)) .. char(code%0x100) .. message;
	self.conn:write(self:build({opcode = 0x8, FIN = true, data = data}));
	self.conn:close();
end
	
function ws:parse(frame)
	local result = {};
	local pos = 1;
	local length_bytes = 0;
	local tmp_byte;

	if #frame < 2 then return; end

	tmp_byte = byte(frame, pos);
	result.FIN = band(tmp_byte, 0x80) > 0;
	result.RSV1 = band(tmp_byte, 0x40) > 0;
	result.RSV2 = band(tmp_byte, 0x20) > 0;
	result.RSV3 = band(tmp_byte, 0x10) > 0;
	result.opcode = band(tmp_byte, 0x0F);

	pos = pos + 1;
	tmp_byte = byte(frame, pos);
	result.MASK = band(tmp_byte, 0x80) > 0;
	result.length = band(tmp_byte, 0x7F);

	if result.length == 126 then
		length_bytes = 2;
		result.length = 0;
	elseif result.length == 127 then
		length_bytes = 8;
		result.length = 0;
	end

	if #frame < (2 + length_bytes) then return; end

	for i = 1, length_bytes do
		pos = pos + 1;
		result.length = result.length * 256 + byte(frame, pos);
	end

	if #frame < (2 + length_bytes + (result.MASK and 4 or 0) + result.length) then return; end

	if result.MASK then
		local counter = 0;
		local data = {};
		local key = {byte(frame, pos+1), byte(frame, pos+2),
				byte(frame, pos+3), byte(frame, pos+4)}
		result.key = key;

		pos = pos + 5;
		for i = pos, pos + result.length - 1 do
			data[#data+1] = char(bxor(key[counter+1], byte(frame, i)));
			counter = (counter + 1) % 4;
		end
		result.data = concat(data, "");
	else
		result.data = frame:sub(pos + 1, pos + result.length);
	end

	return result, 2 + length_bytes + (result.MASK and 4 or 0) + result.length;
end
	
function ws:handle(frame)
	local conn, length, opcode = self.conn, frame.length, frame.opcode;
	log("debug", "Websocket received: %s (%i bytes)", self.frame_log and frame.data or "<filtered>", #frame.data);
	
	local buffer = self.buffer;

	-- Error cases
	if frame.RSV1 or frame.RSV2 or frame.RSV3 then -- Reserved bits non zero
		self:close(1002, "Reserved bits not zero");
		return false;
	end

	if opcode == 0x8 then
		if length == 1 then
			self:close(1002, "Close frame with payload, but too short for status code");
			return false;
		elseif length >= 2 then
			local status_code = byte(frame.data, 1) * 256 + byte(frame.data, 2)
			if status_code < 1000 then
				self:close(1002, "Closed with invalid status code");
				return false;
			elseif ((status_code > 1003 and status_code < 1007) or status_code > 1011) and status_code < 3000 then
				self:close(1002, "Cosed with reserved status code");
				return false;
			end
		end
	end

	if opcode >= 0x8 then
		if length > 125 then -- Control frame with too much payload
			self:close(1002, "Payload too large");
			return false;
		end

		if not frame.FIN then -- Fragmented control frame
			self:close(1002, "Fragmented control frame");
			return false;
		end
	end

	if (opcode > 0x2 and opcode < 0x8) or (opcode > 0xA) then
		self:close(1002, "Reserved opcode");
		return false;
	end

	if opcode == 0x0 and not buffer then
		self:close(1002, "Unexpected continuation frame");
		return false;
	end

	if (opcode == 0x1 or opcode == 0x2) and buffer then
		self:close(1002, "Continuation frame expected");
		return false;
	end

	-- Valid cases
	if opcode == 0x0 then -- Continuation frame
		buffer[#buffer + 1] = frame.data;
	elseif opcode == 0x1 then -- Text frame
		self.buffer = { frame.data };
		buffer = self.buffer;
	elseif opcode == 0x2 then -- Binary frame
		self:close(1003, "Only text frames are supported");
		return;
	elseif opcode == 0x8 then -- Close request
		self:close(1000, "Goodbye");
		return;
	elseif opcode == 0x9 then -- Ping frame
		frame.opcode = 0xA;
		conn:write(self:build(frame));
		return "";
	else
		log("warn", "Received frame with unsupported opcode %i", opcode);
		return "";
	end

	if frame.FIN then
		local data = concat(buffer, "");
		self.buffer = nil;
		return data;
	end
	return "";
end
	
function new(conn, _log) return setmetatable({ conn = conn, frame_log = _log }, mt); end
	
return _M;
