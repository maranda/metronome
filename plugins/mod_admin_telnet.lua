-- * Metronome IM *
--
-- This file is part of the Metronome XMPP server and is released under the
-- ISC License, please see the LICENSE file in this source package for more
-- information about copyright and licensing.
--
-- As per the sublicensing clause, this file is also MIT/X11 Licensed.
-- ** Copyright (c) 2010-2013, Kim Alvefur, Florian Zeitz, Marco Cirillo, Matthew Wild, Paul Aurich, Waqas Hussain

module:set_global();

local hostmanager = require "core.hostmanager";
local s2smanager = require "util.s2smanager";
local portmanager = require "core.portmanager";

local _G = _G;

local metronome = _G.metronome;
local hosts = metronome.hosts;
local full_sessions = metronome.full_sessions;
local incoming_s2s = metronome.incoming_s2s;

local console_listener = { default_port = 5582; default_mode = "*a"; interface = "127.0.0.1" };

local iterators = require "util.iterators";
local keys, values = iterators.keys, iterators.values;
local jid = require "util.jid";
local jid_bare, jid_split = jid.bare, jid.split;
local set, array = require "util.set", require "util.array";
local cert_verify_identity = require "util.x509".verify_identity;
local envload = require "util.envload".envload;
local envloadfile = require "util.envload".envloadfile;
local pcall, rand, abs = pcall, math.random, math.abs;
local dns = require "net.dns";
local st = require "util.stanza";
local cm = require "core.configmanager";
local mm = require "core.modulemanager";
local um = require "core.usermanager";
local read_version = read_version;

local graphic_banner, short_banner;

local commands = module:shared("commands")
local def_env = module:shared("env");
local default_env_mt = { __index = def_env };

local ok, pposix = pcall(require, "util.pposix");
if not ok then pposix = nil; end

local strict_host_checks = module:get_option_boolean("admin_telnet_strict_host_checks", true);
local auth_user = module:get_option_string("admin_telnet_auth_user");

local function redirect_output(_G, session)
	local env = setmetatable({ print = session.print }, { __index = function (t, k) return rawget(_G, k); end });
	env.dofile = function(name)
		local f, err = envloadfile(name, env);
		if not f then return f, err; end
		return f();
	end;
	return env;
end

console = {};

function console:new_session(conn)
	local w = function(s) conn:write(s:gsub("\n", "\r\n")); end;
	local session = { conn = conn;
			send = function (t) w(tostring(t)); end;
			print = function (...)
				local t = {};
				for i=1,select("#", ...) do
					t[i] = tostring(select(i, ...));
				end
				w("| "..table.concat(t, "\t").."\n");
			end;
			disconnect = function () conn:close(); end;
			};
	session.env = setmetatable({}, default_env_mt);
	
	for name, t in pairs(def_env) do
		if type(t) == "table" then
			session.env[name] = setmetatable({ session = session }, { __index = t });
		end
	end
	
	return session;
end

local sessions = {};

function console_listener.onconnect(conn)
	local session = console:new_session(conn);
	sessions[conn] = session;
	printbanner(session);
	session.send(string.char(0));
end

local wrong_password = {
	"No not that...", "Maybe near... but no", "Fire... fireeee... Water, sorry.", "Wrong Password"
};

