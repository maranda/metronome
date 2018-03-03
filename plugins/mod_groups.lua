-- * Metronome IM *
--
-- This file is part of the Metronome XMPP server and is released under the
-- ISC License, please see the LICENSE file in this source package for more
-- information about copyright and licensing.
--
-- As per the sublicensing clause, this file is also MIT/X11 Licensed.
-- ** Copyright (c) 2009-2011, Christian Haase, Jeff Mitchell, Matthew Wild

if hosts[module.host].anonymous_host then
	module:log("error", "Roster Groups won't be available on anonymous hosts as storage is explicitly disabled");
	return;
end

local groups;
local members;

local groups_file;

local jid, datamanager = require "util.jid", require "util.datamanager";
local jid_bare, jid_prep = jid.bare, jid.prep;

local module_host = module:get_host();

function inject_roster_contacts(username, host, roster)
	local bare_jid = username.."@"..host;
	if not members[bare_jid] and not members[false] then return; end -- Not a member of any groups
	
	local function import_jids_to_roster(group_name)
		for jid in pairs(groups[group_name]) do
			-- Add them to roster
			if jid ~= bare_jid then
				if not roster[jid] then roster[jid] = {}; end
				roster[jid].subscription = "both";
				if groups[group_name][jid] then
					roster[jid].name = groups[group_name][jid];
				end
				if not roster[jid].groups then
					roster[jid].groups = { [group_name] = true };
				end
				roster[jid].groups[group_name] = true;
				roster[jid].persist = false;
			end
		end
	end

	if members[bare_jid] then
		for _, group_name in ipairs(members[bare_jid]) do
			import_jids_to_roster(group_name);
		end
	end
	
	if members[false] then
		for _, group_name in ipairs(members[false]) do
			import_jids_to_roster(group_name);
		end
	end
	
	if roster[false] then
		roster[false].version = true;
	end
end

function remove_virtual_contacts(username, host, datastore, data)
	if host == module_host and datastore == "roster" then
		local new_roster = {};
		for jid, contact in pairs(data) do
			if contact.persist ~= false then
				new_roster[jid] = contact;
			end
		end
		if new_roster[false] then
			new_roster[false].version = nil; -- Version is void
		end
		return username, host, datastore, new_roster;
	end

	return username, host, datastore, data;
end

function module.load()
	groups_file = config.get(module_host, "groups_file");
	if not groups_file then
		module:log("error", 
			   "No groups file found, please be sure to add the groups_file statement on the %s host section",
			   module_host);
		return; 
	end
	
	module:hook("roster-load", inject_roster_contacts);
	datamanager.add_callback(remove_virtual_contacts);
	
	groups = { default = {} };
	members = { };
	local curr_group = "default";
	for line in io.lines(groups_file) do
		if line:match("^%s*%[.-%]%s*$") then
			curr_group = line:match("^%s*%[(.-)%]%s*$");
			if curr_group:match("^%+") then
				curr_group = curr_group:gsub("^%+", "");
				if not members[false] then
					members[false] = {};
				end
				members[false][#members[false]+1] = curr_group; -- Is a public group
			end
			module:log("debug", "New group: %s", tostring(curr_group));
			groups[curr_group] = groups[curr_group] or {};
		else
			-- Add JID
			local entryjid, name = line:match("([^=]*)=?(.*)");
			module:log("debug", "entryjid = '%s', name = '%s'", entryjid, name);
			local jid;
			jid = jid_prep(entryjid:match("%S+"));
			if jid then
				module:log("debug", "New member of %s: %s", tostring(curr_group), tostring(jid));
				groups[curr_group][jid] = name or false;
				members[jid] = members[jid] or {};
				members[jid][#members[jid]+1] = curr_group;
			end
		end
	end
	module:log("info", "Groups loaded successfully");
end

function module.unload()
	datamanager.remove_callback(remove_virtual_contacts);
end
