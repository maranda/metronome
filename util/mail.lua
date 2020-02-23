-- * Metronome IM *
--
-- This file is part of the Metronome XMPP server and is released under the
-- ISC License, please see the LICENSE file in this source package for more
-- information about copyright and licensing.

local ssl = require "ssl";
local socket = require "socket";
local smtp = require "socket.smtp";

if not (ssl or smtp) then error("Either Luasocket or Luasec aren't installed, aborting load", 0); end

local version = ssl and ssl._VERSION:match("^%d+%.(%d+)");
version = tonumber(version);

local function do_ssl()
    local s = socket.tcp();
    return setmetatable({
        connect = function(_, host, port)
		local r, e = s:connect(host, port);
			if not r then
				s:close();
				return r, e;
			end
			s = ssl.wrap(s, { mode = "client", protocol = version > 5 and "any" or "sslv23" });
			return s:dohandshake();
		end
    }, {
		__index = function(t,n)
			return function(_, ...)
				return s[n](s, ...);
			end
		end
	});
end

local function send(from, to, reply_to, subject, body, server, secure)
	local msg = {
		headers = {
			["Content-Type"] = "text/html; charset=UTF-8",
			["from"] = from,
			["to"] = to,
			["reply-to"] = reply_to,
			["subject"] = subject
		},
		body = body
	};

	local mail = {
		from = from,
		rcpt = to,
		source = smtp.message(msg),
		user = type(server) == "table" and server.user or nil,
		password = type(server) == "table" and server.password or nil,
		domain = type(server) == "table" and server.helo or nil,
		server = (type(server) == "string" and server) or (type(server) == "table" and server.host) or nil,
		port = type(server) == "table" and server.port or (secure and 465 or 25),
		create = secure and do_ssl or nil
	};

	if not mail.server then return nil, "No mail host specified"; end

	local ok, err = smtp.send(mail);
    if not ok then return ok, err; end

	return true;
end

return { send = send };
