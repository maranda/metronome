-- * Metronome IM *
--
-- This file is part of the Metronome XMPP server and is released under the
-- ISC License, please see the LICENSE file in this source package for more
-- information about copyright and licensing.
--
-- As per the sublicensing clause, this file is also MIT/X11 Licensed.
-- ** Copyright (c) 2008-2013, Kim Alvefur, Matthew Wild, Paul Aurich, Waqas Hussain 

local configmanager = require "core.configmanager";
local modulemanager = require "core.modulemanager";
local events_new = require "util.events".new;
local mt_new = require "util.multitable".new;
local set_new = require "util.set".new;
local disco_items = mt_new();
local NULL = {};

local jid_section = require "util.jid".section;
local generate_secret = require "util.auxiliary".generate_secret;

local log = require "util.logger".init("hostmanager");

local hosts = hosts;
local metronome_events = metronome.events;
local fire_event = metronome_events.fire_event;

local pairs, tostring, type = pairs, tostring, type;

module "hostmanager"

local hosts_loaded_once;

local function load_enabled_hosts()
	local disabled = configmanager.get("*", "modules_disabled");
	if disabled then
		disabled = set_new(disabled);
		if disabled:contains("router") then
			log("warn", "You intentionally disabled core routing functions.");
			log("warn", "Be aware that if you don't have any replacement this will cause Metronome to NOT work correctly.");
		end
	end

	local defined_hosts = configmanager.getconfig();
	local activated_any_host;
	
	for host, host_config in pairs(defined_hosts) do
		if host ~= "*" and host_config.enabled ~= false then
			if not host_config.component_module then
				activated_any_host = true;
			end
			activate(host, host_config);
		end
	end
	
	if not activated_any_host then
		log("error", "No active VirtualHost entries in the config file. This may cause unexpected behaviour as no modules will be loaded.");
	end
	
	metronome_events.fire_event("hosts-activated", defined_hosts);
	hosts_loaded_once = true;
end

metronome_events.add_handler("server-starting", load_enabled_hosts);

local function rebuild_disco_data()
	disco_items = mt_new(); --reset
	for name in pairs(hosts) do
		local config = configmanager.getconfig()[name];
		if not name:match("[@/]") then
			disco_items:set(name:match("%.(.*)") or "*", name, config.name or true);
		end		
	end
end

metronome_events.add_handler("config-reloaded", rebuild_disco_data);

local function host_send(stanza)
	local name, type = stanza.name, stanza.attr.type;
	if type == "error" or (name == "iq" and type == "result") then
		local dest_host_name = jid_section(stanza.attr.to, "host");
		local dest_host = hosts[dest_host_name] or { type = "unknown" };
		log("warn", "Unhandled response sent to %s host %s: %s", dest_host.type, dest_host_name, tostring(stanza));
		return;
	end
	fire_event("route/local", nil, stanza);
end

function activate(host)
	if hosts[host] then return nil, "The host "..host.." is already activated"; end
	host_config = configmanager.getconfig()[host];
	local host_session = {
		host = host;
		s2sout = {};
		events = events_new();
		dialback_secret = configmanager.get(host, "dialback_secret") or generate_secret();
		send = host_send;
		modules = {};
	};
	if not host_session.dialback_secret then -- secret generation failed, out of file descriptors?
		return nil, "Failed to generate dialback secret for host "..host;
	end
	if not host_config.component_module then
		host_session.type = "local";
		host_session.sessions = {};
	else
		host_session.type = "component";
	end
	hosts[host] = host_session;
	if not host:match("[@/]") then
		disco_items:set(host:match("%.(.*)") or "*", host, host_config.name or true);
	end
	for option_name in pairs(host_config) do
		if option_name:match("_ports$") or option_name:match("_interface$") then
			log("warn", "%s: Option '%s' has no effect for virtual hosts - put it in the server-wide section instead", host, option_name);
		end
	end
	
	log((hosts_loaded_once and "info") or "debug", "Activated host: %s", host);
	metronome_events.fire_event("host-activated", host);
	return true;
end

function deactivate(host, reason)
	local host_session = hosts[host];
	if not host_session then return nil, "The host "..tostring(host).." is not activated"; end
	log("info", "Deactivating host: %s", host);
	if type(reason) ~= "table" then
		reason = { condition = "host-gone", text = tostring(reason or "This server has stopped serving "..host) };
	end
	metronome_events.fire_event("host-deactivating", { host = host, host_session = host_session, reason = reason });

	hosts[host] = nil;
	if not host:match("[@/]") then
		disco_items:remove(host:match("%.(.*)") or "*", host);
	end
	metronome_events.fire_event("host-deactivated", host);
	log("info", "Deactivated host: %s", host);
	return true;
end

function get_children(host)
	return disco_items:get(host) or NULL;
end

return _M;
