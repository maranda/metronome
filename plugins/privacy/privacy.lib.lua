-- * Metronome IM *
--
-- This file is part of the Metronome XMPP server and is released under the
-- ISC License, please see the LICENSE file in this source package for more
-- information about copyright and licensing.
--
-- As per the sublicensing clause, this file is also MIT/X11 Licensed.
-- ** Copyright (c) 2009-2011, Florian Zeitz, Matthew Wild, Waqas Hussain

local st = require "util.stanza";
local bare_sessions, full_sessions = bare_sessions, full_sessions;
local ipairs, pairs, tonumber, tostring, t_insert, t_remove, t_sort = 
	ipairs, pairs, tonumber, tostring, table.insert, table.remove, table.sort;
local jid_bare, jid_join, jid_split =
	require "util.jid".bare, require "util.jid".join, require "util.jid".split;

local privacy_xmlns = "jabber:iq:privacy";
local blocking_xmlns = "urn:xmpp:blocking";

-- Privacy List Functions

local function priv_is_list_used(origin, name, privacy_lists)
	local user = bare_sessions[origin.username.."@"..origin.host];
	if user then
		for resource, session in pairs(user.sessions) do
			if resource ~= origin.resource then
				if session.active_privacylist == name then
					return true;
				elseif session.active_privacylist == nil and privacy_lists.default == name then
					return true;
				end
			end
		end
	end
end

local function priv_is_defaultlist_used(origin)
	local user = bare_sessions[origin.username.."@"..origin.host];
	if user then
		for resource, session in pairs(user.sessions) do
			if resource ~= origin.resource and session.active_privacylist == nil then
				return true;
			end
		end
	end
end

local function priv_decline_list(privacy_lists, origin, stanza, which)
	if which == "default" then
		if privacy_lists.default == "simple" then
			return { "cancel", "forbidden", "Can't decline current default list via privacy lists." };
		end
		
		if priv_is_defaultlist_used(origin) then
			return { "cancel", "conflict", "Another session is online and using the default list." };
		end
		privacy_lists.default = nil;
		origin.send(st.reply(stanza));
	elseif which == "active" then
		origin.active_privacylist = nil;
		origin.send(st.reply(stanza));
	else
		return { "modify", "bad-request", "Neither default nor active list specified to decline." };
	end
	return true;
end

local function priv_activate_list(privacy_lists, origin, stanza, which, name)
	local list = privacy_lists.lists[name];

	if which == "default" and list then
		if privacy_lists.default == "simple" then
			return { "cancel", "forbidden", "Can't change current default list via privacy lists." };
		end
	
		if priv_is_defaultlist_used(origin) then
			return { "cancel", "conflict", "Another session is online and using the default list." };
		end
		privacy_lists.default = name;

		origin.send(st.reply(stanza));
	elseif which == "active" and list then
		origin.active_privacylist = name;

		origin.send(st.reply(stanza));
	elseif not list then
		return { "cancel", "item-not-found", "No such list: "..name };
	else
		return { "modify", "bad-request", "No list chosen to be active or default." };
	end

	return true;
end

local function priv_delete_list(privacy_lists, origin, stanza, name)
	local list = privacy_lists.lists[name];

	if list then
		if name == "simple" then
			return { "modify", "policy-violation", "This list cannot be deleted via privacy lists." };
		end

		if priv_is_list_used(origin, name, privacy_lists) then
			return { "cancel", "conflict", "Another session is online and using the list which should be deleted." };
		end
		if privacy_lists.default == name then
			privacy_lists.default = nil;
		end
		if origin.active_privacylist == name then
			origin.active_privacylist = nil;
		end
		privacy_lists.lists[name] = nil;
		origin.send(st.reply(stanza));
		
		return true;
	end

	return { "modify", "bad-request", "Not existing list specifed to be deleted." };
end

