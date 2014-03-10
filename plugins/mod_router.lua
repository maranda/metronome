-- * Metronome IM *
--
-- This file is part of the Metronome XMPP server and is released under the
-- ISC License, please see the LICENSE file in this source package for more
-- information about copyright and licensing.

module:set_global();

local hosts = metronome.hosts;
local tostring = tostring;
local st = require "util.stanza";
local jid_section = require "util.jid".section;
local jid_split = require "util.jid".split;
local jid_prepped_split = require "util.jid".prepped_split;

local full_sessions = metronome.full_sessions;
local bare_sessions = metronome.bare_sessions;

local log = module._log;
local fire_event = metronome.events.fire_event;

local function handle_unhandled_stanza(host, origin, stanza)
	local name, xmlns, origin_type = stanza.name, stanza.attr.xmlns or "jabber:client", origin.type;
	if name == "iq" and xmlns == "jabber:client" then
		if stanza.attr.type == "get" or stanza.attr.type == "set" then
			xmlns = stanza.tags[1].attr.xmlns or "jabber:client";
			module:log("debug", "Stanza of type %s from %s has xmlns: %s", name, origin_type, xmlns);
		else
			module:log("debug", "Discarding %s from %s of type: %s", name, origin_type, stanza.attr.type);
			return true;
		end
	end
	if stanza.attr.xmlns == nil and origin.send then
		module:log("debug", "Unhandled %s stanza: %s; xmlns=%s", origin.type, stanza.name, xmlns);
		if stanza.attr.type ~= "error" and stanza.attr.type ~= "result" then
			origin.send(st.error_reply(stanza, "cancel", "service-unavailable"));
		end
	elseif not((name == "features" or name == "error") and xmlns == "http://etherx.jabber.org/streams") then
		module:log("warn", "Unhandled %s stream element or stanza: %s; xmlns=%s: %s", origin.type, stanza.name, xmlns, tostring(stanza));
		origin:close("unsupported-stanza-type");
	end
end

