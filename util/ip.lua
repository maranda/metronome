-- * Metronome IM *
--
-- This file is part of the Metronome XMPP server and is released under the
-- ISC License, please see the LICENSE file in this source package for more
-- information about copyright and licensing.
--
-- As per the sublicensing clause, this file is also MIT/X11 Licensed.
-- ** Copyright (c) 2011-2013, Florian Zeitz, Matthew Wild
--
-- Additional Contributors: Alban Bedel

local ipairs, table = ipairs, table;

local ip_methods = {};
local ip_mt = { __index = function (ip, key) return (ip_methods[key])(ip); end,
		__tostring = function (ip) return ip.addr; end,
		__eq = function (ipA, ipB) return ipA.addr == ipB.addr; end};
local hex2bits = { ["0"] = "0000", ["1"] = "0001", ["2"] = "0010", ["3"] = "0011", ["4"] = "0100", ["5"] = "0101", ["6"] = "0110", ["7"] = "0111", ["8"] = "1000", ["9"] = "1001", ["A"] = "1010", ["B"] = "1011", ["C"] = "1100", ["D"] = "1101", ["E"] = "1110", ["F"] = "1111" };

local function new_ip(ipStr, proto)
	-- If no protocol was given try to autodetect
	if not proto then
		proto = ipStr:match(":") and "IPv6" or "IPv4";
	elseif proto ~= "IPv4" and proto ~= "IPv6" then
		return nil, "invalid protocol";
	end
	if proto == "IPv6" and ipStr:find('.', 1, true) then
		local changed;
		ipStr, changed = ipStr:gsub(":(%d+)%.(%d+)%.(%d+)%.(%d+)$", function(a,b,c,d)
			return (":%04X:%04X"):format(a*256+b,c*256+d);
		end);
		if changed ~= 1 then return nil, "invalid-address"; end
	end

	return setmetatable({ addr = ipStr, proto = proto }, ip_mt);
end

