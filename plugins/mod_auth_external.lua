-- * Metronome IM *
--
-- This file is part of the Metronome XMPP server and is released under the
-- ISC License, please see the LICENSE file in this source package for more
-- information about copyright and licensing.
--
-- As per the sublicensing clause, this file is also MIT/X11 Licensed.
-- ** Copyright (c) 2010-2013, Waqas Hussain, Jeff Mitchell, Mikael Nordfeldth, Matthew Wild

-- This is a simple backport of Prosody Modules' mod_auth_external

local lpty = assert(require "lpty", "mod_auth_external requires lpty: http://tset.de/lpty/index.html");
local usermanager = require "core.usermanager";
local new_sasl = require "util.sasl".new;
local server = require "net.server";
local have_async, async = pcall(require, "util.async");

local log = module._log;
local host = module.host;

local script_type = module:get_option_string("external_auth_protocol", "generic");
local command = module:get_option_string("external_auth_command", "");
local read_timeout = module:get_option_number("external_auth_timeout", 5);
local blocking = module:get_option_boolean("external_auth_blocking", not(have_async and server.event and lpty.getfd));
local auth_processes = module:get_option_number("external_auth_processes", 1);

assert(script_type == "ejabberd" or script_type == "generic",
	"Config error: external_auth_protocol must be 'ejabberd' or 'generic'");
assert(not host:find(":"), "Invalid hostname");


if not blocking then
	log("debug", "External auth in non-blocking mode, yay!")
	waiter, guard = async.waiter, async.guarder();
elseif auth_processes > 1 then
	log("warn", "external_auth_processes is greater than 1, but we are in blocking mode - reducing to 1");
	auth_processes = 1;
end

local ptys = {};

local pty_options = { throw_errors = false, no_local_echo = true, use_path = false };
for i = 1, auth_processes do
	ptys[i] = lpty.new(pty_options);
end

function module.unload()
	for i = 1, auth_processes do
		ptys[i]:endproc();
	end
end

module:hook_global("server-cleanup", module.unload);

local curr_process = 0;
function send_query(text)
	curr_process = (curr_process%auth_processes)+1;
	local pty = ptys[curr_process];

	local finished_with_pty
	if not blocking then
		finished_with_pty = guard(pty); -- Prevent others from crossing this line while we're busy
	end
	if not pty:hasproc() then
		local status, ret = pty:exitstatus();
		if status and (status ~= "exit" or ret ~= 0) then
			log("warn", "Auth process exited unexpectedly with %s %d, restarting", status, ret or 0);
			return nil;
		end
		local ok, err = pty:startproc(command);
		if not ok then
			log("error", "Failed to start auth process '%s': %s", command, err);
			return nil;
		end
		log("debug", "Started auth process");
	end

	pty:send(text);
	if blocking then
		return pty:read(read_timeout);
	else
		local response;
		local wait, done = waiter();
		server.addevent(pty:getfd(), server.event.EV_READ, function ()
			response = pty:read();
			done();
			return -1;
		end);
		wait();
		finished_with_pty();
		return response;
	end
end

function do_query(kind, username, password)
	if not username then return nil, "not-acceptable"; end

	local query = (password and "%s:%s:%s:%s" or "%s:%s:%s"):format(kind, username, host, password);
	local len = #query
	if len > 1000 then return nil, "policy-violation"; end

	if script_type == "ejabberd" then
		local lo = len % 256;
		local hi = (len - lo) / 256;
		query = string.char(hi, lo)..query;
	elseif script_type == "generic" then
		query = query..'\n';
	end

	local response, err = send_query(query);
	if not response then
		log("warn", "Error while waiting for result from auth process: %s", err or "unknown error");
	elseif (script_type == "ejabberd" and response == "\0\2\0\0") or
		(script_type == "generic" and response:gsub("\r?\n$", "") == "0") then
			return nil, "not-authorized";
	elseif (script_type == "ejabberd" and response == "\0\2\0\1") or
		(script_type == "generic" and response:gsub("\r?\n$", "") == "1") then
			return true;
	else
		log("warn", "Unable to interpret data from auth process, %s",
			(response:match("^error:") and response) or ("["..#response.." bytes]"));
		return nil, "internal-server-error";
	end
end

local function new_external_provider(host)
	local provider = { name = "external" };
	log("debug", "initializing external authentication provider for host '%s'", host);

	function provider.test_password(username, password)
		return do_query("auth", username, password);
	end

	function provider.set_password(username, password)
		return do_query("setpass", username, password);
	end

	function provider.user_exists(username)
		return do_query("isuser", username);
	end

	function provider.is_locked(username)
		return false;
	end

	function provider.unlock_user(username)
		return nil, "Action not available with this backend";
	end

	function provider.create_user(username, password)
		return nil, "Account creation/modification not available.";
	end

	function provider.get_sasl_handler()
		local testpass_authentication_profile = {
			plain_test = function(sasl, username, password, realm)
				return usermanager.test_password(username, realm, password), true;
			end,
		};
		return new_sasl(host, testpass_authentication_profile);
	end

	return provider;
end

module:add_item("auth-provider", new_external_provider(module.host));