local iq_types = { set=true, get=true, result=true, error=true };
local function process_stanza(origin, stanza)
	local type = origin.type;
	(origin.log or log)("debug", "Received[%s]: %s", type, 
		((type == "s2sin_unauthed" or type == "s2sout_unauthed") and tostring(stanza)) or stanza:top_tag());

	-- TODO verify validity of stanza (as well as JID validity)
	if stanza.attr.type == "error" and #stanza.tags == 0 then
		module:log("warn", "Invalid stanza received: %s", tostring(stanza));
		return;
	end
	if stanza.name == "iq" then
		if not stanza.attr.id then stanza.attr.id = ""; end
		if not iq_types[stanza.attr.type] or ((stanza.attr.type == "set" or stanza.attr.type == "get") and (#stanza.tags ~= 1)) then
			origin.send(st.error_reply(stanza, "modify", "bad-request", "Invalid IQ type or incorrect number of children"));
			return;
		end
	end

	if type == "c2s" and not stanza.attr.xmlns then
		if not origin.full_jid
			and not(stanza.name == "iq" and stanza.attr.type == "set" and stanza.tags[1] and stanza.tags[1].name == "bind"
					and stanza.tags[1].attr.xmlns == "urn:ietf:params:xml:ns:xmpp-bind") then
			if stanza.attr.type ~= "result" and stanza.attr.type ~= "error" then
				origin.send(st.error_reply(stanza, "auth", "not-authorized"));
			end
			return;
		end

		-- TODO also, stanzas should be returned to their original state before the function ends
		stanza.attr.from = origin.full_jid;
	end
	local to, xmlns = stanza.attr.to, stanza.attr.xmlns;
	local from = stanza.attr.from;
	local node, host, resource;
	local from_node, from_host, from_resource;
	local to_bare, from_bare;
	if to then
		if full_sessions[to] or bare_sessions[to] or hosts[to] then
			host = jid_section(to, "host");
		else
			node, host, resource = jid_prepped_split(to);
			if not host then
				module:log("warn", "Received stanza with invalid destination JID: %s", to);
				if stanza.attr.type ~= "error" and stanza.attr.type ~= "result" then
					origin.send(st.error_reply(stanza, "modify", "jid-malformed", "The destination address is invalid: "..to));
				end
				return;
			end
			to_bare = node and (node.."@"..host) or host;
			if resource then to = to_bare.."/"..resource; else to = to_bare; end
			stanza.attr.to = to;
		end
	end
	if from and not origin.full_jid then
		from_node, from_host, from_resource = jid_prepped_split(from);
		if not from_host then
			module:log("warn", "Received stanza with invalid source JID: %s", from);
			if stanza.attr.type ~= "error" and stanza.attr.type ~= "result" then
				origin.send(st.error_reply(stanza, "modify", "jid-malformed", "The source address is invalid: "..from));
			end
			return;
		end
		from_bare = from_node and (from_node.."@"..from_host) or from_host;
		if from_resource then from = from_bare.."/"..from_resource; else from = from_bare; end
		stanza.attr.from = from;
	end

	local incoming_bidi = origin.incoming_bidi;
	if (type == "s2sin" or (type == "s2sout" and incoming_bidi) or type == "c2s" or type == "component") and xmlns == nil then
		if (type == "s2sin" or type == "s2sout") and not origin.dummy then
			local _hosts = (incoming_bidi and incoming_bidi.hosts) or origin.hosts;
			local host_status = _hosts[from_host];

			if not host_status or not host_status.authed then
				module:log("warn", "Received a stanza claiming to be from %s, over a stream authed for %s!", from_host, origin.from_host);
				origin:close("not-authorized");
				return;
			elseif not hosts[host] then
				module:log("warn", "Remote server %s sent us a stanza for %s, closing stream", origin.from_host, host);
				origin:close("host-unknown");
				return;
			end
		end
		fire_event("route/post", origin, stanza, origin.full_jid);
	else
		local h = hosts[stanza.attr.to or origin.host or origin.to_host or (origin.incoming_bidi and host)];
		if h then
			local event;
			if xmlns == nil then
				if stanza.name == "iq" and (stanza.attr.type == "set" or stanza.attr.type == "get") then
					event = "stanza/iq/"..stanza.tags[1].attr.xmlns..":"..stanza.tags[1].name;
				else
					event = "stanza/"..stanza.name;
				end
			else
				event = "stanza/"..xmlns..":"..stanza.name;
			end
			if h.events.fire_event(event, {origin = origin, stanza = stanza}) then return; end
		end
		if host and not hosts[host] then host = nil; end
		handle_unhandled_stanza(host or origin.host or origin.to_host, origin, stanza);
	end
end

local function post_stanza(origin, stanza, preevents)
	local to = stanza.attr.to;
	local node, host, resource = jid_split(to);
	local to_bare = node and (node.."@"..host) or host;

	local to_type, to_self;
	if node then
		if resource then
			to_type = '/full';
		else
			to_type = '/bare';
			if node == origin.username and host == origin.host then
				stanza.attr.to = nil;
				to_self = true;
			end
		end
	else
		if host then
			to_type = '/host';
		else
			to_type = '/bare';
			to_self = true;
		end
	end

	local event_data = {origin=origin, stanza=stanza};
	if preevents then
		if hosts[origin.host].events.fire_event('pre-'..stanza.name..to_type, event_data) then return; end
	end
	local h = hosts[to_bare] or hosts[host or origin.host];
	if h then
		if h.events.fire_event(stanza.name..to_type, event_data) then return; end
		if to_self and h.events.fire_event(stanza.name..'/self', event_data) then return; end
		handle_unhandled_stanza(h.host, origin, stanza);
	else
		fire_event("route/local", origin, stanza);
	end
end

local function route_stanza(origin, stanza)
	local node, host, resource = jid_split(stanza.attr.to);
	local from_node, from_host, from_resource = jid_split(stanza.attr.from);

	origin = origin or hosts[from_host];
	if not origin then return false; end
	
	if hosts[host] then
		fire_event("route/post", origin, stanza);
	else
		log("debug", "Routing to remote...");
		local host_session = hosts[from_host];
		if not host_session then
			module:log("error", "No hosts[from_host] (please report): %s", tostring(stanza));
		else
			local xmlns = stanza.attr.xmlns;
			stanza.attr.xmlns = nil;
			local routed = host_session.events.fire_event("route/remote", { origin = origin, stanza = stanza, from_host = from_host, to_host = host });
			stanza.attr.xmlns = xmlns; -- reset
			if not routed then
				module:log("debug", "... or not.");
				if stanza.attr.type == "error" or (stanza.name == "iq" and stanza.attr.type == "result") then return; end
				fire_event("route/local", host_session, st.error_reply(stanza, "cancel", "not-allowed", "Communication with remote domains is not enabled"));
			end
		end
	end
end

module:hook("route/process", process_stanza, -1);
module:hook("route/post", post_stanza, -1);
module:hook("route/local", route_stanza, -1);
