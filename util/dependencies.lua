-- * Metronome IM *
--
-- This file is part of the Metronome XMPP server and is released under the
-- ISC License, please see the LICENSE file in this source package for more
-- information about copyright and licensing.
--
-- As per the sublicensing clause, this file is also MIT/X11 Licensed.
-- ** Copyright (c) 2008-2011, Matthew Wild, Waqas Hussain

local metronome = metronome;

module("dependencies", package.seeall)

function softreq(...) local ok, lib =  pcall(require, ...); if ok then return lib; else return nil, lib; end end

-- Required to be able to find packages installed with luarocks
if not softreq "luarocks.loader" then -- LuaRocks 2.x
	softreq "luarocks.require"; -- LuaRocks <1.x
end

function missingdep(name, sources, msg)
	print("");
	print("**************************");
	print("Metronome was unable to find "..tostring(name));
	print("This package can be obtained in the following ways:");
	print("");
	local longest_platform = 0;
	for platform in pairs(sources) do
		longest_platform = math.max(longest_platform, #platform);
	end
	for platform, source in pairs(sources) do
		print("", platform..":"..(" "):rep(4+longest_platform-#platform)..source);
	end
	print("");
	print(msg or (name.." is required for Metronome to run, so we will now exit."));
	print("**************************");
	print("");
end

package.preload["util.ztact"] = function ()
	if not package.loaded["core.loggingmanager"] then
		error("util.ztact has been removed from Metronome and you need to fix your config file.", 0);
	else
		error("module 'util.ztact' has been deprecated in Metronome.");
	end
end;

function check_dependencies()
	local fatal;
	
	local lxp = softreq "lxp"
	if not lxp then
		missingdep("luaexpat", {
				["Debian/Ubuntu"] = "sudo apt-get install liblua5.1-expat0";
				["luarocks"] = "luarocks install luaexpat";
				["Source"] = "http://www.keplerproject.org/luaexpat/";
			});
		fatal = true;
	end
	
	local socket = softreq "socket"
	if not socket then
		missingdep("luasocket", {
				["Debian/Ubuntu"] = "sudo apt-get install liblua5.1-socket2";
				["luarocks"] = "luarocks install luasocket";
				["Source"] = "http://www.tecgraf.puc-rio.br/~diego/professional/luasocket/";
			});
		fatal = true;
	end

	local luaevent = softreq "luaevent" or softreq "luaevent.core"
	if not luaevent then
		missingdep("luaevent", {
		 		["Debian/Ubuntu"] = "sudo apt-get install liblua5.1-event0";
				["luarocks"] = "luarocks install luaevent";
		 		["Source"] = "https://github.com/harningt/luaevent";
		 	});
		fatal = true;
	end	
	
	local lfs, err = softreq "lfs"
	if not lfs then
		missingdep("luafilesystem", {
				["luarocks"] = "luarocks install luafilesystem";
		 		["Debian/Ubuntu"] = "sudo apt-get install liblua5.1-filesystem0";
		 		["Source"] = "http://www.keplerproject.org/luafilesystem/";
		 	});
		fatal = true;
	end
	
	local ssl = softreq "ssl"
	if not ssl then
		missingdep("LuaSec", {
				["Debian/Ubuntu"] = "http://prosody.im/download/start#debian_and_ubuntu";
				["luarocks"] = "luarocks install luasec";
				["Source"] = "http://www.inf.puc-rio.br/~brunoos/luasec/";
			}, "SSL/TLS support will not be available");
		metronome.no_encryption = true;
	end
	
	local encodings, err = softreq "util.encodings"
	if not encodings then
		if err:match("not found") then
			missingdep("util.encodings", {
		 				["GNU/Linux"] = "Run './configure' and 'make' in the Metronome source directory to build util/encodings.so";
		 			});
		else
			print "***********************************"
			print("util/encodings couldn't be loaded. Check that you have a recent version of libidn");
			print ""
			print("The full error was:");
			print(err)
			print "***********************************"
		end
		fatal = true;
	end

	local hashes, err = softreq "util.hashes"
	if not hashes then
		if err:match("not found") then
			missingdep("util.hashes", {
		 				["GNU/Linux"] = "Run './configure' and 'make' in the Metronome source directory to build util/hashes.so";
		 			});
	 	else
			print "***********************************"
			print("util/hashes couldn't be loaded. Check that you have a recent version of OpenSSL (libcrypto in particular)");
			print ""
			print("The full error was:");
			print(err)
			print "***********************************"
		end
		fatal = true;
	end
	return not fatal;
end

function log_warnings()
	if ssl then
		local major, minor, veryminor, patched = ssl._VERSION:match("(%d+)%.(%d+)%.?(%d*)(M?)");
		if not major or ((tonumber(major) == 0 and (tonumber(minor) or 0) <= 3 and (tonumber(veryminor) or 0) <= 2) and patched ~= "M") then
			log("error", "This version of LuaSec contains a known bug that causes disconnects, see https://metronome.im/building");
		end
	end
	if lxp then
		if not pcall(lxp.new, { StartDoctypeDecl = false }) then
			log("error", "The version of LuaExpat on your system leaves Metronome "
				.."vulnerable to denial-of-service attacks. You should upgrade to "
				.."LuaExpat 1.1.1 or higher as soon as possible. See "
				.."https://metronome.im/building for more information.");
		end
	end
end

return _M;
