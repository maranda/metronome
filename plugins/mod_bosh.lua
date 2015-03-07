-- * Metronome IM *
--
-- This file is part of the Metronome XMPP server and is released under the
-- ISC License, please see the LICENSE file in this source package for more
-- information about copyright and licensing.
--
-- As per the sublicensing clause, this file is also MIT/X11 Licensed.
-- ** Copyright (c) 2008-2013, Kim Alvefur, Matthew Wild, Waqas Hussain

module:set_global(); -- Global module

local hosts = _G.hosts;
local new_xmpp_stream = require "util.xmppstream".new;
local sm = require "core.sessionmanager";
local sm_destroy_session = sm.destroy_session;
local new_uuid = require "util.uuid".generate;
local fire_event = metronome.events.fire_event;
local st = require "util.stanza";
local logger = require "util.logger";
local log = logger.init("mod_bosh");
local math_min = math.min;

local initialize_filters = require "util.filters".initialize;

local xmlns_streams = "http://etherx.jabber.org/streams";
local xmlns_xmpp_streams = "urn:ietf:params:xml:ns:xmpp-streams";
local xmlns_bosh = "http://jabber.org/protocol/httpbind"; -- (hard-coded into a literal in session.send)

local stream_callbacks = { stream_ns = xmlns_bosh, stream_tag = "body", default_ns = "jabber:client" };

local BOSH_DEFAULT_HOLD = module:get_option_number("bosh_default_hold", 1);
local BOSH_DEFAULT_INACTIVITY = module:get_option_number("bosh_max_inactivity", 60);
local BOSH_DEFAULT_POLLING = module:get_option_number("bosh_max_polling", 5);
local BOSH_DEFAULT_REQUESTS = module:get_option_number("bosh_max_requests", 2);
local BOSH_MAX_WAIT = module:get_option_number("bosh_max_wait", 120);

local consider_bosh_secure = module:get_option_boolean("consider_bosh_secure");
local force_secure = module:get_option_boolean("force_https_bosh");
local no_raw_req_logging = module:get_option_boolean("bosh_no_raw_requests_logging", true);

local default_headers = { ["Content-Type"] = "text/xml; charset=utf-8" };

local cross_domain = module:get_option("cross_domain_bosh", false);
if cross_domain then
	default_headers["Access-Control-Allow-Methods"] = "GET, POST, OPTIONS";
	default_headers["Access-Control-Allow-Headers"] = "Content-Type";
	default_headers["Access-Control-Max-Age"] = "7200";

	if cross_domain == true then
		default_headers["Access-Control-Allow-Origin"] = "*";
	elseif type(cross_domain) == "table" then
		cross_domain = table.concat(cross_domain, ", ");
	end
	if type(cross_domain) == "string" then
		default_headers["Access-Control-Allow-Origin"] = cross_domain;
	end
end

local trusted_proxies = module:get_option_set("trusted_proxies", {"127.0.0.1"})._items;

local function get_ip_from_request(request)
	local ip = request.conn:ip();
	local forwarded_for = request.headers.x_forwarded_for;
	if forwarded_for then
		forwarded_for = forwarded_for..", "..ip;
		for forwarded_ip in forwarded_for:gmatch("[^%s,]+") do
			if not trusted_proxies[forwarded_ip] then
				ip = forwarded_ip;
			end
		end
	end
	return ip;
end

local t_insert, t_remove, t_concat = table.insert, table.remove, table.concat;
local os_time = os.time;
local ipairs, pairs, tonumber, tostring, type = ipairs, pairs, tonumber, tostring, type;
local clone_table = require "util.auxiliary".clone_table;
local json_encode = require "util.json".encode;
local url_decode = require "net.http".urldecode;

local sessions, inactive_sessions = module:shared("sessions", "inactive_sessions");
local waiting_requests = {};

local function jsonp_encode(callback, data)
	data = callback.."("..json_encode({ reply = data })..");";
	return data;		
end

local function on_destroy_request(request)
	log("debug", "Request destroyed: %s", tostring(request));
	waiting_requests[request] = nil;
	local session = sessions[request.context.sid];
	if session then
		local requests = session.requests;
		for i, r in ipairs(requests) do
			if r == request then
				t_remove(requests, i);
				break;
			end
		end
		
		local max_inactive = session.bosh_max_inactive;
		if max_inactive and #requests == 0 then
			inactive_sessions[session] = os_time() + max_inactive;
			(session.log or log)("debug", "BOSH session marked as inactive (for %ds)", max_inactive);
		end
	end
