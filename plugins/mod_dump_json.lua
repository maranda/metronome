-- * Metronome IM *
--
-- This file is part of the Metronome XMPP server and is released under the
-- ISC License, please see the LICENSE file in this source package for more
-- information about copyright and licensing.
--
-- This metronomectl extension helps exporting a single datastore in JSON 
-- format to be used with external applications.

if not rawget(_G, "metronomectl") then
	module:log("error", "mod_dump_json can only be loaded from metronomectl!");
	return;
end

local datamanager = require "util.datamanager";
local storagemanager = require "core.storagemanager";
local jid = require "util.jid";
local json = require "util.json";
local message = metronomectl.show_message;
	
function module.command(arg)
	local node, host, store = arg[1], arg[2], arg[3];
	if not node or not host or not store then
		message("Incorrect syntax please use:");
		message("metronomectl mod_dump_json <store node> <host> <store name>");
		return 1;
	end
	
	storagemanager.initialize_host(host);
	local data = datamanager.load(node, host, store);
	if data then
		message(json.encode(data));
		return 0;
	else
		message("Datastore is empty");
		return 1;
	end
end