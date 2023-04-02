-- * Metronome IM *
--
-- This file is part of the Metronome XMPP server and is released under the
-- ISC License, please see the LICENSE file in this source package for more
-- information about copyright and licensing.
--
-- As per the sublicensing clause, this file is also MIT/X11 Licensed.
-- ** Copyright (c) 2012-2013, Florian Zeitz, Kim Alvefur, Matthew Wild, Waqas Hussain

local portmanager = require "core.portmanager";
local wrapclient = require "net.server".wrapclient;
local get_ssl_config = require "util.certmanager".get_ssl_config;
local initialize_filters = require "util.filters".initialize;
local idna_to_ascii = require "util.encodings".idna.to_ascii;
local new_ip = require "util.ip".new_ip;
local select_destination = require "util.address_selection".destination;
local socket = require "socket";
local adns = require "net.adns";
local dns = require "net.dns";
local set_new = require "util.set".new;
local t_insert, t_sort, ipairs = table.insert, table.sort, ipairs;
local st = require "util.stanza";

local s2s_destroy_session = require "util.s2smanager".destroy_session;

local log = module._log;

local sources = {};
local has_ipv4, has_ipv6;

local dns_timeout = module:get_option_number("dns_timeout", 15);
dns.settimeout(dns_timeout);
local max_dns_depth = module:get_option_number("dns_max_depth", 3);

local s2sout = {};
local s2s_listener;
local hosts = hosts;

function s2sout.set_listener(listener)
	s2s_listener = listener;
end

local function compare_srv_priorities(a,b)
	return a.priority < b.priority or (a.priority == b.priority and a.weight > b.weight);
end

function s2sout.initiate_connection(host_session)
	initialize_filters(host_session);
	host_session.version = 1;
	
	-- Kick the connection attempting machine into life
	if not s2sout.attempt_connection(host_session) then
		-- Intentionally not returning here, the
		-- session is needed, connected or not
		s2s_destroy_session(host_session);
	end
end

function s2sout.attempt_connection(host_session, err)
	local from_host, to_host = host_session.from_host, host_session.to_host;
	local connect_host, connect_port = to_host and idna_to_ascii(to_host), 5269;
	
	if not connect_host then
		return false;
	end

	local handle, first_lookup;
	local function callback(answer)
		handle = nil;
		host_session.connecting = nil;
		if answer then
			log("debug", "%s has %sSRV records, handling...", to_host, first_lookup and "direct TLS " or "");
			if not host_session.srv_hosts then host_session.srv_hosts = {}; end
			local srv_hosts = host_session.srv_hosts;
			for _, record in ipairs(answer) do
				record.srv.direct_tls = first_lookup and true or nil;
				t_insert(srv_hosts, record.srv);
			end
			if #srv_hosts == 1 and srv_hosts[1].target == "." then
				log("debug", "%s does not provide a %sXMPP service", to_host, first_lookup and "direct TLS " or "");
				if not first_lookup then
					s2s_destroy_session(host_session, err); -- Nothing to see here
					return;
				end
			end
			if not first_lookup then
				t_sort(srv_hosts, compare_srv_priorities);
			
				local srv_choice = srv_hosts[1];
				host_session.srv_choice = 1;
				host_session.direct_tls_s2s = srv_choice.direct_tls and true or nil;
				if srv_choice then
					connect_host, connect_port = srv_choice.target or to_host, srv_choice.port or connect_port;
					log("debug", "Best record found, will connect to %s:%d", connect_host, connect_port);
				end
			end
		else
			if not first_lookup and not host_session.srv_hosts then
				log("debug", "%s has no SRV records, falling back to A/AAAA", to_host);
				host_session.no_srv_records = true;
			end
		end
		local ok, err;
		if first_lookup then
			host_session.done_first_lookup = true;
		else
			-- Try with SRV, or just the plain hostname if no SRV
			ok, err = s2sout.try_connect(host_session, connect_host, connect_port);
		end
		if not ok then
			if not s2sout.attempt_connection(host_session, err) then
				s2s_destroy_session(host_session, err);
			end
		end
	end
	
	if not err then -- First attempt
		host_session.connecting = true;
		if not host_session.done_first_lookup and host_session.tls_capable then
			log("debug", "Starting lookup for %s, beginning gathering of Direct TLS SRV records...", to_host);
			first_lookup = true;
			handle = adns.lookup(callback, "_xmpps-server._tcp."..connect_host..".", "SRV");
		elseif not host_session.no_srv_records then
			log("debug", "Finalising SRV record lookup for %s...", to_host);
			handle = adns.lookup(callback, "_xmpp-server._tcp."..connect_host..".", "SRV");
		end
		
		return true; -- Attempt in progress
	elseif host_session.ip_hosts then
		return s2sout.try_connect(host_session, connect_host, connect_port, err);
	elseif host_session.srv_hosts and host_session.srv_choice and #host_session.srv_hosts > host_session.srv_choice then -- Not our first attempt, and we also have SRV
		host_session.srv_choice = host_session.srv_choice + 1;
		local srv_choice = host_session.srv_hosts[host_session.srv_choice];
		if srv_choice.direct_tls then
			host_session.direct_tls_s2s = true;
		else
			host_session.direct_tls_s2s = nil;
		end
		connect_host, connect_port = srv_choice.target or to_host, srv_choice.port or connect_port;
		host_session.log("info", "Connection failed (%s). Attempt #%d: This time to %s:%d", tostring(err), host_session.srv_choice, connect_host, connect_port);
	else
		host_session.log("info", "Out of connection options, can't connect to %s", tostring(host_session.to_host));
		-- We're out of options
		return false;
	end
	
	if not (connect_host and connect_port) then
		-- Likely we couldn't resolve DNS
		log("warn", "Hmm, we're without a host (%s) and port (%s) to connect to for %s, giving up :(", tostring(connect_host), tostring(connect_port), tostring(to_host));
		return false;
	end

	return s2sout.try_connect(host_session, connect_host, connect_port);