end

local function handle_OPTIONS(event)
	local request = event.request;
	if force_secure and not request.secure then return nil; end

	local headers = clone_table(default_headers);
	headers["Content-Type"] = nil;
	return { headers = headers, body = "" };
end

local function handle_POST(event)
	local request, response, custom_headers = event.request, event.response, event.custom_headers;
	if force_secure and not request.secure then
		log("debug", "Discarding unsecure request %s: %s\n----------", tostring(request), tostring(no_raw_req_logging and "<filtered>" or request.body));
		return nil;
	end

	log("debug", "Handling new request %s: %s\n----------", tostring(request), tostring(no_raw_req_logging and "<filtered>" or request.body));

	response.on_destroy = on_destroy_request;
	local body = request.body;

	local context = { request = request, response = response, custom_headers = custom_headers, notopen = true };
	local stream = new_xmpp_stream(context, stream_callbacks);
	response.context = context;
	if not stream:feed(body) then
		module:log("warn", "Couldn't parse the body of the request: %s", tostring(body));
		return 400;
	end

	local session = sessions[context.sid];
	if session then
		if inactive_sessions[session] and #session.requests > 0 then
			inactive_sessions[session] = nil;
		end

		local r = session.requests;
		log("debug", "Session %s has %d out of %d requests open", context.sid, #r, session.bosh_hold);
		log("debug", "and there are %d things in the send_buffer:", #session.send_buffer);
		if #r > session.bosh_hold then
			log("debug", "We are holding too many requests, so...");
			if #session.send_buffer > 0 then
				log("debug", "...sending what is in the buffer")
				session.send(t_concat(session.send_buffer));
				session.send_buffer = {};
			else
				log("debug", "...sending an empty response");
				session.send("");
			end
		elseif #session.send_buffer > 0 then
			log("debug", "Session has data in the send buffer, will send now..");
			local resp = t_concat(session.send_buffer);
			session.send_buffer = {};
			session.send(resp);
		end
		
		if not response.finished then
			log("debug", "Have nothing to say, so leaving request unanswered for now");
			if session.bosh_wait then
				waiting_requests[response] = os_time() + session.bosh_wait;
			end
		end
		
		if session.bosh_terminate then
			session.log("debug", "Closing session with %d requests open", #session.requests);
			session.dead = true;
			session:close();
			return nil;
		else
			return true; -- Inform http server we shall reply later
		end
	end

	module:log("warn", "The request isn't associated with a session.");
	return 400;
end

local function bosh_reset_stream(session) session.notopen = true; end

local stream_xmlns_attr = { xmlns = xmlns_xmpp_streams };

local function bosh_close_stream(session, reason)
	(session.log or log)("info", "BOSH client disconnected");
	
	local close_reply = st.stanza("body", { xmlns = xmlns_bosh, type = "terminate",
		["xmlns:stream"] = xmlns_streams });
	
	if reason then
		close_reply.attr.condition = "remote-stream-error";
		if type(reason) == "string" then
			close_reply:tag("stream:error")
				:tag(reason, {xmlns = xmlns_xmpp_streams});
		elseif type(reason) == "table" then
			if reason.condition then
				close_reply:tag("stream:error")
					:tag(reason.condition, stream_xmlns_attr):up();
				if reason.text then
					close_reply:tag("text", stream_xmlns_attr):text(reason.text):up();
				end
				if reason.extra then
					close_reply:add_child(reason.extra);
				end
			elseif reason.name then
				close_reply = reason;
			end
		end
		log("info", "Disconnecting client, <stream:error> is: %s", tostring(close_reply));
	end

	local response_body = tostring(close_reply);
	for _, held_request in ipairs(session.requests) do
		held_request.headers = session.headers or default_headers;
		held_request:send(response_body);
	end
	sessions[session.sid]  = nil;
	inactive_sessions[session] = nil;
	sm_destroy_session(session);
end

function stream_callbacks.streamopened(context, attr)
	local request, response, custom_headers = context.request, context.response, context.custom_headers;
	local sid = attr.sid;
	log("debug", "BOSH body open (sid: %s)", sid or "<none>");
	if not sid then
		context.notopen = nil; -- Signals that we accept this opening tag
		
		if not hosts[attr.to] then
			log("debug", "BOSH client tried to connect to unknown host: %s", tostring(attr.to));
			response:send(tostring(st.stanza("body", { xmlns = xmlns_bosh, type = "terminate",
				["xmlns:stream"] = xmlns_streams, condition = "host-unknown" })));
			return;
		elseif hosts[attr.to].type == "component" then
			log("debug", "BOSH client tried to connect to a component host: %s", tostring(attr.to));
			local reply = st.stanza("body", { xmlns = xmlns_bosh, type = "terminate",
				["xmlns:stream"] = xmlns_streams, condition = "remote-stream-error" })
					:tag("stream:error")
						:tag("not-allowed", stream_xmlns_attr):up()
						:tag("text", stream_xmlns_attr):text("This entity doesn't offer BOSH client streams"):up():up();
			response:send(tostring(reply));
			return;
		end
		
		sid = new_uuid();
		local session = {
			type = "c2s_unauthed", conn = {}, sid = sid, rid = tonumber(attr.rid)-1, host = attr.to,
			bosh_version = attr.ver, bosh_wait = math_min(attr.wait, BOSH_MAX_WAIT), streamid = sid,
			bosh_hold = BOSH_DEFAULT_HOLD, bosh_max_inactive = BOSH_DEFAULT_INACTIVITY, requests = {},
			send_buffer = {}, reset_stream = bosh_reset_stream, close = bosh_close_stream,
			dispatch_stanza = stream_callbacks.handlestanza, notopen = true, log = logger.init("bosh"..sid),
			secure = consider_bosh_secure or request.secure, ip = get_ip_from_request(request),
			headers = custom_headers;
		};
		sessions[sid] = session;

		local filter = initialize_filters(session);
		
		session.log("debug", "BOSH session created for request from %s", session.ip);
		log("info", "New BOSH session, assigned it sid '%s'", sid);

		local creating_session = true;

		local attach = context.attach;
		local r = session.requests;
		function session.send(s)
			if s.attr and not s.attr.xmlns then
				s = st.clone(s);
				s.attr.xmlns = "jabber:client";
			end
			s = filter("stanzas/out", s);
			t_insert(session.send_buffer, tostring(s));

			local oldest_request = r[1];
			if oldest_request and not session.bosh_processing then
				log("debug", "We have an open request, so sending on that");
				oldest_request.headers = session.headers or default_headers;
				local body_attr = { xmlns = "http://jabber.org/protocol/httpbind",
					["xmlns:stream"] = "http://etherx.jabber.org/streams";
					type = session.bosh_terminate and "terminate" or nil;
					sid = sid;
				};
				if creating_session then
					body_attr.wait = tostring(session.bosh_wait);
					body_attr.inactivity = tostring(BOSH_DEFAULT_INACTIVITY);
					body_attr.polling = tostring(BOSH_DEFAULT_POLLING);
					body_attr.requests = tostring(BOSH_DEFAULT_REQUESTS);
					body_attr.hold = tostring(session.bosh_hold);
					body_attr.authid = sid;
					body_attr.secure = "true";
					body_attr.ver = '1.6'; 
					body_attr.from = session.host;
					body_attr["xmlns:xmpp"] = "urn:xmpp:xbosh";
					body_attr["xmpp:version"] = "1.0";
					creating_session = nil;
				end
				if not attach then
					oldest_request:send(st.stanza("body", body_attr):top_tag()..t_concat(session.send_buffer).."</body>");
				else
					attach = nil;
					t_remove(r, 1);
					oldest_request = nil;
				end
				session.send_buffer = {};
			end
			return true;
		end
		request.sid = sid;
	end
	
	local session = sessions[sid];
	if not session then
		log("info", "Client tried to use sid '%s' which we don't know about", sid);
		response.headers = custom_headers or default_headers;
		response:send(tostring(st.stanza("body", { xmlns = xmlns_bosh, type = "terminate", condition = "item-not-found" })));
		context.notopen = nil;
		return;
	end
	
	if session.rid then
		local rid = tonumber(attr.rid);
		local diff = rid - session.rid;
		if diff > 1 then
			session.log("warn", "rid too large (means a request was lost). Last rid: %d New rid: %s", session.rid, attr.rid);
		elseif diff <= 0 then
			session.log("debug", "rid repeated (on request %s), ignoring: %d (diff %d)", tostring(request), session.rid, diff);
			context.notopen = nil;
			context.ignore = true;
			context.sid = sid;
			t_insert(session.requests, response);
			return;
		end
		session.rid = rid;
	end
	
	if attr.type == "terminate" then
		session.bosh_terminate = true;
	end

	context.notopen = nil;
	t_insert(session.requests, response);
	context.sid = sid;
	session.bosh_processing = true; -- Used to suppress requests until processing is done

	if session.notopen then
		local features = st.stanza("stream:features");
		hosts[session.host].events.fire_event("stream-features", { origin = session, features = features });
		fire_event("stream-features", session, features);
		table.insert(session.send_buffer, tostring(features));
		session.notopen = nil;
	end
end

function stream_callbacks.handlestanza(context, stanza)
	if context.ignore then return; end
	log("debug", "BOSH stanza received: %s\n", stanza:top_tag());
	local session = sessions[context.sid];
	if session or context.dead then
		if stanza.attr.xmlns == xmlns_bosh then -- Clients not qualifying stanzas should be whipped..
			stanza.attr.xmlns = nil;
			if stanza.name == "message" then
				local body = stanza:child_with_name("body");
				if body then body.attr.xmlns = nil; end
			end
		end
		stanza = (session or context).filter("stanzas/in", stanza);
		if stanza then fire_event("route/process", (session or context), stanza); end
	end
end

function stream_callbacks.streamclosed(request)
	local session = sessions[request.sid];
	if session then
		session.bosh_processing = false;
		if #session.send_buffer > 0 then
			session.send("");
		end
	end
end

function stream_callbacks.error(context, error)
	log("debug", "Error parsing BOSH request payload; %s", error);
	if not context.sid then
		local response = context.response;
		response.headers = context.custom_headers or default_headers;
		response.status_code = 400;
		response:send();
		return;
	end
	
	local session = sessions[context.sid];
	if error == "stream-error" then
		session:close();
	else
		session:close({ condition = "bad-format", text = "Error processing stream" });
	end
end

local dead_sessions = {};
local function on_timer()
	local now = os_time() + 3;
	for request, reply_before in pairs(waiting_requests) do
		if reply_before <= now then
			log("debug", "%s was soon to timeout (at %d, now %d), sending empty response", tostring(request), reply_before, now);
			if request.conn then
				sessions[request.context.sid].send("");
			end
		end
	end
	
	now = now - 3;
	local n_dead_sessions = 0;
	for session, close_after in pairs(inactive_sessions) do
		if close_after < now then
			(session.log or log)("debug", "BOSH client inactive too long, destroying session at %d", now);
			sessions[session.sid]  = nil;
			inactive_sessions[session] = nil;
			n_dead_sessions = n_dead_sessions + 1;
			dead_sessions[n_dead_sessions] = session;
		end
	end

	for i=1,n_dead_sessions do
		local session = dead_sessions[i];
		dead_sessions[i] = nil;
		session.dead = true;
		sm_destroy_session(session, "BOSH client silent for over "..session.bosh_max_inactive.." seconds");
	end
	return 1;
end
module:add_timer(1, on_timer);

local function handle_GET(event)
	local request, response = event.request, event.response;
	if force_secure and not request.secure then return nil; end

	local query = request.url.query;
	local callback, data;
	if cross_domain and query then
		if query:match("=") then
			local params = {};
			for key, value in query:gmatch("&?([^=%?]+)=([^&%?]+)&?") do
				if key and value then
					params[url_decode(key)] = url_decode(value);
				end
			end
			callback, data = params.callback, params.data;
		else
			callback, data = "_BOSH_", url_decode(query);
		end
	end

	if callback and data then
		local _send = response.send;
		local custom_headers = clone_table(default_headers);
		custom_headers["Content-Type"] = "application/javascript; charset=utf-8";

		function response:send(data)
			return _send(self, jsonp_encode(callback, data));
		end

		request.method = "POST";
		request.body = data;
		event.custom_headers = custom_headers;
		return handle_POST(event);
	end	

	response.headers = { ["Content-Type"] = "text/html; charset=utf-8" };
	response.body =
		[[<!DOCTYPE html><html><head><title>Metronome's BOSH Interface</title></head><body>
		<p>It works! Now point your BOSH client to this URL to connect to the XMPP Server.</p>
		</body></html>]];
	return response:send();
end

function module.add_host(module)
	module:depends("http");
	module:provides("http", {
		default_path = "/http-bind";
		route = {
			["GET"] = handle_GET;
			["GET /"] = handle_GET;
			["OPTIONS"] = handle_OPTIONS;
			["OPTIONS /"] = handle_OPTIONS;
			["POST"] = handle_POST;
			["POST /"] = handle_POST;
		};
	});
end

-- Export a few functions in the environment
module.environment.utils = { 
	stream_callbacks = stream_callbacks, get = handle_GET, options = handle_OPTIONS, post = handle_POST
};
