-- * Metronome IM *
--
-- This file is part of the Metronome XMPP server and is released under the
-- ISC License, please see the LICENSE file in this source package for more
-- information about copyright and licensing.
--
-- As per the sublicensing clause, this file is also MIT/X11 Licensed.
-- ** Copyright (c) 2008-2013, Brian Cully, Florian Zeitz, Kim Alvefur, Matthew Wild, Waqas Hussain

-- todo: quick (default) header generation
-- todo: nxdomain, error handling
-- todo: cache results of encodeName

-- reference: http://tools.ietf.org/html/rfc1035
-- reference: http://tools.ietf.org/html/rfc1876 (LOC)

local socket = require "socket";
local timer = require "util.timer";

local coroutine, io, math, string =
	coroutine, io, math, string;

local t_concat, t_insert, t_remove, t_sort =
	table.concat, table.insert, table.remove, table.sort;

local s_byte, s_char, s_format, s_gmatch, s_len, s_lower, s_sub =
	string.byte, string.char, string.format, string.gmatch, string.len, string.lower, string.sub;

local ipairs, next, pairs, print, setmetatable, tostring, assert, error, unpack, select, type =
	ipairs, next, pairs, print, setmetatable, tostring, assert, error, unpack, select, type;

local ztact = { -- public domain 20080404 lua@ztact.com
	get = function(parent, ...)
		local len = select('#', ...);
		for i=1,len do
			parent = parent[select(i, ...)];
			if parent == nil then break; end
		end
		return parent;
	end;
	set = function(parent, ...)
		local len = select('#', ...);
		local key, value = select(len-1, ...);
		local cutpoint, cutkey;

		for i=1,len-2 do
			local key = select(i, ...)
			local child = parent[key]

			if value == nil then
				if child == nil then
					return;
				elseif next(child, next(child)) then
					cutpoint = nil; cutkey = nil;
				elseif cutpoint == nil then
					cutpoint = parent; cutkey = key;
				end
			elseif child == nil then
				child = {};
				parent[key] = child;
			end
			parent = child
		end

		if value == nil and cutpoint then
			cutpoint[cutkey] = nil;
		else
			parent[key] = value;
			return value;
		end
	end;
};
local get, set = ztact.get, ztact.set;

local default_timeout = 15;

module('dns')
local dns = _M;


-- Utility functions, types definition and class codes

local function highbyte(i)
	return (i-(i%0x100))/0x100;
end

local function augment(t)
	local a = {};
	for i,s in pairs(t) do
		a[i] = s;
		a[s] = s;
		a[s_lower(s)] = s;
	end
	return a;
end

local function encode(t)
	local code = {};
	for i,s in pairs(t) do
		local word = s_char(highbyte(i), i%0x100);
		code[i] = word;
		code[s] = word;
		code[s_lower(s)] = word;
	end
	return code;
end

dns.types = {
	'A', 'NS', 'MD', 'MF', 'CNAME', 'SOA', 'MB', 'MG', 'MR', 'NULL', 'WKS',
	'PTR', 'HINFO', 'MINFO', 'MX', 'TXT',
	[ 28] = 'AAAA', [ 29] = 'LOC',   [ 33] = 'SRV',
	[252] = 'AXFR', [253] = 'MAILB', [254] = 'MAILA', [255] = '*' 
};

dns.classes = { 'IN', 'CS', 'CH', 'HS', [255] = '*' };

dns.type = augment(dns.types);
dns.class = augment(dns.classes);
dns.typecode = encode(dns.types);
dns.classcode = encode(dns.classes);

local function standardize(qname, qtype, qclass)
	if s_byte(qname, -1) ~= 0x2E then qname = qname..'.';  end
	qname = s_lower(qname);
	return qname, dns.type[qtype or 'A'], dns.class[qclass or 'IN'];
end

local function prune(rrs, time, soft)
	time = time or socket.gettime();
	for i,rr in pairs(rrs) do
		if rr.tod then
			-- rr.tod = rr.tod - 50    -- accelerated decripitude
			rr.ttl = math.floor(rr.tod - time);
			if rr.ttl <= 0 then
				t_remove(rrs, i);
				return prune(rrs, time, soft); -- Re-iterate
			end
		elseif soft == 'soft' then
			assert(rr.ttl == 0);
			rrs[i] = nil;
		end
	end