end

function s2sout.try_next_ip(host_session)
	host_session.connecting = nil;
	host_session.ip_choice = host_session.ip_choice + 1;
	local ip = host_session.ip_hosts[host_session.ip_choice];
	local ok, err= s2sout.make_connect(host_session, ip.ip, ip.port);
	if not ok then
		if not s2sout.attempt_connection(host_session, err or "closed") then
			err = err and (": "..err) or "";
			s2s_destroy_session(host_session, "Connection failed"..err);
		end
	end
end

function s2sout.try_connect(host_session, connect_host, connect_port, err)
	host_session.connecting = true;

	if not err then
		local IPs = {};
		local have_already = set_new{};
		host_session.ip_hosts = IPs;
		local handle4, handle6;
		local have_other_result = not(has_ipv4) or not(has_ipv6) or false;

		if has_ipv4 then
			handle4 = adns.lookup(function (reply, err)
				handle4 = nil;

				-- COMPAT: This is a compromise for all you CNAME-(ab)users :)
				if not (reply and reply[#reply] and reply[#reply].a) then
					local count = max_dns_depth;
					reply = dns.peek(connect_host, "CNAME", "IN");
					while count > 0 and reply and reply[#reply] and not reply[#reply].a and reply[#reply].cname do
						log("debug", "Looking up %s (DNS depth is %d)", tostring(reply[#reply].cname), count);
						reply = dns.peek(reply[#reply].cname, "A", "IN") or dns.peek(reply[#reply].cname, "CNAME", "IN");
						count = count - 1;
					end
				end
				-- end of CNAME resolving

				if reply and reply[#reply] and reply[#reply].a then
					for _, ip in ipairs(reply) do
						if not have_already:contains(ip.a) then
							log("debug", "DNS reply for %s gives us %s", connect_host, ip.a);
							IPs[#IPs+1] = new_ip(ip.a, "IPv4");
							have_already:add(ip.a);
						end
					end
				end

				if have_other_result then
					if #IPs > 0 then
						select_destination(host_session.ip_hosts, sources);
						for i = 1, #IPs do
							IPs[i] = {ip = IPs[i], port = connect_port};
						end
						host_session.ip_choice = 0;
						s2sout.try_next_ip(host_session);
					else
						log("debug", "DNS lookup failed to get a response for %s", connect_host);
						host_session.ip_hosts = nil;
						if not s2sout.attempt_connection(host_session, "name resolution failed") then -- Retry if we can
							log("debug", "No other records to try for %s - destroying", host_session.to_host);
							err = err and (": "..err) or "";
							s2s_destroy_session(host_session, "DNS resolution failed"..err); -- End of the line, we can't
						end
					end
				else
					have_other_result = true;
				end
			end, connect_host, "A", "IN");
		else
			have_other_result = true;
		end

		if has_ipv6 then
			handle6 = adns.lookup(function (reply, err)
				handle6 = nil;

				if reply and reply[#reply] and reply[#reply].aaaa then
					for _, ip in ipairs(reply) do
						if not have_already:contains(ip.aaaa) then
							log("debug", "DNS reply for %s gives us %s", connect_host, ip.aaaa);
							IPs[#IPs+1] = new_ip(ip.aaaa, "IPv6");
							have_already:add(ip.aaaa);
						end
					end
				end

				if have_other_result then
					if #IPs > 0 then
						select_destination(host_session.ip_hosts, sources);
						for i = 1, #IPs do
							IPs[i] = {ip = IPs[i], port = connect_port};
						end
						host_session.ip_choice = 0;
						s2sout.try_next_ip(host_session);
					else
						log("debug", "DNS lookup failed to get a response for %s", connect_host);
						host_session.ip_hosts = nil;
						if not s2sout.attempt_connection(host_session, "name resolution failed") then -- Retry if we can
							log("debug", "No other records to try for %s - destroying", host_session.to_host);
							err = err and (": "..err) or "";
							s2s_destroy_session(host_session, "DNS resolution failed"..err); -- End of the line, we can't
						end
					end
				else
					have_other_result = true;
				end
			end, connect_host, "AAAA", "IN");
		else
			have_other_result = true;
		end
		return true;
	elseif host_session.ip_hosts and #host_session.ip_hosts > host_session.ip_choice then -- Not our first attempt, and we also have IPs left to try
		s2sout.try_next_ip(host_session);
	else
		host_session.ip_hosts = nil;
		if not s2sout.attempt_connection(host_session, "out of IP addresses") then -- Retry if we can
			log("debug", "No other records to try for %s - destroying", host_session.to_host);
			err = err and (": "..err) or "";
			s2s_destroy_session(host_session, "Connecting failed"..err); -- End of the line, we can't
			return false;
		end
	end

	return true;
end

function s2sout.make_connect(host_session, connect_host, connect_port)
	(host_session.log or log)("info", "Beginning new connection attempt to %s ([%s]:%d)", host_session.to_host, connect_host.addr, connect_port);
	-- Ok, we're going to try to connect
	
	local from_host, to_host = host_session.from_host, host_session.to_host;

	local ssl_ctx;
	if host_session.direct_tls_s2s then
		local ctx, err = get_ssl_config(from_host, "client");
		if not ctx then
			return false, "Failed to get SSL config for Direct TLS S2S connection: "..err;
		end
		ssl_ctx = ctx;
	end
	
	local conn, handler;
	if connect_host.proto == "IPv4" then
		conn, handler = socket.tcp();
	else
		conn, handler = socket.tcp6();
	end
	
	if not conn then
		log("warn", "Failed to create outgoing connection, system error: %s", handler);
		return false, handler;
	end

	conn:settimeout(0);
	local success, err = conn:connect(connect_host.addr, connect_port);
	if not success and err ~= "timeout" then
		log("warn", "s2s connect() to %s (%s:%d) failed: %s", host_session.to_host, connect_host.addr, connect_port, err);
		return false, err;
	end
	
	conn = wrapclient(conn, connect_host.addr, connect_port, s2s_listener, "*a", ssl_ctx);
	host_session.conn = conn;
	
	local filter = initialize_filters(host_session);
	local w, log = conn.write, host_session.log;
	host_session.sends2s = function (t)
		log("debug", "sending: %s", (t.top_tag and t:top_tag()) or t:match("^[^>]*>?"));
		if t.name then
			t = filter("stanzas/out", t);
		end
		if t then
			t = filter("bytes/out", tostring(t));
			if t then
				return w(conn, tostring(t));
			end
		end
	end
	
	-- Register this outgoing connection so that xmppserver_listener knows about it
	-- otherwise it will assume it is a new incoming connection
	s2s_listener.register_outgoing(conn, host_session);
	
	log("debug", "Connection attempt in progress...");
	return true;
end

module:hook_global("service-added", function (event)
	if event.name ~= "s2s" then return end

	local s2s_sources = portmanager.get_active_services():get("s2s");
	if not s2s_sources then
		module:log("warn", "s2s not listening on any ports, outgoing connections may fail");
		return;
	end
	for source, _ in pairs(s2s_sources) do
		if source == "*" or source == "0.0.0.0" then
			if not socket.local_addresses then
				sources[#sources + 1] = new_ip("0.0.0.0", "IPv4");
			else
				for _, addr in ipairs(socket.local_addresses("ipv4", true)) do
					sources[#sources + 1] = new_ip(addr, "IPv4");
				end
			end
		elseif source == "::" then
			if not socket.local_addresses then
				sources[#sources + 1] = new_ip("::", "IPv6");
			else
				for _, addr in ipairs(socket.local_addresses("ipv6", true)) do
					sources[#sources + 1] = new_ip(addr, "IPv6");
				end
			end
		else
			sources[#sources + 1] = new_ip(source, (source:find(":") and "IPv6") or "IPv4");
		end
	end
	for i = 1,#sources do
		if sources[i].proto == "IPv6" then
			has_ipv6 = true;
		elseif sources[i].proto == "IPv4" then
			has_ipv4 = true;
		end
	end
end);

return s2sout;
