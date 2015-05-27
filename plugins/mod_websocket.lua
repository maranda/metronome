-- * Metronome IM *
--
-- This file is part of the Metronome XMPP server and is released under the
-- ISC License, please see the LICENSE file in this source package for more
-- information about copyright and licensing.
--
-- As per the sublicensing clause, this file is also MIT/X11 Licensed.
-- ** Copyright (c) 2012-2013, Florian Zeitz
--
-- This module is mainly a refactor and adaptation of the module available
-- from Prosody Modules (mod_websocket)

module:set_global();

local add_filter = require "util.filters".add_filter;
local sha1 = require "util.hashes".sha1;
local base64 = require "util.encodings".base64.encode;
local portmanager = require "core.portmanager";
local websocket = require "util.websocket";

local t_concat = table.concat;

local raw_log = module:get_option_boolean("websocket_no_raw_requests_logging", true) ~= true and true or nil;
local consider_secure = module:get_option_boolean("consider_websocket_secure");
local cross_domain = module:get_option("cross_domain_websocket");
if cross_domain then
	if cross_domain == true then
		cross_domain = "*";
	elseif type(cross_domain) == "table" then
		cross_domain = t_concat(cross_domain, ", ");
	end
	if type(cross_domain) ~= "string" then
		cross_domain = nil;
	end
end

module:depends("c2s")
local sessions = module:shared("c2s/sessions");
local c2s_listener = portmanager.get_service("c2s")[1].listener;

function handle_request(event, path)
	local request, response = event.request, event.response;
	local conn = response.conn;

	if not request.headers.sec_websocket_key then
		response.headers.content_type = "text/html";
		return [[<!DOCTYPE html><html><head><title>Metronome's WebSocket Interface</title></head><body>
			<p>It works! Now point your WebSocket client to this URL to connect to the XMPP server.</p>
			</body></html>]];
	end

	local wants_xmpp = false;
	(request.headers.sec_websocket_protocol or ""):gsub("([^,]*),?", function (proto)
		if proto == "xmpp" then wants_xmpp = true; end
	end);

	if not wants_xmpp then return 501; end

	conn:setlistener(c2s_listener);
	c2s_listener.onconnect(conn);

	local session = sessions[conn];
	local ws = websocket.new(conn, raw_log);

	session.secure = consider_secure or session.secure;
	session.ws_session = true;

	local buffer = "";
	add_filter(session, "bytes/in", function(data)
		local cache = {};
		buffer = buffer .. data;
		local frame, length = ws:parse(buffer);

		while frame do
			buffer = buffer:sub(length + 1);
			local result = ws:handle(frame);
			if not result then return; end
			cache[#cache+1] = result;
			frame, length = ws:parse(buffer);
		end
		return t_concat(cache, "");
	end);

	add_filter(session, "bytes/out", function(data)
		return ws:build({ FIN = true, opcode = 0x01, data = tostring(data)});
	end);

	response.status_code = 101;
	response.headers.upgrade = "websocket";
	response.headers.connection = "Upgrade";
	response.headers.sec_webSocket_accept = base64(sha1(request.headers.sec_websocket_key .. "258EAFA5-E914-47DA-95CA-C5AB0DC85B11"));
	response.headers.sec_webSocket_protocol = "xmpp";
	response.headers.access_control_allow_origin = cross_domain;

	return "";
end

function module.add_host(module)
	module:depends("http");
	module:provides("http", {
		name = "websocket";
		default_path = "xmpp-websocket";
		route = {
			["GET"] = handle_request;
			["GET /"] = handle_request;
		};
	});
end
