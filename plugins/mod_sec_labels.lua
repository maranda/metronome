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
local split = require "util.jid".split;
local fire_event = metronome.events.fire_event;
local ipairs, pairs, type = ipairs, pairs, type;

local label_xmlns = "urn:xmpp:sec-label:0";
local label_catalog_xmlns = "urn:xmpp:sec-label:catalog:2";

module:add_feature(label_xmlns);
module:add_feature(label_catalog_xmlns);

local default_labels = {
	{
		name = "Unclassified",
		label = true,
		default = true,
		restrict = "none"
	},
	Classified = {
		SECRET = { 
			color = "white", bgcolor = "blue", label = "CONFIDENTIAL",
			restrict = { type = "chat" }
		},
		PUBLIC = { 
			color = "black", bgcolor = "aqua", label = "PUBLIC",
			restrict = "none"
		}
	}
};
local catalog_name = module:get_option_string("security_catalog_name", "Default");
local catalog_desc = module:get_option_string("security_catalog_desc", "Default Labels");
local labels = module:get_option("security_labels", default_labels);

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
				}):text(item.display or name):up();
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
		local server_request = server_requests[id];
		if not server_request.session.destroyed then
			local reply = st.reply(server_request.stanza):add_child(catalog):up();
			server_request.session.send(reply);
		end
		server_requests[id] = nil;
		return true;
	end
end

local function handle_catalog_request(request)
	local catalog_request = request.stanza.tags[1];
	if catalog_request.attr.to and catalog_request.attr.to ~= module.host then
		local node = split(catalog_request.attr.to);
		if node then
			request.origin.send(st.error_reply(stanza, "cancel", "not-acceptable", "Catalogs can only be requested from hosts"));
			return true;
		end

		local catalog_request_clone = st.clone(catalog_request);
		local id = uuid();
		local iq = st.iq({ from = module.host, to = catalog_request.attr.to, id = id, type = "get" }):add_child(catalog_request_clone);
		fire_event("route/local", hosts[module.host], iq);
		server_requests[id] = { to = request.stanza.attr.from, stanza = request.stanza, session = request.origin };
		module:add_timer(20, function()
			local server_request = server_requests[id];
			if server_request and not server_request.session.destroyed then
				server_request.session.send(st.error_reply(request.stanza, "cancel", "item-not-found", "Remote catalog not found"));
				server_requests[id] = nil;
			else
				server_requests[id] = nil;
			end
		end);
		return true;
	else
		local reply = st.reply(request.stanza)
			:tag("catalog", {
				xmlns = catalog_request.attr.xmlns,
				to = catalog_request.attr.to,
				name = catalog_name,
				desc = catalog_desc
			});

		add_labels(catalog_request, reply, labels, "");
		request.origin.send(reply);
		return true;
	end
end

module:hook("iq/host", handle_server_catalog_response);
module:hook("iq/host/"..label_catalog_xmlns..":catalog", handle_catalog_request);
module:hook("sec-labels-fetch-actions", handle_get_actions);
