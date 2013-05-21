-- * Metronome IM *
--
-- This file is part of the Metronome XMPP server and is released under the
-- ISC License, please see the LICENSE file in this source package for more
-- information about copyright and licensing.
--
-- As per the sublicensing clause, this file is also MIT/X11 Licensed.
-- ** Copyright (c) 2009-2013, Brian Cully, Kim Alvefur, Matthew Wild, Tobias Markmann, Waqas Hussain

local want_pposix_version = "0.3.5";

local pposix = assert(require "util.pposix");
if pposix._VERSION ~= want_pposix_version then module:log("warn", "Unknown version (%s) of binary pposix module, expected %s", tostring(pposix._VERSION), want_pposix_version); end

local signal = select(2, pcall(require, "util.signal"));
if type(signal) == "string" then
	module:log("warn", "Couldn't load signal library, won't respond to SIGTERM");
end

local lfs = require "lfs";
local stat = lfs.attributes;

local metronome = _G.metronome;

module:set_global();

local umask = module:get_option("umask") or "027";
pposix.umask(umask);

-- Allow switching away from root, some people like strange ports.
module:hook("server-started", function ()
		local uid = module:get_option("setuid");
		local gid = module:get_option("setgid");
		if gid then
			local success, msg = pposix.setgid(gid);
			if success then
				module:log("debug", "Changed group to %s successfully.", gid);
			else
				module:log("error", "Failed to change group to %s. Error: %s", gid, msg);
				metronome.shutdown("Failed to change group to %s", gid);
			end
		end
		if uid then
			local success, msg = pposix.setuid(uid);
			if success then
				module:log("debug", "Changed user to %s successfully.", uid);
			else
				module:log("error", "Failed to change user to %s. Error: %s", uid, msg);
				metronome.shutdown("Failed to change user to %s", uid);
			end
		end
	end);

-- Don't even think about it!
if not metronome.start_time then -- server-starting
	local suid = module:get_option("setuid");
	if not suid or suid == 0 or suid == "root" then
		if pposix.getuid() == 0 and not module:get_option("run_as_root") then
			module:log("error", "Danger, Will Robinson! Metronome doesn't need to be run as root, so don't do it!");
			metronome.shutdown("Refusing to run as root");
		end
	end
end

local pidfile;
local pidfile_handle;

local function remove_pidfile()
	if pidfile_handle then
		pidfile_handle:close();
		os.remove(pidfile);
		pidfile, pidfile_handle = nil, nil;
	end
end

local function write_pidfile()
	if pidfile_handle then
		remove_pidfile();
	end
	pidfile = module:get_option("pidfile");
	if pidfile then
		local err;
		local mode = stat(pidfile) and "r+" or "w+";
		pidfile_handle, err = io.open(pidfile, mode);
		if not pidfile_handle then
			module:log("error", "Couldn't write pidfile at %s; %s", pidfile, err);
			metronome.shutdown("Couldn't write pidfile");
		else
			if not lfs.lock(pidfile_handle, "w") then -- Exclusive lock
				local other_pid = pidfile_handle:read("*a");
				module:log("error", "Another Metronome instance seems to be running with PID %s, quitting", other_pid);
				pidfile_handle = nil;
				metronome.shutdown("Metronome already running");
			else
				pidfile_handle:close();
				pidfile_handle, err = io.open(pidfile, "w+");
				if not pidfile_handle then
					module:log("error", "Couldn't write pidfile at %s; %s", pidfile, err);
					metronome.shutdown("Couldn't write pidfile");
				else
					if lfs.lock(pidfile_handle, "w") then
						pidfile_handle:write(tostring(pposix.getpid()));
						pidfile_handle:flush();
					end
				end
			end
		end
	end
end

local syslog_opened;
function syslog_sink_maker(config)
	if not syslog_opened then
		pposix.syslog_open("metronome", module:get_option_string("syslog_facility"));
		syslog_opened = true;
	end
	local syslog, format = pposix.syslog_log, string.format;
	return function (name, level, message, ...)
		if ... then
			syslog(level, format(message, ...));
		else
			syslog(level, message);
		end
	end;
end
require "core.loggingmanager".register_sink_type("syslog", syslog_sink_maker);

local daemonize = module:get_option("daemonize");
if daemonize == nil then
	local no_daemonize = module:get_option("no_daemonize"); --COMPAT w/ 0.5
	daemonize = not no_daemonize;
	if no_daemonize ~= nil then
		module:log("warn", "The 'no_daemonize' option is now replaced by 'daemonize'");
		module:log("warn", "Update your config from 'no_daemonize = %s' to 'daemonize = %s'", tostring(no_daemonize), tostring(daemonize));
	end
end

if daemonize then
	local function daemonize_server()
		local ok, ret = pposix.daemonize();
		if not ok then
			module:log("error", "Failed to daemonize: %s", ret);
		elseif ret and ret > 0 then
			os.exit(0);
		else
			module:log("info", "Successfully daemonized to PID %d", pposix.getpid());
			write_pidfile();
		end
	end
	if not metronome.start_time then -- server-starting
		daemonize_server();
	end
else
	-- Not going to daemonize, so write the pid of this process
	write_pidfile();
end

module:hook("server-stopped", remove_pidfile);

-- Set signal handlers
if signal.signal then
	signal.signal("SIGTERM", function ()
		module:log("warn", "Received SIGTERM");
		metronome.unlock_globals();
		metronome.shutdown("Received SIGTERM");
		metronome.lock_globals();
	end);

	signal.signal("SIGHUP", function ()
		module:log("info", "Received SIGHUP");
		metronome.reload_config();
		metronome.reopen_logfiles();
	end);
	
	signal.signal("SIGINT", function ()
		module:log("info", "Received SIGINT");
		metronome.unlock_globals();
		metronome.shutdown("Received SIGINT");
		metronome.lock_globals();
	end);
end
