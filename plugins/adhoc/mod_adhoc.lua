-- * Metronome IM *
--
-- This file is part of the Metronome XMPP server and is released under the
-- ISC License, please see the LICENSE file in this source package for more
-- information about copyright and licensing.
--
-- As per the sublicensing clause, this file is also MIT/X11 Licensed.
-- ** Copyright (c) 2010-2012, Florian Zeitz, Matthew Wild

local st = require "util.stanza";
local is_admin = require "core.usermanager".is_admin;
local adhoc_handle_cmd = module:require "adhoc".handle_cmd;
local section = require "util.jid".section;
local xmlns_cmd = "http://jabber.org/protocol/commands";
local xmlns_disco = "http://jabber.org/protocol/disco";
local ipairs, t_insert, t_remove = ipairs, table.insert, table.remove;
local commands = {};
local commands_order = {};

local hosts = hosts;

module:add_feature(xmlns_cmd);

module:hook("iq/host/"..xmlns_disco.."#info:query", function (event)
	local origin, stanza = event.origin, event.stanza;
	local node = stanza.tags[1].attr.node;
	if stanza.attr.type == "get" and node then
		if commands[node] then
			local privileged = is_admin(stanza.attr.from, stanza.attr.to);
			local local_user = section(stanza.attr.from or origin.host, "host") == module.host;
			local server_user = hosts[section(stanza.attr.from or origin.host, "host")];
			if (commands[node].permission == "admin" and privileged)
				or (commands[node].permission == "local_user" and local_user)
				or (commands[node].permission == "server_user" and server_user)
				or (commands[node].permission == "user") then
				reply = st.reply(stanza);
				reply:tag("query", { xmlns = xmlns_disco.."#info",
				    node = node });
				reply:tag("identity", { name = commands[node].name,
				    category = "automation", type = "command-node" }):up();
				reply:tag("feature", { var = xmlns_cmd }):up();
				reply:tag("feature", { var = "jabber:x:data" }):up();
			else
				reply = st.error_reply(stanza, "auth", "forbidden", "This item is not available to you");
			end
			origin.send(reply);
			return true;
		elseif node == xmlns_cmd then
			reply = st.reply(stanza);
			reply:tag("query", { xmlns = xmlns_disco.."#info",
			    node = node });
			reply:tag("identity", { name = "Ad-Hoc Commands",
			    category = "automation", type = "command-list" }):up();
			origin.send(reply);
			return true;

		end
	end
end);

module:hook("iq/host/"..xmlns_disco.."#items:query", function (event)
	local origin, stanza = event.origin, event.stanza;
	if stanza.attr.type == "get" and stanza.tags[1].attr.node
	    and stanza.tags[1].attr.node == xmlns_cmd then
		local local_user = section(stanza.attr.from or origin.host, "host") == module.host;
		local server_user = hosts[section(stanza.attr.from or origin.host, "host")];
		local admin = is_admin(stanza.attr.from, stanza.attr.to);
		local global_admin = is_admin(stanza.attr.from);
		reply = st.reply(stanza);
		reply:tag("query", { xmlns = xmlns_disco.."#items",
		    node = xmlns_cmd });
		local command;
		for i, node in ipairs(commands_order) do
			command = commands[node];
			if (command.permission == "admin" and admin)
				or (command.permission == "global_admin" and global_admin)
				or (command.permission == "local_user" and local_user)
				or (command.permission == "server_user" and server_user)
				or (command.permission == "user") then
				reply:tag("item", { name = command.name,
				    node = node, jid = module:get_host() });
				reply:up();
			end
		end
		origin.send(reply);
		return true;
	end
end, 500);

module:hook("iq/host/"..xmlns_cmd..":command", function (event)
	local origin, stanza = event.origin, event.stanza;
	if stanza.attr.type == "set" then
		local node = stanza.tags[1].attr.node
		if commands[node] then
			local local_user = section(stanza.attr.from or origin.host, "host") == module.host;
			local server_user = hosts[section(stanza.attr.from or origin.host, "host")];
			local admin = is_admin(stanza.attr.from, stanza.attr.to);
			local global_admin = is_admin(stanza.attr.from);
			if (commands[node].permission == "admin" and not admin)
				or (commands[node].permission == "global_admin" and not global_admin)
				or (commands[node].permission == "local_user" and not local_user)
				or (commands[node].permission == "server_user" and not server_user) then
				origin.send(st.error_reply(stanza, "auth", "forbidden", "You don't have permission to execute this command"):up()
				    :add_child(commands[node]:cmdtag("canceled")
					:tag("note", {type="error"}):text("You don't have permission to execute this command")));
				return true;
			end
			-- User has permission now execute the command
			return adhoc_handle_cmd(commands[node], origin, stanza);
		end
	end
end, 500);

local function adhoc_added(event)
	local item = event.item;
	commands[item.node] = item;
	t_insert(commands_order, item.node);
end

local function adhoc_removed(event)
	local item = event.item;
	commands[item.node] = nil;
	for i, node in ipairs(commands_order) do
		if node == item.node then t_remove(commands_order, i); end
	end
end

module:handle_items("adhoc", adhoc_added, adhoc_removed);
module:handle_items("adhoc-provider", adhoc_added, adhoc_removed);
