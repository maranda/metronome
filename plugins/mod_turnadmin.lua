-- * Metronome IM *
--
-- This file is part of the Metronome XMPP server and is released under the
-- ISC License, please see the LICENSE file in this source package for more
-- information about copyright and licensing.
--
-- WARNING: for this plugin to work the password of the user has to be passed 
-- to turnadmin before it's actually hashed by the registration backend!!
-- Be certain about the system security before its usage.

local exec = os.execute;

local pre_cmd = module:get_option_string("turnadmin_pre_cmd", "");
local db_path = module:get_option_string("turnadmin_sqlite_db", "/var/db/turndb");

if pre_cmd ~= "" then pre_cmd = pre_cmd .. " "; end

module:hook("user-registration-verified", function(event)
	local user, host, pass = event.username, event.host, event.password;
	module:log("debug", "adding turn server long time credentials for %s", user.."@"..host);
	exec(pre_cmd .. "turnadmin -a -b " .. db_path .. " -u " .. user .. " -r " .. host .. " -p " .. pass .. " &");
end);

module:hook("user-changed-password", function(event)
	local user, host, pass = event.username, event.host, event.password;
	module:log("debug", "updating turn server long time credentials for %s", user.."@"..host);
	exec(pre_cmd .. "turnadmin -a -b " .. db_path .. " -u " .. user .. " -r " .. host .. " -p " .. pass .. " &");
end);

module:hook_global("user-deleted", function(event)
	local user, host = event.username, event.host;
	if host == module.host then
		module:log("debug", "deleting turn server long time credentials for %s", user.."@"..host);
		exec(pre_cmd .. "turnadmin -d -b " .. db_path .. " -u " .. user .. " -r " .. host .. " &");
	end
end, 150);