end


-- Metatables definitions

local resolver = {};
resolver.__index = resolver;

resolver.timeout = default_timeout;

local function default_rr_tostring(rr)
	local rr_val = rr.type and rr[rr.type:lower()];
	if type(rr_val) ~= "string" then
		return "<UNKNOWN RDATA TYPE>";
	end
	return rr_val;
end

local special_tostrings = {
	LOC = resolver.LOC_tostring;
	MX  = function(rr)
		return s_format('%2i %s', rr.pref, rr.mx);
	end;
	SRV = function(rr)
		local s = rr.srv;
		return s_format('%5d %5d %5d %s', s.priority, s.weight, s.port, s.target);
	end;
};

local rr_metatable = {};
function rr_metatable.__tostring(rr)
	local rr_string = (special_tostrings[rr.type] or default_rr_tostring)(rr);
	return s_format('%2s %-5s %6i %-28s %s', rr.class, rr.type, rr.ttl, rr.name, rr_string);
end

local rrs_metatable = {};
function rrs_metatable.__tostring(rrs)
	local t = {};
	for i,rr in pairs(rrs) do
		t_insert(t, tostring(rr)..'\n');
	end
	return t_concat(t);
end

local cache_metatable = {};
function cache_metatable.__tostring(cache)
	local time = socket.gettime();
	local t = {};
	for class,types in pairs(cache) do
		for type,names in pairs(types) do
			for name,rrs in pairs(names) do
				prune(rrs, time);
				t_insert(t, tostring(rrs));
			end
		end
	end
	return t_concat(t);
end

function resolver.new() -- Defines a new resolver object and sets metatables
	local r = { active = {}, cache = {}, unsorted = {}, wanted = {}, yielded = {}, best_server = 1 };
	setmetatable(r, resolver);
	setmetatable(r.cache, cache_metatable);
	setmetatable(r.unsorted, { __mode = 'kv' });
	return r;
end


-- Packet related functions

function dns.random(...)
	math.randomseed(math.floor(10000*socket.gettime()));
	dns.random = math.random;
	return dns.random(...);
end

local function encodeHeader(o)
	o = o or {};
	o.id = o.id or dns.random(0, 0xffff); -- 16b	(random) id

	o.rd = o.rd or 1;		--  1b 1 recursion desired
	o.tc = o.tc or 0;		--  1b 1 truncated response
	o.aa = o.aa or 0;		--  1b 1 authoritative response
	o.opcode = o.opcode or 0;	--  4b 0 query
				--  1 inverse query
				--  2 server status request
				--  3-15 reserved
	o.qr = o.qr or 0;		--  1b	0 query, 1 response

	o.rcode = o.rcode or 0;	--  4b  0 no error
				--	1 format error
				--	2 server failure
				--	3 name error
				--	4 not implemented
				--	5 refused
				--	6-15 reserved
	o.z = o.z  or 0;		--  3b  0 resvered
	o.ra = o.ra or 0;		--  1b  1 recursion available

	o.qdcount = o.qdcount or 1;	-- 16b number of question RRs
	o.ancount = o.ancount or 0;	-- 16b number of answers RRs
	o.nscount = o.nscount or 0;	-- 16b number of nameservers RRs
	o.arcount = o.arcount or 0;	-- 16b number of additional RRs

	-- s_char() rounds, so prevent roundup with -0.4999
	local header = s_char(
		highbyte(o.id), o.id %0x100,
		o.rd + 2*o.tc + 4*o.aa + 8*o.opcode + 128*o.qr,
		o.rcode + 16*o.z + 128*o.ra,
		highbyte(o.qdcount),  o.qdcount %0x100,
		highbyte(o.ancount),  o.ancount %0x100,
		highbyte(o.nscount),  o.nscount %0x100,
		highbyte(o.arcount),  o.arcount %0x100
	);

	return header, o.id;
end

