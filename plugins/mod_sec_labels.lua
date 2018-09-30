-- * Metronome IM *
--
-- This file is part of the Metronome XMPP server and is released under the
-- ISC License, please see the LICENSE file in this source package for more
-- information about copyright and licensing.

-- This module is a simplified port of mod_seclabels from Prosody Modules
-- and implements the server catalog for Security Labels (XEP-0258).

module:depends("acdf");

local st = require "util.stanza";
local uuid = require "util.uuid".generate;
local section = require "util.jid".section;
local fire_event = metronome.events.fire_event;
local ipairs, pairs, type, t_remove = ipairs, pairs, type, table.remove;

local hosts = hosts;

local label_xmlns = "urn:xmpp:sec-label:0";
local label_catalog_xmlns = "urn:xmpp:sec-label:catalog:2";

module:add_feature(label_xmlns);
module:add_feature(label_catalog_xmlns);

local unclassified_default = {
		name = "Unclassified",
		label = true,
		default = true,
		restrict = "none"
};

local default_labels = {
	Classified = {
		SECRET = {
			color = "white", bgcolor = "blue", label = "Confidential",
			restrict = { type = "chat" }
		},
		CONTACTS = {
			color = "black", bgcolor = "cadetblue", label = "Just for contacts",
			restrict = "roster"
		},
		PUBLIC = {
			color = "black", bgcolor = "aqua", label = "Public",
			restrict = "none"
		},
		FORUM = {
			color = "black", bgcolor = "cornsilk", label = "Only for groupchats",
			restrict = { type = "groupchat" }
		},
		LOCAL = {
			color = "black", bgcolor = "aliceblue", label = "Only for "..module.host,
			restrict = { host = { module.host }, include_muc_subdomains = true }
		}
	}
};
local catalog_name = module:get_option_string("security_catalog_name", "Default");
local catalog_desc = module:get_option_string("security_catalog_desc", "Default Labels");
local config_labels = module:get_option_table("security_labels", default_labels);

local labels = {};
local has_default;
for i, label in ipairs(config_labels) do
	if label.default and not has_default then
		has_default = t_remove(config_labels, i);
	elseif label.default and has_default then
		t_remove(config_labels, i);
	end
end
labels[1] = has_default or unclassified_default;
for i, label in ipairs(config_labels) do labels[i + 1] = label; end
for selector, labels in pairs(config_labels) do
	if type(selector) == "string" then labels[selector] = labels; end
end

local actions_buffer = {};
local function actions_parser(s, loop)
	if not loop then
		actions_buffer[s.name] = s.restrict;
	else
		for name, label in pairs(s) do actions_buffer[name] = label.restrict; end
	end
end
for k, label in ipairs(labels) do actions_parser(label); end
for k, selector in pairs(labels) do
	if type(k) == "string" then actions_parser(selector, true); end
end

local function handle_get_actions(label_name) return actions_buffer[label_name]; end

local function add_labels(request, catalog, labels, selector)
	local function add_item(item, name)
		local name = name or item.name;
		if item.label then
			if request.attr.xmlns == label_catalog_xmlns then
				catalog:tag("item", {
					selector = selector..name,
					default = item.default and "true" or nil,
				}):tag("securitylabel", { xmlns = label_xmlns });
			end
			if item.display or item.color or item.bgcolor then
				catalog:tag("displaymarking", {
					fgcolor = item.color,
					bgcolor = item.bgcolor,
				}):text(item.name or name):up();
			end
			if item.label == true then
				catalog:tag("label"):text(name):up();
			elseif type(item.label) == "string" then
				catalog:tag("label"):text(item.label):up();
			end
			catalog:up();
			if request.attr.xmlns == label_catalog_xmlns then catalog:up(); end
		else
			add_labels(request, catalog, item, (selector or "")..name.."|");
		end
	end
	for i = 1, #labels do
		add_item(labels[i])
	end
	for name, child in pairs(labels) do
		if type(name) == "string" then
			add_item(child, name)
		end
	end
end

local server_requests = {};
local function handle_server_catalog_response(event)
	local origin, stanza = event.origin, event.stanza;
	
	if server_requests[stanza.attr.id] and stanza.attr.type == "result" then
		local catalog, id = stanza.tags[1], stanza.attr.id;
		if catalog.name ~= "catalog" and catalog.attr.xmlns ~= label_catalog_xmlns then
			return;
		end
		local server_request = server_requests[id];
		if not server_request.session.destroyed then
			local reply = st.reply(server_request.stanza):add_child(catalog):up();
			server_request.session.send(reply);
		end
		server_requests[id] = nil;
		return true;
	end
end

local function handle_catalog_request(event)
	local origin, stanza = event.origin, event.stanza;
	local catalog_request = stanza.tags[1];
	local host = section(catalog_request.attr.to, "host");
	local is_muc = hosts[host] and hosts[host].muc;
	
	if catalog_request.attr.to and host ~= module.host and not is_muc then
		if origin.type ~= "c2s" then
			origin.send(st.error_reply(stanza, "cancel", "forbidden", "Remote catalogs can't be requested by remote entities"));
			return true;
		end

		local catalog_request_clone = st.clone(catalog_request);
		local id = uuid();
		local iq = st.iq({ from = module.host, to = catalog_request.attr.to, id = id, type = "get" }):add_child(catalog_request_clone);
		fire_event("route/local", hosts[module.host], iq);
		server_requests[id] = { to = stanza.attr.from, stanza = stanza, session = origin };
		module:add_timer(20, function()
			local server_request = server_requests[id];
			if server_request and not server_request.session.destroyed then
				server_request.session.send(st.error_reply(server_request.stanza, "cancel", "item-not-found", "Remote catalog not found"));
				server_requests[id] = nil;
			else
				server_requests[id] = nil;
			end
		end);
		return true;
	else
		local reply = st.reply(stanza)
			:tag("catalog", {
				xmlns = catalog_request.attr.xmlns,
				to = catalog_request.attr.to,
				name = catalog_name,
				desc = catalog_desc
			});

		add_labels(catalog_request, reply, labels, "");
		origin.send(reply);
		return true;
	end
end

module:hook("iq/host", handle_server_catalog_response);
module:hook("iq/host/"..label_catalog_xmlns..":catalog", handle_catalog_request);
module:hook("sec-labels-fetch-actions", handle_get_actions);