function console_listener.onincoming(conn, data)
	local session = sessions[conn];

	if data:match("^"..string.char(255)..".*") then return; end

	local partial = session.partial_data;
	if partial then
		data = partial..data;
	end

	for line in data:gmatch("[^\n]*[\n\004]") do
		repeat
			local useglobalenv;

			if session.wait_password then
				local pass = line:match("(.*)\r\n$");
				local user, host = jid_split(auth_user);
				if um.test_password(user, host, pass) then
					session.print(short_banner);
					session.send(string.char(255,252,1));
					session.wait_password = nil;
					session.wrong_password = nil;
					break;
				else
					session.wrong_pass = session.wrong_pass and session.wrong_pass + 1 or 1;
					if session.wrong_pass >= 3 then
						commands.bye(session, "Too many wrong login attempts, have a nice day! ;)");
					else
						session.print(wrong_password[rand(1,4)]);
						session.print("Please insert the console password:");
					end
					break;
				end
			elseif line:match("^>") then
				line = line:gsub("^>", "");
				useglobalenv = true;
			elseif line == "\004" then
				commands.bye(session, line);
				break;
			else
				local command = line:match("^%w+") or line:match("%p");
				if commands[command] then
					commands[command](session, line);
					break;
				end
			end

			session.env._ = line;
			
			local chunkname = "=console";
			local env = (useglobalenv and redirect_output(_G, session)) or session.env or nil
			local chunk, err = envload("return "..line, chunkname, env);
			if not chunk then
				chunk, err = envload(line, chunkname, env);
				if not chunk then
					err = err:gsub("^%[string .-%]:%d+: ", "");
					err = err:gsub("^:%d+: ", "");
					err = err:gsub("'<eof>'", "the end of the line");
					session.print("Sorry, I couldn't understand that... "..err);
					break;
				end
			end
		
			local ranok, taskok, message = pcall(chunk);
			
			if not (ranok or message or useglobalenv) and commands[line:lower()] then
				commands[line:lower()](session, line);
				break;
			end
			
			if not ranok then
				session.print("Fatal error while running command, it did not complete");
				session.print("Error: "..taskok);
				break;
			end
			
			if not message then
				session.print("Result: "..tostring(taskok));
				break;
			elseif (not taskok) and message then
				session.print("Command completed with a problem");
				session.print("Message: "..tostring(message));
				break;
			end
			
			session.print("OK: "..tostring(message));
		until true
		
		session.send(string.char(0));
	end
	session.partial_data = data:match("[^\n]+$");
end

function console_listener.ondisconnect(conn, err)
	local session = sessions[conn];
	if session then
		session.disconnect();
		sessions[conn] = nil;
	end
end

-- Console commands --
-- These are simple commands, not valid standalone in Lua

function commands.bye(session, line)
	if line == "bye\r\n" or line == "quit\r\n" or line == "exit\r\n" then line = nil; end
	session.print(line or "See you! :)");
	session.disconnect();
end
commands.quit, commands.exit = commands.bye, commands.bye;

commands["!"] = function (session, data)
	if data:match("^!!") and session.env._ then
		session.print("!> "..session.env._);
		return console_listener.onincoming(session.conn, session.env._);
	end
	local old, new = data:match("^!(.-[^\\])!(.-)!$");
	if old and new then
		local ok, res = pcall(string.gsub, session.env._, old, new);
		if not ok then
			session.print(res)
			return;
		end
		session.print("!> "..res);
		return console_listener.onincoming(session.conn, res);
	end
	session.print("Sorry, not sure what you want");
end