local function priv_create_list(privacy_lists, origin, stanza, name, entries)
	if name == "simple" then
		return { "modify", "policy-violation", "This list name is reserved and can't be created via privacy lists." };
	end

	local bare_jid = origin.username.."@"..origin.host;
	
	if privacy_lists.lists == nil then
		privacy_lists.lists = {};
	end

	local list = {};
	privacy_lists.lists[name] = list;

	local order_check = {};
	list.name = name;
	list.items = {};

	for _, item in ipairs(entries) do
		if tonumber(item.attr.order) == nil or tonumber(item.attr.order) < 0 or order_check[item.attr.order] then
			return { "modify", "bad-request", "Order attribute not valid." };
		end
		
		if item.attr.type ~= "jid" and item.attr.type ~= "subscription" and
		   item.attr.type ~= "group" and item.attr.type ~= nil then
			return { "modify", "bad-request", "Type attribute not valid." };
		end
		
		local tmp = {};
		order_check[item.attr.order] = true;
		
		tmp["type"] = item.attr.type;
		tmp["value"] = item.attr.value;
		tmp["action"] = item.attr.action;
		tmp["order"] = tonumber(item.attr.order);
		tmp["presence-in"] = false;
		tmp["presence-out"] = false;
		tmp["message"] = false;
		tmp["iq"] = false;
		
		if #item.tags > 0 then
			for _, tag in ipairs(item.tags) do
				tmp[tag.name] = true;
			end
		end
		
		if tmp.type == "subscription" then
			if	tmp.value ~= "both" and
				tmp.value ~= "to" and
				tmp.value ~= "from" and
				tmp.value ~= "none" then
				return { "cancel", "bad-request", "Subscription value must be both, to, from or none." };
			end
		end
		
		if tmp.action ~= "deny" and tmp.action ~= "allow" then
			return { "cancel", "bad-request", "Action must be either deny or allow." };
		end
		list.items[#list.items + 1] = tmp;
	end
	
	t_sort(list, function(a, b) return a.order < b.order; end);

	origin.send(st.reply(stanza));
	if bare_sessions[bare_jid] then
		local iq = st.iq({ type = "set", id="privacy-lists-push" })
				:tag ("query", { xmlns = privacy_xmlns })
					:tag ("list", { name = list.name }):up():up();

		for resource, session in pairs(bare_sessions[bare_jid].sessions) do
			iq.attr.to = bare_jid.."/"..resource
			session.send(iq);
		end
	else
		return { "cancel", "bad-request", "internal error." };
	end

	return true;
end

local function priv_get_list(privacy_lists, origin, stanza, name)
	local reply = st.reply(stanza);
	reply:tag("query", { xmlns = privacy_xmlns });

	if name == nil then
		if privacy_lists.lists then
			if origin.active_privacylist then
				reply:tag("active", { name = origin.active_privacylist }):up();
			end
			if privacy_lists.default then
				reply:tag("default", { name = privacy_lists.default }):up();
			end
			for name,list in pairs(privacy_lists.lists) do
				reply:tag("list", { name = name }):up();
			end
		end
	else
		local list = privacy_lists.lists[name];
		if list then
			reply = reply:tag("list", { name = list.name });
			for _, item in ipairs(list.items) do
				reply:tag("item", { type = item.type, value = item.value, action = item.action, order = item.order });
				if item["message"] then reply:tag("message"):up(); end
				if item["iq"] then reply:tag("iq"):up(); end
				if item["presence-in"] then reply:tag("presence-in"):up(); end
				if item["presence-out"] then reply:tag("presence-out"):up(); end
				reply:up();
			end
		else
			return {"cancel", "item-not-found", "Unknown list specified."};
		end
	end
	
	origin.send(reply); 
	return true;
end

-- Simple Blocking Command Functions

local function simple_create_list(privacy_lists)
	if not privacy_lists.lists.simple then
		privacy_lists.default = "simple";
		privacy_lists.lists.simple = {
			name = "Simple Blocking Command (XEP-0191) List",
			items = {}
		};
	end
end

local function simple_delete_list(privacy_lists)
	privacy_lists.default = nil;
	privacy_lists.lists["simple"] = nil;
end

local function simple_add_entry(privacy_lists, jid)
	local list = privacy_lists.lists.simple.items;
	t_insert(list, {
		action = "deny", type = "jid", value = jid, order = tostring(#list+1)
	});
end

local function simple_delete_entry(privacy_lists, jid)
	local list = privacy_lists.lists.simple.items;
	for i = 1, #list do
		if list[i].value == jid then
			t_remove(list, i);
			break;
		end
	end
end

local function simple_process_entries(block)
		local entries = {};

		for item in block:childtags() do
			local jid = item.attr.jid;
			if not jid then	return nil; end
			
			t_insert(entries, item.attr.jid);
		end
		
		return entries;
end

local function simple_generate_stanza(stanza, entries, payload)
		stanza:tag(payload, { xmlns = blocking_xmlns });
		if entries then
			for _, jid in ipairs(entries) do stanza:tag("item", { jid = jid }):up(); end
		end
		stanza:up();
		
		return stanza;
end

local function simple_push_entries(self_bare, self_resource, payload, entries)
		local push = simple_generate_stanza(st.iq({ type = "set", id = "simple-blocking-cmd-push" }), entries, payload);
		
		for resource, session in pairs(bare_sessions[self_bare].sessions) do
			if resource ~= self_resource then
				push.attr.to = session.full_jid;
				session.send(push);
			end
		end
end

local function simple_reorder_list(privacy_lists)
	local simple_list = privacy_lists.lists.simple;
	if simple_list then
		local items = simple_list.items;
		for i = 1, #items do items[i].order = i; end
	end
end

-- Stanza Handlers

local function check_stanza(e, session)
	local origin, stanza = e.origin, e.stanza;
	local privacy_lists = datamanager.load(session.username, session.host, "privacy") or {};
	local session_username, session_host = session.username, session.host;
	local bare_jid = session_username.."@"..session_host;
	local to = stanza.attr.to or bare_jid;
	local from = stanza.attr.from;
	
	local is_to_user = bare_jid == jid_bare(to);
	local is_from_user = bare_jid == jid_bare(from);
	
	if privacy_lists.lists == nil or 
	   not (session.active_privacylist or privacy_lists.default) then
		return; -- Nothing to block, default is Allow all
	end
	if is_from_user and is_to_user then
		return; -- from one of a user's resource to another => HANDS OFF!
	end
	
	local listname = session.active_privacylist;
	if listname == nil then
		listname = privacy_lists.default; -- no active list selected, use default list
	end
	local list = privacy_lists.lists[listname];
	if not list then -- should never happen
		module:log("warn", "given privacy list not found. name: %s for user %s", listname, bare_jid);
		return;
	end
	for _, item in ipairs(list.items) do
		local apply = false;
		local block = false;
		if ((stanza.name == "message" and item.message) or
		    (stanza.name == "iq" and item.iq) or
		    (stanza.name == "presence" and is_to_user and item["presence-in"]) or
		    (stanza.name == "presence" and is_from_user and item["presence-out"]) or
		    (item.message == false and item.iq == false and item["presence-in"] == false and item["presence-out"] == false)) then
			apply = true;
		end
		if apply then
			local node, host, resource;
			apply = false;
			if is_to_user then
				node, host, resource = jid_split(from);
			else
				node, host, resource = jid_split(to);
			end
			if item.type == "jid" and
			   (node and host and resource and item.value == node.."@"..host.."/"..resource) or
			   (node and host and item.value == node.."@"..host) or
			   (host and resource and item.value == host.."/"..resource) or
			   (host and item.value == host) then
				apply = true;
				block = (item.action == "deny");
			elseif item.type == "group" then
				local roster = rostermanager.load_roster(session_username, session_host);
				local roster_entry = roster[jid_join(node, host)] or 
						     rostermanager.get_readonly_item(session_username, session_host, jid_join(node, host));
				if roster_entry then
					local groups = roster_entry.groups;
					for group in pairs(groups) do
						if group == item.value then
							apply = true;
							block = (item.action == "deny");
							break;
						end
					end
				end
			elseif item.type == "subscription" then -- we need a valid bare evil jid
				local roster = rostermanager.load_roster(session_username, session_host);
				local roster_entry = roster[jid_join(node, host)] or 
						     rostermanager.get_readonly_item(session_username, session_host, jid_join(node, host));
				if (not(roster_entry) and item.value == "none")
				   or (roster_entry and roster_entry.subscription == item.value) then
					apply = true;
					block = (item.action == "deny");
				end
			elseif item.type == nil then
				apply = true;
				block = (item.action == "deny");
			end
		end
		if apply then
			if block then
				module:log("debug", "stanza blocked: %s, to: %s, from: %s", tostring(stanza.name), tostring(to), tostring(from));
				if stanza.name == "message" and stanza.attr.type ~= "groupchat" then
					local reply = st.error_reply(stanza, "cancel", "not-acceptable");
					reply:child_with_name("error"):tag("blocked", { xmlns = blocking_xmlns..":errors" }):up();
					origin.send(reply);
				elseif stanza.name == "iq" and (stanza.attr.type == "get" or stanza.attr.type == "set") then
					origin.send(st.error_reply(stanza, "cancel", "service-unavailable"));
				end
				return true; -- stanza blocked !
			else
				return;
			end
		end
	end
end

local function stanza_check_incoming(e)
	local session;
	if e.stanza.attr.to then
		local node, host, resource = jid_split(e.stanza.attr.to);
		if node == nil or host == nil then
			return;
		end
		if resource == nil then
			local prio = 0;
			if bare_sessions[node.."@"..host] then
				for resource, session_ in pairs(bare_sessions[node.."@"..host].sessions) do
					if session_.priority and session_.priority > prio then
						session = session_;
						prio = session_.priority;
					end
				end
			end
		else
			session = full_sessions[node.."@"..host.."/"..resource];
		end
		if session then
			return check_stanza(e, session);
		end
	end
end

local function stanza_check_outgoing(e)
	local session = e.origin;
	if e.stanza.attr.from == nil then
		e.stanza.attr.from = session.username.."@".. session.host;
		if session.resource then
		 	e.stanza.attr.from = e.stanza.attr.from.."/".. session.resource;
		end
	end
	if session.username then
		return check_stanza(e, session);
	end
end

local _M = {};
_M.priv_decline_list = priv_decline_list;
_M.priv_activate_list = priv_activate_list;
_M.priv_delete_list = priv_delete_list;
_M.priv_create_list = priv_create_list;
_M.priv_get_list = priv_get_list;
_M.simple_create_list = simple_create_list;
_M.simple_delete_list = simple_delete_list;
_M.simple_add_entry = simple_add_entry;
_M.simple_delete_entry = simple_delete_entry;
_M.simple_process_entries = simple_process_entries;
_M.simple_generate_stanza = simple_generate_stanza;
_M.simple_push_entries = simple_push_entries;
_M.simple_reorder_list = simple_reorder_list;
_M.stanza_check_incoming = stanza_check_incoming;
_M.stanza_check_outgoing = stanza_check_outgoing;

return _M;