local function toBits(ip)
	local result = "";
	local fields = {};
	if ip.proto == "IPv4" then
		ip = ip.toV4mapped;
	end
	ip = (ip.addr):upper();
	ip:gsub("([^:]*):?", function (c) fields[#fields + 1] = c end);
	if not ip:match(":$") then fields[#fields] = nil; end
	for i, field in ipairs(fields) do
		if field:len() == 0 and i ~= 1 and i ~= #fields then
			for i = 1, 16 * (9 - #fields) do
				result = result .. "0";
			end
		else
			for i = 1, 4 - field:len() do
				result = result .. "0000";
			end
			for i = 1, field:len() do
				result = result .. hex2bits[field:sub(i,i)];
			end
		end
	end
	return result;
end

local function commonPrefixLength(ipA, ipB)
	ipA, ipB = toBits(ipA), toBits(ipB);
	for i = 1, 128 do
		if ipA:sub(i,i) ~= ipB:sub(i,i) then
			return i-1;
		end
	end
	return 128;
end

local function match_prefix(ipA, ipB)
	local len = commonPrefixLength(ipA, ipB);
	return len < 64 and len or 64;
end

local function parse_subnet(subnet)
	local ip, mask = subnet:match("^([%x.:]*)/?(%d*)$");
	ip = ip and new_ip(ip) or nil;
	return ip and { addr = ip, mask = tonumber(mask) } or nil;
end

local function parse_subnets(lst)
	local subnets = {};
	for _, s in ipairs(lst) do
		s = parse_subnet(s);
		if s then
			table.insert(subnets, s);
		end
	end
	return subnets;
end

local function match_subnet(ipA, subnet, len)
	if len and subnet.proto == "IPv4" then
		len = len + 128 - 32;
	end
	ipA, subnet = toBits(ipA), toBits(subnet);
	len = (len == nil or len > 128) and 128 or len;
	return ipA:sub(1, len) == subnet:sub(1, len);
end

local function v4scope(ip)
	local fields = {};
	ip:gsub("([^.]*).?", function (c) fields[#fields + 1] = tonumber(c) end);
	-- Loopback:
	if fields[1] == 127 then
		return 0x2;
	-- Link-local unicast:
	elseif fields[1] == 169 and fields[2] == 254 then
		return 0x2;
	-- Global unicast:
	else
		return 0xE;
	end
end

local function v6scope(ip)
	-- Loopback:
	if ip:match("^[0:]*1$") then
		return 0x2;
	-- Link-local unicast:
	elseif ip:match("^[Ff][Ee][89ABab]") then 
		return 0x2;
	-- Site-local unicast:
	elseif ip:match("^[Ff][Ee][CcDdEeFf]") then
		return 0x5;
	-- Multicast:
	elseif ip:match("^[Ff][Ff]") then
		return tonumber("0x"..ip:sub(4,4));
	-- Global unicast:
	else
		return 0xE;
	end
end

local function label(ip)
	if commonPrefixLength(ip, new_ip("::1", "IPv6")) == 128 then
		return 0;
	elseif commonPrefixLength(ip, new_ip("2002::", "IPv6")) >= 16 then
		return 2;
	elseif commonPrefixLength(ip, new_ip("2001::", "IPv6")) >= 32 then
		return 5;
	elseif commonPrefixLength(ip, new_ip("fc00::", "IPv6")) >= 7 then
		return 13;
	elseif commonPrefixLength(ip, new_ip("fec0::", "IPv6")) >= 10 then
		return 11;
	elseif commonPrefixLength(ip, new_ip("3ffe::", "IPv6")) >= 16 then
		return 12;
	elseif commonPrefixLength(ip, new_ip("::", "IPv6")) >= 96 then
		return 3;
	elseif commonPrefixLength(ip, new_ip("::ffff:0:0", "IPv6")) >= 96 then
		return 4;
	else
		return 1;
	end
end

local function precedence(ip)
	if commonPrefixLength(ip, new_ip("::1", "IPv6")) == 128 then
		return 50;
	elseif commonPrefixLength(ip, new_ip("2002::", "IPv6")) >= 16 then
		return 30;
	elseif commonPrefixLength(ip, new_ip("2001::", "IPv6")) >= 32 then
		return 5;
	elseif commonPrefixLength(ip, new_ip("fc00::", "IPv6")) >= 7 then
		return 3;
	elseif commonPrefixLength(ip, new_ip("fec0::", "IPv6")) >= 10 then
		return 1;
	elseif commonPrefixLength(ip, new_ip("3ffe::", "IPv6")) >= 16 then
		return 1;
	elseif commonPrefixLength(ip, new_ip("::", "IPv6")) >= 96 then
		return 1;
	elseif commonPrefixLength(ip, new_ip("::ffff:0:0", "IPv6")) >= 96 then
		return 35;
	else
		return 40;
	end
end

local function toV4mapped(ip)
	local fields = {};
	local ret = "::ffff:";
	ip:gsub("([^.]*).?", function (c) fields[#fields + 1] = tonumber(c) end);
	ret = ret .. ("%02x"):format(fields[1]);
	ret = ret .. ("%02x"):format(fields[2]);
	ret = ret .. ":"
	ret = ret .. ("%02x"):format(fields[3]);
	ret = ret .. ("%02x"):format(fields[4]);
	return new_ip(ret, "IPv6");
end

local function compare_destination(ipA, ipB, sourceAddrs)
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

local function compare_source(ipA, ipB, dest)
	-- Rule 1: Prefer same address
	if dest == ipA then
		return true;
	elseif dest == ipB then
		return false;
	end

	-- Rule 2: Prefer appropriate scope
	if ipA.scope < ipB.scope then
		if ipA.scope < dest.scope then
			return false;
		else
			return true;
		end
	elseif ipA.scope > ipB.scope then
		if ipB.scope < dest.scope then
			return true;
		else
			return false;
		end
	end

	-- Rule 6: Prefer matching label
	if ipA.label == dest.label and ipB.label ~= dest.label then
		return true;
	elseif ipB.label == dest.label and ipA.label ~= dest.label then
		return false;
	end

	-- Rule 8: Use longest matching prefix
	if match_prefix(ipA, dest) > match_prefix(ipB, dest) then
		return true;
	else
		return false;
	end
end

-- Methods

function ip_methods:toV4mapped()
	if self.proto ~= "IPv4" then return nil, "No IPv4 address" end
	local value = toV4mapped(self.addr);
	self.toV4mapped = value;
	return value;
end

function ip_methods:label()
	local value;
	if self.proto == "IPv4" then
		value = label(self.toV4mapped);
	else
		value = label(self);
	end
	self.label = value;
	return value;
end

function ip_methods:precedence()
	local value;
	if self.proto == "IPv4" then
		value = precedence(self.toV4mapped);
	else
		value = precedence(self);
	end
	self.precedence = value;
	return value;
end

function ip_methods:scope()
	local value;
	if self.proto == "IPv4" then
		value = v4scope(self.addr);
	else
		value = v6scope(self.addr);
	end
	self.scope = value;
	return value;
end

return {
	new_ip = new_ip,
	compare_destination = compare_destination,
	compare_source = compare_source,
	match_prefix = match_prefix,
	match_subnet = match_subnet,
	parse_subnets = parse_subnets
};
