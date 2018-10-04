-- * Metronome IM *
--
-- This file is part of the Metronome XMPP server and is released under the
-- ISC License, please see the LICENSE file in this source package for more
-- information about copyright and licensing.

-- This module is a simplified port of mod_seclabels from Prosody Modules
-- and implements the server catalog for Security Labels (XEP-0258).

module:set_global();

local clone = require "util.auxiliary".clone_table;
local st = require "util.stanza";
local uuid = require "util.uuid".generate;
local section = require "util.jid".section;
local fire_event = metronome.events.fire_event;
local ipairs, pairs, type, t_remove = ipairs, pairs, type, table.remove;

local hosts = hosts;

local label_xmlns = "urn:xmpp:sec-label:0";
local label_catalog_xmlns = "urn:xmpp:sec-label:catalog:2";

local function actions_parser(buffer, s, loop)
	if not loop then
		buffer[s.name] = s.restrict;
	else
		for name, label in pairs(s) do buffer[name] = label.restrict; end
	end
	return buffer;
end

local function boot_module(config, unclassified_default)
	local _config = clone(config);
	local labels = {};
	local has_default;
	for i, label in ipairs(_config) do
		if label.default and not has_default then
			has_default = t_remove(_config, i);
		elseif label.default and has_default then
			t_remove(_config, i);
		end
	end
	labels[1] = has_default or unclassified_default;
	for i, label in ipairs(_config) do labels[i + 1] = label; end
	for selector, _labels in pairs(_config) do
		if type(selector) == "string" then labels[selector] = _labels; end
	end

	local buffer = {};
	for k, label in ipairs(labels) do actions_parser(buffer, label); end
	for k, selector in pairs(labels) do
		if type(k) == "string" then actions_parser(buffer, selector, true); end
	end

	return labels, buffer;
end

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

local function handle_catalog_request(event, config, my_host)
	local origin, stanza = event.origin, event.stanza;
	local catalog_request = stanza.tags[1];
	local host = section(catalog_request.attr.to, "host");
	
	if catalog_request.attr.to and host ~= my_host then
		if module:host_is_muc(my_host) then
			origin.send(st.error_reply(stanza, "cancel", "not-allowed", "This entity can't query remote catalogs"));
		end

		if origin.type ~= "c2s" then
			origin.send(st.error_reply(stanza, "cancel", "forbidden", "Remote catalogs can't be requested by remote entities"));
			return true;
		end

		local catalog_request_clone = st.clone(catalog_request);
		local id = uuid();
		local iq = st.iq({ from = my_host, to = catalog_request.attr.to, id = id, type = "get" }):add_child(catalog_request_clone);
		server_requests[id] = { to = stanza.attr.from, stanza = stanza, session = origin };
		fire_event("route/post", hosts[my_host], iq);
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
				name = config.catalog_name,
				desc = config.catalog_desc
			});

		add_labels(catalog_request, reply, config.labels, "");
		fire_event("route/post", hosts[my_host], reply);
		return true;
	end
end

function module.add_host(module)
	module:set_component_inheritable();
	module:depends("acdf");

	if module:host_is_component() and not module:host_is_muc() then
		modulemanager.unload(module.host, "sec_labels");
		modulemanager.unload(module.host, "acdf");
	end

	module:add_feature(label_xmlns);
	module:add_feature(label_catalog_xmlns);

	local host_object = module:get_host_session();

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
			LOCAL = {
				color = "black", bgcolor = "magenta", label = "Only for "..module.host,
				restrict = { host = { module.host } }
			}
		}
	};

	local default_muc_labels = {
		Classified = {
			MODERATORS = {
				color = "black", bgcolor = "skyblue", label = "Just for moderators",
				restrict = { muc_callback = "affiliation", response = { "admin", "owner" } }
			},
			MEMBERS = {
				color = "black", bgcolor = "aliceblue", label = "Just for members",
				restrict = { muc_callback = "affiliation", response = { "admin", "owner", "member" } }
			},
			PRIVATE = {
				color = "black", bgcolor = "turquoise", label = "Only for groupchats",
				restrict = { type = "chat" }
			},
			PUBLIC = {
				color = "black", bgcolor = "mediumaquamarine", label = "Only for groupchats",
				restrict = { type = "groupchat" }
			}
		}
	};

	local catalog_name = module:get_option_string("security_catalog_name", "Default");
	local catalog_desc = module:get_option_string("security_catalog_desc", "Default Labels");
	local config_labels = module:get_option_table("security_labels",
		host_object.muc and default_muc_labels or default_labels
	);

	local labels, actions = boot_module(config_labels, unclassified_default);
	local config = { catalog_name = catalog_name, catalog_desc = catalog_desc, labels = labels };

	module:hook("iq/host", handle_server_catalog_response);
	module:hook("iq-get/host/"..label_catalog_xmlns..":catalog", function(event)
		return handle_catalog_request(event, config, module.host, server_requests);
	end);
	module:hook("iq-get/bare/"..label_catalog_xmlns..":catalog", function(event)
		return handle_catalog_request(event, config, module.host, server_requests);
	end);
	if host_object.muc then
		module:hook("iq/full", function(event)
			if event.stanza.attr.type ~= "get" then return; end
			local catalog = event.stanza.tags[1];
			if catalog and catalog.name == "catalog" and catalog.attr.xmlns == label_catalog_xmlns then
				return handle_catalog_request(event, config, module.host, server_requests);
			end
		end);
	end
	module:hook("sec-labels-fetch-actions", function(label)
		return actions[label];
	end);
end