local function encodeName(name)
	local t = {};
	for part in s_gmatch(name, '[^.]+') do
		t_insert(t, s_char(s_len(part)));
		t_insert(t, part);
	end
	t_insert(t, s_char(0));
	return t_concat(t);
end

local function encodeQuestion(qname, qtype, qclass)
	qname  = encodeName(qname);
	qtype  = dns.typecode[qtype or 'a'];
	qclass = dns.classcode[qclass or 'in'];
	return qname..qtype..qclass;
end

function resolver:byte(len)
	len = len or 1;
	local offset = self.offset;
	local last = offset + len - 1;
	if last > #self.packet then
		error(s_format('out of bounds: %i>%i', last, #self.packet));
	end
	self.offset = offset + len;
	return s_byte(self.packet, offset, last);
end

function resolver:word()
	local b1, b2 = self:byte(2);
	return 0x100*b1 + b2;
end

function resolver:dword()
	local b1, b2, b3, b4 = self:byte(4);
	return 0x1000000*b1 + 0x10000*b2 + 0x100*b3 + b4;
end

function resolver:sub(len)
	len = len or 1;
	local s = s_sub(self.packet, self.offset, self.offset + len - 1);
	self.offset = self.offset + len;
	return s;
end

function resolver:header(force)
	local id = self:word();
	if not self.active[id] and not force then return nil; end

	local h = { id = id };

	local b1, b2 = self:byte(2);

	h.rd = b1 %2;
	h.tc = b1 /2%2;
	h.aa = b1 /4%2;
	h.opcode = b1 /8%16;
	h.qr = b1 /128;

	h.rcode = b2 %16;
	h.z = b2 /16%8;
	h.ra = b2 /128;

	h.qdcount = self:word();
	h.ancount = self:word();
	h.nscount = self:word();
	h.arcount = self:word();

	for k,v in pairs(h) do h[k] = v-v%1; end

	return h;
end

function resolver:name()
	local remember, pointers = nil, 0;
	local len = self:byte();
	local n = {};
	if len == 0 then return "." end -- Root label
	while len > 0 do
		if len >= 0xc0 then    -- name is "compressed"
			pointers = pointers + 1;
			if pointers >= 20 then error('dns error: 20 pointers'); end;
			local offset = ((len-0xc0)*0x100) + self:byte();
			remember = remember or self.offset;
			self.offset = offset + 1;    -- +1 for lua
		else    -- name is not compressed
			t_insert(n, self:sub(len)..'.');
		end
		len = self:byte();
	end
	self.offset = remember or self.offset;
	return t_concat(n);
end

function resolver:question()
	local q = {};
	q.name  = self:name();
	q.type  = dns.type[self:word()];
	q.class = dns.class[self:word()];
	return q;
end

-- Record types

function resolver:A(rr)
	local b1, b2, b3, b4 = self:byte(4);
	rr.a = s_format('%i.%i.%i.%i', b1, b2, b3, b4);
end

function resolver:AAAA(rr)
	local addr = {};
	for i = 1, rr.rdlength, 2 do
		local b1, b2 = self:byte(2);
		t_insert(addr, ("%02x%02x"):format(b1, b2));
	end
	addr = t_concat(addr, ":"):gsub("%f[%x]0+(%x)","%1");
	local zeros = {};
	for item in addr:gmatch(":[0:]+:") do
		t_insert(zeros, item)
	end
	if #zeros == 0 then
		rr.aaaa = addr;
		return
	elseif #zeros > 1 then
		t_sort(zeros, function(a, b) return #a > #b end);
	end
	rr.aaaa = addr:gsub(zeros[1], "::", 1):gsub("^0::", "::"):gsub("::0$", "::");
end

function resolver:CNAME(rr)
	rr.cname = self:name();
end

function resolver:MX(rr)
	rr.pref = self:word();
	rr.mx   = self:name();
end

function resolver:LOC_nibble_power()
	local b = self:byte();
	return ((b-(b%0x10))/0x10) * (10^(b%0x10));
end

function resolver:LOC(rr)
	rr.version = self:byte();
	if rr.version == 0 then
		rr.loc = rr.loc or {};
		rr.loc.size = self:LOC_nibble_power();
		rr.loc.horiz_pre = self:LOC_nibble_power();
		rr.loc.vert_pre = self:LOC_nibble_power();
		rr.loc.latitude = self:dword();
		rr.loc.longitude = self:dword();
		rr.loc.altitude = self:dword();
	end
end

local function LOC_tostring_degrees(f, pos, neg)
	f = f - 0x80000000;
	if f < 0 then pos = neg; f = -f; end
	local deg, min, msec;
	msec = f%60000;
	f = (f-msec)/60000;
	min = f%60;
	deg = (f-min)/60;
	return s_format('%3d %2d %2.3f %s', deg, min, msec/1000, pos);
end

function resolver.LOC_tostring(rr)
	local t = {};

	t_insert(t, s_format(
		'%s    %s    %.2fm %.2fm %.2fm %.2fm',
		LOC_tostring_degrees(rr.loc.latitude, 'N', 'S'),
		LOC_tostring_degrees(rr.loc.longitude, 'E', 'W'),
		(rr.loc.altitude - 10000000) / 100,
		rr.loc.size / 100,
		rr.loc.horiz_pre / 100,
		rr.loc.vert_pre / 100
	));

	return t_concat(t);
end

function resolver:NS(rr)
	rr.ns = self:name();
end

function resolver:SOA(rr)
end

function resolver:SRV(rr)
	  rr.srv = {};
	  rr.srv.priority = self:word();
	  rr.srv.weight = self:word();
	  rr.srv.port = self:word();
	  rr.srv.target = self:name();
end

function resolver:PTR(rr)
	rr.ptr = self:name();
end

function resolver:TXT(rr)
	rr.txt = self:sub(self:byte());
end

function resolver:rr()
	local rr = {};
	setmetatable(rr, rr_metatable);
	rr.name = self:name(self);
	rr.type = dns.type[self:word()] or rr.type;
	rr.class = dns.class[self:word()] or rr.class;
	rr.ttl = 0x10000*self:word() + self:word();
	rr.rdlength = self:word();

	if rr.ttl <= 0 then
		rr.tod = self.time + 30;
	else
		rr.tod = self.time + rr.ttl;
	end

	local remember = self.offset;
	local rr_parser = self[dns.type[rr.type]];
	if rr_parser then rr_parser(self, rr); end
	self.offset = remember;
	rr.rdata = self:sub(rr.rdlength);
	return rr;
end

function resolver:rrs(count)
	local rrs = {};
	for i = 1,count do t_insert(rrs, self:rr()); end
	return rrs;
end

-- Record types end

function resolver:decode(packet, force)
	self.packet, self.offset = packet, 1;
	local header = self:header(force);
	if not header then return nil; end
	local response = { header = header };

	response.question = {};
	local offset = self.offset;
	for i = 1,response.header.qdcount do
		t_insert(response.question, self:question());
	end
	response.question.raw = s_sub(self.packet, offset, self.offset - 1);

	if not force then
		if not self.active[response.header.id] or not self.active[response.header.id][response.question.raw] then
			return nil;
		end
	end

	response.answer = self:rrs(response.header.ancount);
	response.authority = self:rrs(response.header.nscount);
	response.additional = self:rrs(response.header.arcount);

	return response;
end


-- Socket related functions

resolver.delays = { 1, 3 };

function resolver:addnameserver(address)
	self.server = self.server or {};
	t_insert(self.server, address);
end

function resolver:setnameservers(addr)
	self:resetobject();
	if type(addr) == "table" then
		for i, server in ipairs(addr) do self:addnameserver(server); end
	elseif type(addr) == "string" then
		self:addnameserver(addr);
	else
		self:addnameserver("127.0.0.1");
		-- Fall back to local resolver
	end
end

function resolver:adddefaultnameservers()
	local resolv_conf = io.open("/etc/resolv.conf");
	if resolv_conf then
		for line in resolv_conf:lines() do
			line = line:gsub("#.*$", "")
				:match('^%s*nameserver%s+(.*)%s*$');
			if line then
				line:gsub("%f[%d.](%d+%.%d+%.%d+%.%d+)%f[^%d.]", function(address)
					self:addnameserver(address)
				end);
			end
		end
	end
	if not self.server or #self.server == 0 then
		self:addnameserver("127.0.0.1");
	end
end

function resolver:resetobject()
	self:closeall();
	self.best_server = 1;
	self.server = nil;
	self.socket = nil;
	self.socketset = nil;
end

function resolver:resetnameservers()
	self:resetobject();
	self:adddefaultnameservers();
end

function resolver:getsocket(servernum)
	self.socket = self.socket or {};
	self.socketset = self.socketset or {};

	local sock = self.socket[servernum];
	if sock then return sock; end

	local err, peer, inet6;
	peer = self.server[servernum];
	inet6 = peer:find(":");

	if inet6 and not socket.udp6 then
		-- LuaSocket doesn't support IPv6
		sock, err = nil, "unable to connect to IPv6 resolvers";
	else
		sock, err = ((inet6 and socket.udp6) or (socket.udp4 or socket.udp))();
	end

	if not sock then
		return nil, err;
	end
	if self.socket_wrapper then sock = self.socket_wrapper(sock, self); end
	sock:settimeout(0);
	-- todo: attempt to use a random port, fallback to 0
	sock:setsockname('*', 0);
	sock:setpeername(peer, 53);
	self.socket[servernum] = sock;
	self.socketset[sock] = servernum;
	return sock;
end

function resolver:voidsocket(sock)
	if self.socket[sock] then
		self.socketset[self.socket[sock]] = nil;
		self.socket[sock] = nil;
	elseif self.socketset[sock] then
		self.socket[self.socketset[sock]] = nil;
		self.socketset[sock] = nil;
	end
end

function resolver:socket_wrapper_set(func)
	self.socket_wrapper = func;
end

function resolver:closeall()
	for i,sock in ipairs(self.socket) do
		self.socket[i] = nil;
		self.socketset[sock] = nil;
		sock:close();
	end
end

function resolver:remember(rr, type)
	local qname, qtype, qclass = standardize(rr.name, rr.type, rr.class);

	if type ~= '*' then
		type = qtype;
		local all = get(self.cache, qclass, '*', qname);
		if all then t_insert(all, rr); end
	end

	self.cache = self.cache or setmetatable({}, cache_metatable);
	local rrs = get(self.cache, qclass, type, qname) or
		set(self.cache, qclass, type, qname, setmetatable({}, rrs_metatable));
	t_insert(rrs, rr);

	if type == 'MX' then self.unsorted[rrs] = true; end
end

local function comp_mx(a, b)
	return (a.pref == b.pref) and (a.mx < b.mx) or (a.pref < b.pref);
end

function resolver:peek(qname, qtype, qclass)
	qname, qtype, qclass = standardize(qname, qtype, qclass);
	local rrs = get(self.cache, qclass, qtype, qname);
	if not rrs then return nil; end
	if prune(rrs, socket.gettime()) and qtype == '*' or not next(rrs) then
		set(self.cache, qclass, qtype, qname, nil);
		return nil;
	end
	if self.unsorted[rrs] then t_sort(rrs, comp_mx); end
	return rrs;
end

function resolver:purge(soft)
	if soft == 'soft' then
		self.time = socket.gettime();
		for class,types in pairs(self.cache or {}) do
			for type,names in pairs(types) do
				for name,rrs in pairs(names) do
					prune(rrs, self.time, 'soft')
				end
			end
		end
	else self.cache = setmetatable({}, cache_metatable); end
end

function resolver:query(qname, qtype, qclass)
	qname, qtype, qclass = standardize(qname, qtype, qclass)

	if not self.server then self:adddefaultnameservers(); end

	local question = encodeQuestion(qname, qtype, qclass);
	local peek = self:peek(qname, qtype, qclass);
	if peek then return peek; end

	local header, id = encodeHeader();
	local o = {
		packet = header..question,
		server = self.best_server,
		delay  = 1,
		retry  = socket.gettime() + self.delays[1]
	};

	-- remember the query
	self.active[id] = self.active[id] or {};
	self.active[id][question] = o;

	-- remember which coroutine wants the answer
	local co = coroutine.running();
	if co then
		set(self.wanted, qclass, qtype, qname, co, true);
	end

	local conn, err = self:getsocket(o.server)
	if not conn then
		return nil, err;
	end
	conn:send(o.packet)
	
	if timer and self.timeout then
		local num_servers = #self.server;
		local i = 1;
		timer.add_task(self.timeout, function()
			if get(self.wanted, qclass, qtype, qname, co) then
				if i < num_servers then
					i = i + 1;
					self:servfail(conn);
					o.server = self.best_server;
					conn, err = self:getsocket(o.server);
					if conn then
						conn:send(o.packet);
						return self.timeout;
					end
				end
				-- Tried everything, failed
				self:cancel(qclass, qtype, qname, co, true);
			end
		end)
	end
	return true;
end

function resolver:servfail(sock)
	-- Resend all queries for this server

	local num = self.socketset[sock]

	-- Socket is dead now
	self:voidsocket(sock);

	-- Find all requests to the down server, and retry on the next server
	self.time = socket.gettime();
	for id,queries in pairs(self.active) do
		for question,o in pairs(queries) do
			if o.server == num then -- This request was to the broken server
				o.server = o.server + 1 -- Use next server
				if o.server > #self.server then
					o.server = 1;
				end

				o.retries = (o.retries or 0) + 1;
				if o.retries >= #self.server then
					queries[question] = nil;
				else
					local _a = self:getsocket(o.server);
					if _a then _a:send(o.packet); end
				end
			end
		end
	end

	if num == self.best_server then
		self.best_server = self.best_server + 1;
		if self.best_server > #self.server then
			-- Exhausted all servers, try first again
			self.best_server = 1;
		end
	end
end

function resolver:settimeout(seconds)
	self.timeout = seconds;
end

function resolver:receive(rset)
	self.time = socket.gettime();
	rset = rset or self.socket;

	local response;
	for i,sock in pairs(rset) do

		if self.socketset[sock] then
			local packet = sock:receive();
			if packet then
				response = self:decode(packet);
				if response and self.active[response.header.id]
					and self.active[response.header.id][response.question.raw] then

					for j,rr in pairs(response.answer) do
						if rr.name:sub(-#response.question[1].name, -1) == response.question[1].name then
							self:remember(rr, response.question[1].type)
						end
					end

					-- retire the query
					local queries = self.active[response.header.id];
					queries[response.question.raw] = nil;
					
					if not next(queries) then self.active[response.header.id] = nil; end
					if not next(self.active) then self:closeall(); end

					-- was the query on the wanted list?
					local q = response.question[1];
					local cos = get(self.wanted, q.class, q.type, q.name);
					if cos then
						for co in pairs(cos) do
							set(self.yielded, co, q.class, q.type, q.name, nil);
							if coroutine.status(co) == "suspended" then coroutine.resume(co); end
						end
						set(self.wanted, q.class, q.type, q.name, nil);
					end
				end
			end
		end
	end

	return response;
end

function resolver:feed(sock, packet, force)
	self.time = socket.gettime();

	local response = self:decode(packet, force);
	if response and self.active[response.header.id]
		and self.active[response.header.id][response.question.raw] then

		for j,rr in pairs(response.answer) do
			self:remember(rr, response.question[1].type);
		end

		-- retire the query
		local queries = self.active[response.header.id];
		queries[response.question.raw] = nil;
		if not next(queries) then self.active[response.header.id] = nil; end
		if not next(self.active) then self:closeall(); end

		-- was the query on the wanted list?
		local q = response.question[1];
		if q then
			local cos = get(self.wanted, q.class, q.type, q.name);
			if cos then
				for co in pairs(cos) do
					set(self.yielded, co, q.class, q.type, q.name, nil);
					if coroutine.status(co) == "suspended" then coroutine.resume(co); end
				end
				set(self.wanted, q.class, q.type, q.name, nil);
			end
		end
	end

	return response;
end

function resolver:cancel(qclass, qtype, qname, co, call_handler)
	local cos = get(self.wanted, qclass, qtype, qname);
	if cos then
		if call_handler then
			coroutine.resume(co);
		end
		cos[co] = nil;
	end
end

function resolver:pulse()
	while self:receive() do end
	if not next(self.active) then return nil; end

	self.time = socket.gettime();
	for id,queries in pairs(self.active) do
		for question,o in pairs(queries) do
			if self.time >= o.retry then

				o.server = o.server + 1;
				if o.server > #self.server then
					o.server = 1;
					o.delay = o.delay + 1;
				end

				if o.delay > #self.delays then
					queries[question] = nil;
					if not next(queries) then self.active[id] = nil; end
					if not next(self.active) then return nil; end
				else
					local _a = self.socket[o.server];
					if _a then _a:send(o.packet); end
					o.retry = self.time + self.delays[o.delay];
				end
			end
		end
	end

	if next(self.active) then return true; end
	return nil;
end

function resolver:lookup(qname, qtype, qclass)
	self:query(qname, qtype, qclass)
	while self:pulse() do
		local recvt = {}
		for i, s in ipairs(self.socket) do
			recvt[i] = s
		end
		socket.select(recvt, nil, 4)
	end
	return self:peek(qname, qtype, qclass);
end

function resolver:lookupex(handler, qname, qtype, qclass)
	return self:peek(qname, qtype, qclass) or self:query(qname, qtype, qclass);
end

function resolver:tohostname(ip)
	return dns.lookup(ip:gsub("(%d+)%.(%d+)%.(%d+)%.(%d+)", "%4.%3.%2.%1.in-addr.arpa."), "PTR");
end


-- Print related functions

local hints = {
	qr = { [0]='query', 'response' },
	opcode = { [0]='query', 'inverse query', 'server status request' },
	aa = { [0]='non-authoritative', 'authoritative' },
	tc = { [0]='complete', 'truncated' },
	rd = { [0]='recursion not desired', 'recursion desired' },
	ra = { [0]='recursion not available', 'recursion available' },
	z  = { [0]='(reserved)' },
	rcode = { [0]='no error', 'format error', 'server failure', 'name error', 'not implemented' },

	type = dns.type,
	class = dns.class
};

local function hint(p, s)
	return (hints[s] and hints[s][p[s]]) or '';
end

function resolver.print(response)
	for s,s in pairs { 'id', 'qr', 'opcode', 'aa', 'tc', 'rd', 'ra', 'z',
						'rcode', 'qdcount', 'ancount', 'nscount', 'arcount' } do
		print( s_format('%-30s', 'header.'..s), response.header[s], hint(response.header, s) );
	end

	for i,question in ipairs(response.question) do
		print(s_format('question[%i].name         ', i), question.name);
		print(s_format('question[%i].type         ', i), question.type);
		print(s_format('question[%i].class        ', i), question.class);
	end

	local common = { name=1, type=1, class=1, ttl=1, rdlength=1, rdata=1 };
	local tmp;
	for s,s in pairs({'answer', 'authority', 'additional'}) do
		for i,rr in pairs(response[s]) do
			for j,t in pairs({ 'name', 'type', 'class', 'ttl', 'rdlength' }) do
				tmp = s_format('%s[%i].%s', s, i, t);
				print(s_format('%-30s', tmp), rr[t], hint(rr, t));
			end
			for j,t in pairs(rr) do
				if not common[j] then
					tmp = s_format('%s[%i].%s', s, i, j);
					print(s_format('%-30s  %s', tostring(tmp), tostring(t)));
				end
			end
		end
	end
end


-- API functions

dns.resolver = resolver.new;

local _resolver = dns.resolver();
dns._resolver = _resolver;

function dns.lookup(...)
	return _resolver:lookup(...);
end

function dns.tohostname(...)
	return _resolver:tohostname(...);
end

function dns.purge(...)
	return _resolver:purge(...);
end

function dns.peek(...)
	return _resolver:peek(...);
end

function dns.query(...)
	return _resolver:query(...);
end

function dns.feed(...)
	return _resolver:feed(...);
end

function dns.cancel(...)
	return _resolver:cancel(...);
end

function dns.settimeout(...)
	return _resolver:settimeout(...);
end

function dns.socket_wrapper_set(...)
	return _resolver:socket_wrapper_set(...);
end

return dns;
