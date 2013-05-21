-- * Metronome IM *
--
-- This file is part of the Metronome XMPP server and is released under the
-- ISC License, please see the LICENSE file in this source package for more
-- information about copyright and licensing.
--
-- As per the sublicensing clause, this file is also MIT/X11 Licensed.
-- ** Copyright (c) 2009-2013, Kim Alvefur, Matthew Wild

local server;

server = require "net.server_event";

local ok, signal = pcall(require, "util.signal");
if ok and signal then
	local _signal_signal = signal.signal;
	function signal.signal(signal_id, handler)
		if type(signal_id) == "string" then
			signal_id = signal[signal_id:upper()];
		end
		if type(signal_id) ~= "number" then
			return false, "invalid-signal";
		end
		return server.hook_signal(signal_id, handler);
	end
end

if metronome then
	local config_get = require "core.configmanager".get;
	local defaults = {};
	for k,v in pairs(server.cfg or server.getsettings()) do
		defaults[k] = v;
	end
	local function load_config()
		local settings = config_get("*", "network_settings") or {};
		local event_settings = {
			ACCEPT_DELAY = settings.event_accept_retry_interval;
			ACCEPT_QUEUE = settings.tcp_backlog;
			CLEAR_DELAY = settings.event_clear_interval;
			CONNECT_TIMEOUT = settings.connect_timeout;
			DEBUG = settings.debug;
			HANDSHAKE_TIMEOUT = settings.ssl_handshake_timeout;
			MAX_CONNECTIONS = settings.max_connections;
			MAX_HANDSHAKE_ATTEMPTS = settings.max_ssl_handshake_roundtrips;
			MAX_READ_LENGTH = settings.max_receive_buffer_size;
			MAX_SEND_LENGTH = settings.max_send_buffer_size;
			READ_TIMEOUT = settings.read_timeout;
			WRITE_TIMEOUT = settings.send_timeout;
		};

		for k,default in pairs(defaults) do
			server.cfg[k] = event_settings[k] or default;
		end
	end
	load_config();
	metronome.events.add_handler("config-reloaded", load_config);
end

return server;