function commands.help(session, data)
	local print = session.print;
	local section = data:match("^help (%w+)");
	if not section then
		print [[Commands are divided into multiple sections. For help on a particular section, ]]
		print [[type: help SECTION (for example, 'help c2s'). Sections are: ]]
		print [[]]
		print [[dns - Commands to manage Metronome's internal dns resolver]]
		print [[c2s - Commands to manage local client-to-server sessions]]
		print [[s2s - Commands to manage sessions between this server and others]]
		print [[module - Commands to load/reload/unload modules/plugins]]
		print [[host - Commands to activate, deactivate and list virtual hosts]]
		print [[muc - Commands to retrieve and manage MUC room objects]]
		print [[user - Commands to create and delete users, and change their passwords]]
		print [[port - Commands to manage server listening port interfaces]]
		print [[server - Uptime, version, shutting down, etc.]]
		print [[config - Reloading the configuration, etc.]]
		print [[console - Help regarding the console itself]]
	elseif section == "dns" then
		print [[dns:reload() - Reload system resolvers configuration data]]
		print [[dns:purge() - Purge the internal dns cache]]
		print [[dns:set(serverlist) - Sets an arbitrary list of resolvers (argument passed can either be a string or list)]]
	elseif section == "c2s" then
		print [[c2s:show(jid) - Show all client sessions with the specified JID (or all if no JID given)]]
		print [[c2s:show_compressed() - Show all compressed client connections]]
		print [[c2s:show_insecure() - Show all unencrypted client connections]]
		print [[c2s:show_secure() - Show all encrypted client connections]]
		print [[c2s:show_direct_tls() - Show all direct tls client connections]]
		print [[c2s:show_sm() - Show all stream management enabled client connections]]
		print [[c2s:show_csi() - Show all client state indication enabled client connections]]
		print [[c2s:close(jid) - Close all sessions for the specified JID]]
		print [[c2s:closeall() - Close all c2s sessions]]
	elseif section == "s2s" then
		print [[s2s:show(domain) - Show all s2s connections for the given domain (or all if no domain given)]]
		print [[s2s:close(from, to) - Close a connection from one domain to another]]
		print [[s2s:closeall(host) - Close all the incoming/outgoing s2s sessions, or all to the specified host]]
	elseif section == "module" then
		print [[module:load(module, host) - Load the specified module on the specified host (or all hosts if none given)]]
		print [[module:reload(module, host) - The same, but unloads and loads the module (saving state if the module supports it)]]
		print [[module:unload(module, host) - The same, but just unloads the module from memory]]
		print [[module:list(host) - List the modules loaded on the specified host]]
	elseif section == "host" then
		print [[host:activate(hostname) - Activates the specified host]]
		print [[host:deactivate(hostname) - Disconnects all clients on this host and deactivates]]
		print [[host:list() - List the currently-activated hosts]]
	elseif section == "muc" then
		print [[muc:room(roomjid) - Return room object for the choosen room jid, e.g. you can destroy by using muc:room(roomjid):destroy()]]
	elseif section == "user" then
		print [[user:create(jid, password) - Create the specified user account]]
		print [[user:password(jid, password) - Set the password for the specified user account]]
		print [[user:delete(jid) - Permanently remove the specified user account]]
	elseif section == "port" then
		print [[port:list() - Show an ordered by service list of ports and interfaces they're listening on]]
		print [[port:close(port, address) - Close the specified port on all ip addresses or only on the specified interface]]
	elseif section == "server" then
		print [[server:meminfo() - Show the server's memory usage]]
		print [[server:version() - Show the server's version number]]
		print [[server:uptime() - Show how long the server has been running]]
		print [[server:shutdown(reason) - Shut down the server, with an optional reason to be broadcast to all connections]]
	elseif section == "config" then
		print [[config:reload() - Reload the server configuration. Modules may need to be reloaded for changes to take effect]]
	elseif section == "console" then
		print [[Hey! Welcome to Metronome's admin console.]]
		print [[First thing, if you're ever wondering how to get out, simply type 'quit'.]]
		print [[Secondly, note that we don't support the full telnet protocol yet (it's coming)]]
		print [[so you may have trouble using the arrow keys, etc. depending on your system.]]
		print [[]]
		print [[For now we offer a couple of handy shortcuts:]]
		print [[!! - Repeat the last command]]
		print [[!old!new! - repeat the last command, but with 'old' replaced by 'new']]
		print [[]]
		print [[For those well-versed in Metronome's internals, or taking instruction from those who are,]]
		print [[you can prefix a command with > to escape the console sandbox, and access everything in]]
		print [[the running server. Great fun, but be careful not to break anything :)]]
	end
	print [[]]
end

-- Session environment --
-- Anything in def_env will be accessible within the session as a global variable

def_env.st = st; -- expose util.stanza
def_env.server = {};

function def_env.server:meminfo()
	local info = pposix and pposix.meminfo and pposix.meminfo();
	if not info then -- fallback to GC count
		return true, string.format("Posix library unavailable reporting only lua memory usage: %d bytes",
							collectgarbage("count")*1024);
	end
	
	-- also fix integer overflow from malloc after 4GB
	return true, string.format("Used: %d bytes, Allocated: %d bytes, Unused: %d bytes",
						abs(info.used), abs(info.allocated), abs(info.unused));
end

function def_env.server:version()
	return true, tostring(metronome.version or "unknown");
end

function def_env.server:update_version()
	read_version();

	for name in pairs(hosts) do mm.reload(name, "version"); end
	return true, tostring("Updated, "..(metronome.version or "unknown"));
end

function def_env.server:uptime()
	local t = os.time()-metronome.start_time;
	local seconds = t%60;
	t = (t - seconds)/60;
	local minutes = t%60;
	t = (t - minutes)/60;
	local hours = t%24;
	t = (t - hours)/24;
	local days = t;
	return true, string.format("This server has been running for %d day%s, %d hour%s and %d minute%s (since %s)",
		days, (days ~= 1 and "s") or "", hours, (hours ~= 1 and "s") or "",
		minutes, (minutes ~= 1 and "s") or "", os.date("%c", metronome.start_time));
end

function def_env.server:shutdown(reason)
	metronome.shutdown(reason);
	return true, "Shutdown initiated";
end

def_env.module = {};

local function get_hosts_set(hosts, module)
	if type(hosts) == "table" then
		if hosts[1] then
			return set.new(hosts);
		elseif hosts._items then
			return hosts;
		end
	elseif type(hosts) == "string" then
		return set.new { hosts };
	elseif hosts == nil then
		local hosts_set = set.new(array.collect(keys(metronome.hosts)));
		if module and mm.get_module("*", module) then
			hosts_set:add("*");
		end
		return hosts_set;
	end
end

function def_env.module:load(name, hosts)
	local _hosts = get_hosts_set(hosts);
	
	local ok, err, count, mod = true, nil, 0, nil;
	for host in _hosts do
		local _host = module:get_host_session(host);
		if not _host then
			ok, err = false, "Host doesn't exists";
		end
		if _host and (not mm.is_loaded(host, name)) then
			if not hosts and _host.type == "component" then
				mod, err = mm.load(host, name, set.new {})
			else
				mod, err = mm.load(host, name);
			end
				
			if not mod and err ~= "module-not-component-inheritable" then
				ok = false;
				if err == "global-module-already-loaded" then
					if count > 0 then
						ok, err, count = true, nil, 1;
					end
					break;
				end
				self.session.print(err or "Unknown error loading module");
			elseif not err then
				count = count + 1;
				self.session.print("Loaded for "..mod.module.host);
			end
		end
	end
	
	return ok, (ok and "Module loaded onto "..count.." host"..(count ~= 1 and "s" or "")) or ("Last error: "..tostring(err));	
end

function def_env.module:unload(name, hosts)
	hosts = get_hosts_set(hosts, name);
	
	local ok, err, count = true, nil, 0;
	for host in hosts do
		if mm.is_loaded(host, name) then
			ok, err = mm.unload(host, name);
			if not ok then
				ok = false;
				self.session.print(err or "Unknown error unloading module");
			else
				count = count + 1;
				self.session.print("Unloaded from "..host);
			end
		end
	end
	return ok, (ok and "Module unloaded from "..count.." host"..(count ~= 1 and "s" or "")) or ("Last error: "..tostring(err));
end

function def_env.module:reload(name, hosts)
	hosts = array.collect(get_hosts_set(hosts, name)):sort(function (a, b)
		if a == "*" then return true
		elseif b == "*" then return false
		else return a < b; end
	end);

	local ok, err, count = true, nil, 0;
	for _, host in ipairs(hosts) do
		if mm.is_loaded(host, name) then
			ok, err = mm.reload(host, name);
			if not ok then
				ok = false;
				self.session.print(err or "Unknown error reloading module");
			else
				count = count + 1;
				if ok == nil then
					ok = true;
				end
				self.session.print("Reloaded on "..host);
			end
		end
	end
	return ok, (ok and "Module reloaded on "..count.." host"..(count ~= 1 and "s" or "")) or ("Last error: "..tostring(err));
end

function def_env.module:list(hosts)
	if hosts == nil then
		hosts = array.collect(keys(metronome.hosts));
		table.insert(hosts, 1, "*");
	end
	if type(hosts) == "string" then
		hosts = { hosts };
	end
	if type(hosts) ~= "table" then
		return false, "Please supply a host or a list of hosts you would like to see";
	end
	
	local print = self.session.print;
	for _, host in ipairs(hosts) do
		print((host == "*" and "Global" or host)..":");
		local modules = array.collect(keys(mm.get_modules(host) or {})):sort();
		if #modules == 0 then
			if module:get_host_session(host) then
				print("    No modules loaded");
			else
				print("    Host not found");
			end
		else
			for _, name in ipairs(modules) do
				print("    "..name);
			end
		end
	end
end

def_env.dns = {};

function def_env.dns:reload()
	dns._resolver:resetnameservers();

	return true, "Resolvers configuration reloaded";
end

function def_env.dns:purge()
	dns.purge();

	return true, "Internal dns cache has been purged";
end

function def_env.dns:set(arg)
	if type(arg) ~= "string" and type(arg) ~= "table" then
		return false, "Passed argument needs to either be a string or list"
	elseif type(arg) == "table" and #arg == 0 then
		return false, "Passed table is not a valid list"
	end
	dns._resolver:setnameservers(arg);

	return true, "DNS resolvers list changed";
end

def_env.config = {};

function def_env.config:load(filename, format)
	local ok, err = cm.load(filename, format);
	if not ok then
		return false, err or "Unknown error loading config";
	end
	return true, "Config loaded";
end

function def_env.config:get(host, section, key)
	return true, tostring(cm.get(host, section, key));
end

function def_env.config:reload()
	local ok, err = metronome.reload_config();
	return ok, (ok and "Config reloaded (you may need to reload modules to take effect)") or tostring(err);
end

def_env.hosts = {};

function def_env.hosts:list()
	for host, host_session in pairs(hosts) do
		self.session.print(host);
	end
	return true, "Done";
end

function def_env.hosts:add(name)
end

local function session_flags(session, line)
	if session.cert_identity_status == "valid" then
		line[#line+1] = "(secure)";
	elseif session.secure then
		line[#line+1] = "(encrypted)";
	end
	if session.direct_tls_c2s or session.direct_tls_s2s then
		line[#line+1] = "(direct tls)";
	end
	if session.compressed then
		line[#line+1] = "(compressed)";
	end
	if session.sm then
		line[#line+1] = "(sm)";
	end
	if session.csi then
		if session.csi == "active" then
			line[#line+1] = "(csi active)";
		else
			line[#line+1] = "(csi inactive)";
		end
	end
	if session.bidirectional then
		line[#line+1] = "(bidi)";
	end
	if session.conn and session.conn.ip and session.conn:ip():match(":") then
		line[#line+1] = "(ipv6)";
	end
	return table.concat(line, " ");
end

def_env.c2s = {};

local function show_c2s(callback)
	for jid, session in pairs(full_sessions) do callback(jid, session); end
end

function def_env.c2s:count(match_jid)
	local count = 0;
	show_c2s(function (jid, session)
		if (not match_jid) or jid:match(match_jid) then
			count = count + 1;
		end		
	end);
	return true, "Total: "..count.." clients";
end

function def_env.c2s:show(match_jid)
	local print, count = self.session.print, 0;
	local curr_host;
	show_c2s(function (jid, session)
		if curr_host ~= session.host then
			curr_host = session.host;
			print(curr_host);
		end
		if (not match_jid) or jid:match(match_jid) then
			count = count + 1;
			local status, priority = "unavailable", tostring(session.priority or "-");
			if session.presence then
				status = session.presence:child_with_name("show");
				if status then
					status = status:get_text() or "[invalid!]";
				else
					status = "available";
				end
			end
			print(session_flags(session, {"   ", jid, "-", status.."("..priority..")", "-"}));
		end		
	end);
	return true, "Total: "..count.." clients";
end

local function show_type(self, match_jid, flag, void)
	local print, count = self.session.print, 0;
	show_c2s(function (jid, session)
		if ((not match_jid) or jid:match(match_jid)) and
		   ((void and not session[flag]) or (not void and session[flag])) then
			count = count + 1;
			print(jid);
		end		
	end);
	return count;
end

function def_env.c2s:show_compressed(match_jid)
	local count = show_type(self, match_jid, "compressed");
	return true, "Total: "..count.." compressed client connections";
end

function def_env.c2s:show_insecure(match_jid)
	local count = show_type(self, match_jid, "secure", true);
	return true, "Total: "..count.." insecure client connections";
end

function def_env.c2s:show_secure(match_jid)
	local count = show_type(self, match_jid, "secure");
	return true, "Total: "..count.." secure client connections";
end

function def_env.c2s:show_direct_tls(match_jid)
	local count = show_type(self, match_jid, "direct_tls_c2s");
	return true, "Total: "..count.." direct tls client connections";
end

function def_env.c2s:show_sm(match_jid)
	local count = show_type(self, match_jid, "sm");
	return true, "Total: "..count.." stream management enabled client connections";
end

function def_env.c2s:show_csi(match_jid)
	local count = show_type(self, match_jid, "csi");
	return true, "Total: "..count.." client state indication enabled client connections";
end

function def_env.c2s:close(match_jid)
	local count = 0;
	show_c2s(function (jid, session)
		if jid == match_jid or jid_bare(jid) == match_jid then
			count = count + 1;
			session:close();
		end
	end);
	return true, "Total: "..count.." sessions closed";
end

function def_env.c2s:closeall()
	local count = 0;
	for jid, session in pairs(full_sessions) do
		count = count + 1;
		session:close();
	end
	return true, "Total: "..count.." sessions closed";
end

def_env.s2s = {};
function def_env.s2s:show(match_jid)
	local _print = self.session.print;
	local print = self.session.print;
	
	local count_in, count_out = 0,0;
	
	for host, host_session in pairs(hosts) do
		print = function (...) _print(host); _print(...); print = _print; end
		for remotehost, session in pairs(host_session.s2sout) do
			if (not match_jid) or remotehost:match(match_jid) or host:match(match_jid) then
				count_out = count_out + 1;
				print(session_flags(session, {"   ", host, "->", remotehost}));
				if session.sendq then
					print("        There are "..#session.sendq.." queued outgoing stanzas for this connection");
				end
				if session.type == "s2sout_unauthed" then
					if session.connecting then
						print("        Connection not yet established");
						if not session.srv_hosts then
							if not session.conn then
								print("        We do not yet have a DNS answer for this host's SRV records");
							else
								print("        This host has no SRV records, using A record instead");
							end
						elseif session.srv_choice then
							print("        We are on SRV record "..session.srv_choice.." of "..#session.srv_hosts);
							local srv_choice = session.srv_hosts[session.srv_choice];
							print("        Using "..(srv_choice.target or ".")..":"..(srv_choice.port or 5269));
						end
					elseif session.notopen then
						print("        The <stream> has not yet been opened");
					elseif not session.dialback_key then
						print("        Dialback has not been initiated yet");
					elseif session.dialback_key then
						print("        Dialback has been requested, but no result received");
					end
				end
			end
		end	
		local subhost_filter = function (h)
				return (match_jid and h:match(match_jid));
			end
		for session in pairs(incoming_s2s) do
			if session.to_host == host and ((not match_jid) or host:match(match_jid)
				or (session.from_host and session.from_host:match(match_jid))
				or (session.hosts and #array.collect(keys(session.hosts)):filter(subhost_filter)>0)) then
				count_in = count_in + 1;
				print(session_flags(session, {"   ", host, "<-", session.from_host or "(unknown)"}));
				if session.type == "s2sin_unauthed" then
						print("        Connection not yet authenticated");
				end
				for name in pairs(session.hosts) do
					if name ~= session.from_host then
						print("        also hosts "..tostring(name));
					end
				end
			end
		end
		
		print = _print;
	end
	
	for session in pairs(incoming_s2s) do
		if not session.to_host and ((not match_jid) or session.from_host and session.from_host:match(match_jid)) then
			count_in = count_in + 1;
			print("Other incoming s2s connections");
			print("    (unknown) <- "..(session.from_host or "(unknown)"));			
		end
	end
	
	return true, "Total: "..count_out.." outgoing, "..count_in.." incoming connections";
end

local function print_subject(print, subject)
	for _, entry in ipairs(subject) do
		print(
			("    %s: %q"):format(
				entry.name or entry.oid,
				entry.value:gsub("[\r\n%z%c]", " ")
			)
		);
	end
end

-- As much as it pains me to use the 0-based depths that OpenSSL does,
-- I think there's going to be more confusion among operators if we
-- break from that.
local function print_errors(print, errors)
	for depth, t in ipairs(errors) do
		print(
			("    %d: %s"):format(
				depth-1,
				table.concat(t, "\n|        ")
			)
		);
	end
end

function def_env.s2s:showcert(domain)
	local ser = require "util.serialization".serialize;
	local print = self.session.print;
	local domain_sessions = set.new(array.collect(keys(incoming_s2s)))
		/function(session) return session.from_host == domain and session or nil; end;
	for local_host in values(metronome.hosts) do
		local s2sout = local_host.s2sout;
		if s2sout and s2sout[domain] then
			domain_sessions:add(s2sout[domain]);
		end
	end
	local cert_set = {};
	for session in domain_sessions do
		local conn = session.conn;
		conn = conn and conn:socket();
		if not conn.getpeerchain then
			if conn.dohandshake then
				error("This version of LuaSec does not support certificate viewing");
			end
		else
			local certs = conn:getpeerchain();
			local cert = certs[1];
			if cert then
				local digest = cert:digest("sha1");
				if not cert_set[digest] then
					local chain_valid, chain_errors = conn:getpeerverification();
					cert_set[digest] = {
						{
						  from = session.from_host,
						  to = session.to_host,
						  direction = session.direction
						};
						chain_valid = chain_valid;
						chain_errors = chain_errors;
						certs = certs;
					};
				else
					table.insert(cert_set[digest], {
						from = session.from_host,
						to = session.to_host,
						direction = session.direction
					});
				end
			end
		end
	end
	local domain_certs = array.collect(values(cert_set));
	local n_certs = #domain_certs;
	
	if n_certs == 0 then
		return "No certificates found for "..domain;
	end
	
	local function _capitalize_and_colon(byte)
		return string.upper(byte)..":";
	end
	local function pretty_fingerprint(hash)
		return hash:gsub("..", _capitalize_and_colon):sub(1, -2);
	end
	
	for cert_info in values(domain_certs) do
		local certs = cert_info.certs;
		local cert = certs[1];
		print("---")
		print("Fingerprint (SHA1): "..pretty_fingerprint(cert:digest("sha1")));
		print("");
		local n_streams = #cert_info;
		print("Currently used on "..n_streams.." stream"..(n_streams==1 and "" or "s")..":");
		for _, stream in ipairs(cert_info) do
			if stream.direction == "incoming" then
				print("    "..stream.to.." <- "..stream.from);
			else
				print("    "..stream.from.." -> "..stream.to);
			end
		end
		print("");
		local chain_valid, errors = cert_info.chain_valid, cert_info.chain_errors;
		local valid_identity = cert_verify_identity(domain, "xmpp-server", cert);
		if chain_valid then
			print("Trusted certificate: Yes");
		else
			print("Trusted certificate: No");
			print_errors(print, errors);
		end
		print("");
		print("Issuer: ");
		print_subject(print, cert:issuer());
		print("");
		print("Valid for "..domain..": "..(valid_identity and "Yes" or "No"));
		print("Subject:");
		print_subject(print, cert:subject());
	end
	print("---");
	return ("Showing "..n_certs.." certificate"
		..(n_certs==1 and "" or "s")
		.." presented by "..domain..".");
end

function def_env.s2s:close(from, to)
	local print, count = self.session.print, 0;
	
	if not (from and to) then
		return false, "Syntax: s2s:close('from', 'to') - Closes all s2s sessions from 'from' to 'to'";
	elseif from == to then
		return false, "Both from and to are the same... you can't do that :)";
	end
	
	if hosts[from] and not hosts[to] then
		-- Outgoing conn.
		local session = hosts[from].s2sout[to];
		if not session then
			print("No outgoing connection from "..from.." to "..to)
		else
			(session.close or s2smanager.destroy_session)(session);
			count = count + 1;
			print("Closed outgoing session from "..from.." to "..to);
		end
	elseif hosts[to] and not hosts[from] then
		-- Incoming conn.
		for session in pairs(incoming_s2s) do
			if session.to_host == to and session.from_host == from then
				(session.close or s2smanager.destroy_session)(session);
				count = count + 1;
			end
		end
		
		if count == 0 then
			print("No incoming connections from "..from.." to "..to);
		else
			print("Closed "..count.." incoming session"..((count == 1 and "") or "s").." from "..from.." to "..to);
		end
	elseif hosts[to] and hosts[from] then
		return false, "Both of the hostnames you specified are local, there are no s2s sessions to close";
	else
		return false, "Neither of the hostnames you specified are being used on this server";
	end
	
	return true, "Closed "..count.." s2s session"..((count == 1 and "") or "s");
end

function def_env.s2s:closeall(host)
	local count = 0;

	if type(host) ~= "string" and type(host) ~= "nil" then return false, "wrong syntax: please use s2s:closeall('hostname.tld')"; end
	for session in pairs(incoming_s2s) do
		if session.to_host == host or session.from_host == host or not host then
			(session.close or s2smanager.destroy_session)(session);
			count = count + 1;
		end
	end
	for i, _host in pairs(hosts) do
		for name, session in pairs(_host.s2sout) do
			if name == host or not host then
				(session.close or s2smanager.destroy_session)(session);
				count = count + 1;
			end
		end
	end

	if count == 0 then 
		return false, "No sessions to close.";
	else
		return true, "Closed "..count.." s2s session"..((count == 1 and "") or "s");
	end
end

def_env.host = {}; def_env.hosts = def_env.host;
function def_env.host:activate(hostname, reload)
	-- auto-reload config as long as not stated otherwise
	if reload or reload == nil then
		local ok, err = metronome.reload_config();
		if err then 
			return false, "Config reload failure eventually, call host:activate("..hostname..", false) -- ERROR:"..tostring(err);
		end
	end

	if not cm.is_host_defined(hostname) and strict_host_checks then
		return false, "Hosts needs to be defined explicitly into the configuration before being activated (to avoid this set << admin_telnet_strict_host_checks = false >> in the global configuration)";
	end

	return hostmanager.activate(hostname);
end

function def_env.host:deactivate(hostname, reason)
	return hostmanager.deactivate(hostname, reason);
end

function def_env.host:list()
	local print = self.session.print;
	local i = 0;
	for host in values(array.collect(keys(metronome.hosts)):sort()) do
		i = i + 1;
		print(host);
	end
	return true, i.." hosts";
end

def_env.port = {};

function def_env.port:list()
	local print = self.session.print;
	local services = portmanager.get_active_services().data;
	local ordered_services, n_ports = {}, 0;
	for service, interfaces in pairs(services) do
		table.insert(ordered_services, service);
	end
	table.sort(ordered_services);
	for _, service in ipairs(ordered_services) do
		local ports_list = {};
		for interface, ports in pairs(services[service]) do
			for port in pairs(ports) do
				table.insert(ports_list, "["..interface.."]:"..port);
			end
		end
		n_ports = n_ports + #ports_list;
		print(service..": "..table.concat(ports_list, ", "));
	end
	return true, #ordered_services.." services listening on "..n_ports.." ports";
end

function def_env.port:close(close_port, close_interface)
	close_port = assert(tonumber(close_port), "Invalid port number");
	local n_closed = 0;
	local services = portmanager.get_active_services().data;
	for service, interfaces in pairs(services) do
		for interface, ports in pairs(interfaces) do
			if not close_interface or close_interface == interface then
				if ports[close_port] then
					self.session.print("Closing ["..interface.."]:"..close_port.."...");
					local ok, err = portmanager.close(interface, close_port)
					if not ok then
						self.session.print("Failed to close "..interface.." "..close_port..": "..err);
					else
						n_closed = n_closed + 1;
					end
				end
			end
		end
	end
	return true, "Closed "..n_closed.." ports";
end

def_env.muc = {};

local console_room_mt = {
	__index = function (self, k) return self.room[k]; end;
	__tostring = function (self)
		return "MUC room <"..self.room.jid..">";
	end;
};

function def_env.muc:room(room_jid)
	local room_name, host = jid_split(room_jid);
	if not module:host_is_muc(host) then
		return nil, "Host '"..host.."' doesn't exist or is not a MUC service";
	end
	local muc = module:get_host_session(host).muc;
	local room_obj = muc.rooms[room_jid];
	if not room_obj then
		return nil, "No such room: "..room_jid;
	end
	return setmetatable({ room = room_obj }, console_room_mt);
end

def_env.user = {};
function def_env.user:create(jid, password)
	local username, host = jid_split(jid);
	if um.user_exists(username, host) then return nil, "User exists"; end
	local ok, err = um.create_user(username, password, host);
	if ok then
		return true, "User created";
	else
		return nil, "Could not create user: "..err;
	end
end

function def_env.user:delete(jid)
	local username, host = jid_split(jid);
	if not um.user_exists(username, host) then return nil, "User doesn't exist"; end
	local ok, err = um.delete_user(username, host);
	if ok then
		return true, "User deleted";
	else
		return nil, "Could not delete user: "..err;
	end
end

function def_env.user:password(jid, password)
	local username, host = jid_split(jid);
	if not um.user_exists(username, host) then return nil, "User doesn't exist"; end
	local ok, err = um.set_password(username, password, host);
	if ok then
		return true, "User's password changed";
	else
		return nil, "Could not change password for user: "..err;
	end
end

def_env.xmpp = {};

function def_env.xmpp:ping(localhost, remotehost)
	if hosts[localhost] then
		module:fire_global_event("route/post", hosts[localhost],
			st.iq{ from=localhost, to=remotehost, type="get", id="ping" }
				:tag("ping", {xmlns = "urn:xmpp:ping"}));
		return true, "Sent ping";
	else
		return nil, "No such host";
	end
end

-------------

short_banner = "Welcome to the Metronome administration console. For a list of commands, type: help";
graphic_banner = [[ 
|
|          /===========\
|          | Mêtronôme |
|          \===========/
|
|          When things tick and tack...
|
|]];

local function print_auth(session)
	session.print("Please insert the console password:");
	session.wait_password = true;
	session.send(string.char(255,251,1));
end

function printbanner(session)
	local option = module:get_option("console_banner");
	if option == nil or option == "full" or option == "graphic" then
		session.print(graphic_banner);
	end
	if option == nil or option == "short" or option == "full" then
		if auth_user then
			print_auth(session);
		else
			session.print(short_banner);
		end
	end
	if option and option ~= "short" and option ~= "full" and option ~= "graphic" then
		if type(option) == "string" then
			session.print(option);
		elseif type(option) == "function" then
			module:log("warn", "Using functions as value for the console_banner option is no longer supported");
		end
		if auth_user then print_auth(session); end
	end
end

module:add_item("net-provider", {
	name = "console",
	listener = console_listener,
	default_port = 5582,
	private = true
});
