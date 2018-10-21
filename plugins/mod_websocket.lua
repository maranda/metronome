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
local sm_destroy_session = require "core.sessionmanager".destroy_session;
local websocket = require "util.websocket";
local st = require "util.stanza";

local httpserver_sessions = require "net.http.server".sessions;

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

local xmlns_framing = "urn:ietf:params:xml:ns:xmpp-framing";
local xmlns_streams = "http://etherx.jabber.org/streams";
local xmlns_client = "jabber:client";
local stream_xmlns_attr = { xmlns='urn:ietf:params:xml:ns:xmpp-streams' };

local function open(session)
	local attr = {
		xmlns = xmlns_framing, ["xml:lang"] = "en",
		version = "1.0", id = session.streamid or "",
		from = session.host
	};

	session.send(st.stanza("open", attr));
end

local function close(session, reason) -- Basically duplicated from mod_c2s, should be fixed.
	local log = session.log or log;
	if session.conn then
		local ws = session.ws;
		if session.notopen then session:open_stream(); end
		if reason then
			local stanza = st.stanza("stream:error");
			if type(reason) == "string" then
				stanza:tag(reason, {xmlns = "urn:ietf:params:xml:ns:xmpp-streams" });
			elseif type(reason) == "table" then
				if reason.condition then
					stanza:tag(reason.condition, stream_xmlns_attr):up();
					if reason.text then
						stanza:tag("text", stream_xmlns_attr):text(reason.text):up();
					end
					if reason.extra then
						stanza:add_child(reason.extra);
					end
				elseif reason.name then
					stanza = reason;
				end
			end
			log("debug", "Disconnecting client, <stream:error> is: %s", tostring(stanza));
			session.send(stanza);
		end

		session.send(st.stanza("close", { xmlns = xmlns_framing }));
		function session.send() return false; end

		local reason = (reason and (reason.text or reason.condition)) or reason;
		session.log("info", "c2s stream for %s closed: %s", session.full_jid or "<"..tostring(session.ip)..">", reason or "session closed");

		if reason == nil and not session.notopen and session.type == "c2s" then
			add_task(stream_close_timeout, function ()
				if not session.destroyed then
					session.log("warn", "Failed to receive a stream close response, closing connection anyway...");
					sm_destroy_session(session, reason);
					ws:close(1000, "Stream closed");
				end
			end);
		else
			local conn = session.conn;
			sm_destroy_session(session, reason);
			ws:close(1000, "Stream closed");
		end
	end
end

local function filter_stream_tag(result)
	if result:find(xmlns_framing, 1, true) then
		if result:find("<open", 1, true) then
			local to = result:match(".*%sto=[\'\"]([%w%p]+)[\'\"]");
			local version = result:match(".*%sto=[\'\"]([%w%p]+)[\'\"]");
			local lang = result:match(".*%sxml:lang=[\'\"]([%w%p]+)[\'\"]");
			if to then
				return st.stanza("stream:stream", {
					["xmlns:stream"] = xmlns_streams, to = to, version = version, lang = lang
				}):top_tag();
			end
		elseif result:find("<close", 1, true) then
			return "</stream:stream>";
		end
	end
	return result;
end

local function handle_request(event, path)
	local request, response = event.request, event.response;
	local conn = response.conn;

	if not request.headers.sec_websocket_key then
		response.headers.content_type = "text/html; charset=utf-8";
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
	session.ws = ws;
	session.ws_session = true;
	
	session.open_stream = open;
	session.close = close;

	local buffer = "";
	add_filter(session, "bytes/in", function(data)
		local cache = {};
		buffer = buffer .. data;
		local frame, length = ws:parse(buffer);

		while frame do
			buffer = buffer:sub(length + 1);
			local result = ws:handle(frame);
			if not result then return; end
			cache[#cache + 1] = filter_stream_tag(result);
			frame, length = ws:parse(buffer);
		end
		return t_concat(cache, "");
	end);

	add_filter(session, "stanzas/out", function(stanza)
		local attr = stanza.attr;
		attr.xmlns = attr.xmlns or xmlns_client;
		if stanza.name:find("^stream:") then attr["xmlns:stream"] = attr["xmlns:stream"] or xmlns_streams; end
		return stanza;
	end, -100);

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
		name = "websocket",
		default_path = "xmpp-websocket",
		route = {
			["GET"] = handle_request,
			["GET /"] = handle_request
		}
	});
end

module:hook("c2s-destroyed", function(event)
	local conn = event.conn;
	if httpserver_sessions[conn] then httpserver_sessions[conn] = nil; end
end);
