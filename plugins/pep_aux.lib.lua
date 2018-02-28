-- * Metronome IM *
--
-- This file is part of the Metronome XMPP server and is released under the
-- ISC License, please see the LICENSE file in this source package for more
-- information about copyright and licensing.

-- Objects and Functions for mod_pep.

local log = require "util.logger".init("mod_pep");
local jid_bare = require "util.jid".bare;
local jid_split = require "util.jid".split;
local set_new = require "util.set".new;
local st = require "util.stanza";
local is_contact_subscribed = require "util.rostermanager".is_contact_subscribed;
local dataforms = require "util.dataforms";
local encode_node = datamanager.path_encode;
local um_is_admin = usermanager.is_admin;
local fire_event = metronome.events.fire_event;
local bare_sessions = bare_sessions;

local xmlns_pubsub_errors = "http://jabber.org/protocol/pubsub#errors";
local xmlns_pubsub_event = "http://jabber.org/protocol/pubsub#event";

local hash_map, services;

local features = {
	"http://jabber.org/protocol/pubsub#access-presence",
	"http://jabber.org/protocol/pubsub#auto-create",
	"http://jabber.org/protocol/pubsub#create-and-configure",
	"http://jabber.org/protocol/pubsub#create-nodes",
	"http://jabber.org/protocol/pubsub#config-node",
	"http://jabber.org/protocol/pubsub#delete-items",
	"http://jabber.org/protocol/pubsub#delete-nodes",
	"http://jabber.org/protocol/pubsub#filtered-notifications",
	"http://jabber.org/protocol/pubsub#meta-data",
	"http://jabber.org/protocol/pubsub#persistent-items",
	"http://jabber.org/protocol/pubsub#publish",
	"http://jabber.org/protocol/pubsub#publish-options",
	"http://jabber.org/protocol/pubsub#purge-nodes",
	"http://jabber.org/protocol/pubsub#retrieve-items"
};

local singleton_nodes = set_new{ 
	"http://jabber.org/protocol/activity",
	"http://jabber.org/protocol/geoloc",
	"http://jabber.org/protocol/mood",
	"http://jabber.org/protocol/tune",
	"urn:xmpp:avatar:data",
	"urn:xmpp:avatar:metadata",
	"urn:xmpp:chatting:0",
	"urn:xmpp:browsing:0",
	"urn:xmpp:gaming:0",
	"urn:xmpp:viewing:0"
};

local pep_errors = {
	["conflict"] = { "cancel", "conflict" };
	["invalid-jid"] = { "modify", "bad-request", nil, "invalid-jid" };
	["item-not-found"] = { "cancel", "item-not-found" };
	["feature-not-implemented"] = { "cancel", "feature-not-implemented" };
	["forbidden"] = { "cancel", "forbidden" };
	["not-subscribed"] = { "modify", "unexpected-request", nil, "not-subscribed" };
	["bad-request"] = { "cancel", "bad-request" };
	["precondition-not-met"] = { "cancel", "conflict", nil, "precondition-not-met"}
};

-- Functions

local function set_closures(s, h)
	services = s; hash_map = h;
end

local function pep_error_reply(stanza, error)
	local e = pep_errors[error];
	local reply = st.error_reply(stanza, unpack(e, 1, 3));
	if e[4] then
		reply:tag(e[4], { xmlns = xmlns_pubsub_errors }):up();
	end
	return reply;
end

local function subscription_presence(user_bare, recipient)
	local recipient_bare = jid_bare(recipient);
	if (recipient_bare == user_bare) then return true; end
	local username, host = jid_split(user_bare);
	return is_contact_subscribed(username, host, recipient_bare);
end

local function get_caps_hash_from_presence(stanza)
	local t = stanza.attr.type;
	if not t then
		for _, child in pairs(stanza.tags) do
			if child.name == "c" and child.attr.xmlns == "http://jabber.org/protocol/caps" then
				local attr = child.attr;
				if attr.hash then -- new caps
					if attr.hash == "sha-1" and attr.node and attr.ver then return attr.ver, attr.node.."#"..attr.ver; end
				else -- legacy caps
					if attr.node and attr.ver then return attr.node.."#"..attr.ver.."#"..(attr.ext or ""), attr.node.."#"..attr.ver; end
				end
				return; -- bad caps format
			end
		end
	elseif t == "unavailable" or t == "error" then
		return;
	end
end

local function pep_broadcast_last(service, node, receiver)
	local ok, items, orderly = service:get_items(node, receiver, nil, 1);
	if ok and items then
		for _, id in ipairs(orderly) do
			service:broadcaster(node, receiver, items[id]);
		end
	end
end

local function pep_mutual_recs(source, target, interested)
	for jid, hash in pairs(source.recipients) do
		if jid_bare(jid) == source.name and type(hash) == "string" then
			interested[jid] = hash;
		end
	end
	for jid, hash in pairs(target.recipients) do
		if jid_bare(jid) == target.name and type(hash) == "string" then
			interested[jid] = hash;
		end
	end
end

local function mutually_sub(service, jid, hash, nodes)
	for node, obj in pairs(nodes) do
		if hash_map[hash] and hash_map[hash][node] and service:get_affiliation(jid, node) ~= "no_access" then
			obj.subscribers[jid] = true; 
		end
	end
end

local function pep_send(recipient, user)
	local rec_srv = services[jid_bare(recipient)];
	local user_srv = services[user];
	local nodes = user_srv.nodes;

	if not rec_srv then
		local rec_hash = user_srv.recipients[recipient];
		for node, object in pairs(nodes) do
			if hash_map[rec_hash] and hash_map[rec_hash][node] then
				object.subscribers[recipient] = true;
				pep_broadcast_last(user_srv, node, recipient);
			end
		end
	else
		local rec_nodes = rec_srv.nodes;
		local interested = {};
		pep_mutual_recs(user_srv, rec_srv, interested);

		-- Mutually subscribe
		for jid, hash in pairs(interested) do
			mutually_sub(user_srv, jid, hash, rec_nodes);
			mutually_sub(rec_srv, jid, hash, nodes);
		end

		for node in pairs(nodes) do
			pep_broadcast_last(user_srv, node, recipient);
		end
	end
end

local function pep_autosubscribe_recs(service, node)
	local recipients = service.recipients;
	local _node = service.nodes[node];
	if not _node then return; end

	for jid, hash in pairs(recipients) do
		if type(hash) == "string" and hash_map[hash] and hash_map[hash][node] then
			if service:get_affiliation(jid, node) ~= "no_access" then
				_node.subscribers[jid] = true;
			end
		end
	end
end

local function config_form_layout(service, name)
	local c_name = "Node configuration for "..name;
	local node = service.nodes[name];

	return dataforms.new({
		title = c_name,
		instructions = c_name,
		{
			name = "FORM_TYPE",
			type = "hidden",
			value = "http://jabber.org/protocol/pubsub#node_config"
		},
		{
			name = "pubsub#title",
			type = "text-single",
			label = "A friendly name for this node (optional)",
			value = node.config.title or ""
		},
		{
			name = "pubsub#description",
			type = "text-single",
			label = "A description for this node (optional)",
			value = node.config.description or ""
		},
		{
			name = "pubsub#type",
			type = "text-single",
			label = "The data type of this node (optional)",
			value = node.config.type or ""
		},
		{
			name = "pubsub#max_items",
			type = "text-single",
			label = "Max number of items to persist",
			value = type(node.config.max_items) == "number" and tostring(node.config.max_items) or "0"
		},
		{
			name = "pubsub#persist_items",
			type = "boolean",
			label = "Whether to persist items to storage or not",
			value = node.config.persist_items or false
		},
		{
			name = "pubsub#access_model",
			type = "list-single",
			label = "Access Model for the node, currently supported models are presence, open and whitelist",
			value = {
				{ value = "presence", default = (node.config.access_model == "presence" or node.config.access_model == nil) and true },
				{ value = "open", default = node.config.access_model == "open" and true },
				{ value = "whitelist", default = node.config.access_model == "whitelist" and true }
			}
		},
		{
			name = "pubsub#publish_model",
			type = "list-single",
			label = "Publisher Model for the node, currently supported models are publishers and open",
			value = {
				{ value = "publishers", default = (node.config.publish_model == "publishers" or node.config.publish_model == nil) and true },
				{ value = "open", default = node.config.publish_model == "open" and true }
			}
		}				
	});
end

local function send_config_form(service, name, origin, stanza)
	return origin.send(st.reply(stanza)
		:tag("pubsub", { xmlns = "http://jabber.org/protocol/pubsub#owner" })
			:tag("configure", { node = name })
				:add_child(config_form_layout(service, name):form()):up()
	);
end

local function process_config_form(service, name, form, new)
	local node_config, node;
	if new then
		node_config = {};
	else
		node = service.nodes[name];
		if not node then return false, "item-not-found"; end
		node_config = node.config;
	end

	if not form or form.attr.type ~= "submit" or #form.tags == 0 then return false, "bad-request"; end

	for _, field in ipairs(form.tags) do
		local value = field:get_child_text("value");
		if field.attr.var == "pubsub#title" then
			node_config.title = (value ~= "" and value) or nil;
		elseif field.attr.var == "pubsub#description" then
			node_config.description = (value ~= "" and value) or nil;
		elseif field.attr.var == "pubsub#type" then
			node_config.type = (value ~= "" and value) or nil;
		elseif field.attr.var == "pubsub#max_items" then
			node_config.max_items = tonumber(value) or 20;
		elseif field.attr.var == "pubsub#persist_items" then
			node_config.persist_items = ((value == 0 or value == "false") and false) or ((value == "1" or value == "true") and true);
		elseif field.attr.var == "pubsub#access_model" then
			if value == "presence" or value == "open" or value == "whitelist" then node_config.access_model = value; end
		elseif field.attr.var == "pubsub#publish_model" then
			if value == "publishers" or value == "open" then node_config.publish_model = value; end
		end
	end

	if new then return true, node_config; end

	service:save_node(name);
	service:save();
	return true;
end

local function options_form_layout(service, name)
	local c_name = "Node publish options for "..name;
	local node = service.nodes[name];

	return dataforms.new({
		title = c_name,
		instructions = c_name,
		{
			name = "FORM_TYPE",
			type = "hidden",
			value = "http://jabber.org/protocol/pubsub#publish-options"
		},
		{
			name = "pubsub#max_items",
			type = "text-single",
			label = "Precondition: Max number of items to persist",
			value = type(node.config.max_items) == "number" and tostring(node.config.max_items) or "0"
		},
		{
			name = "pubsub#persist_items",
			type = "boolean",
			label = "Precondition: Whether to persist items to storage or not",
			value = node.config.persist_items or false
		},
		{
			name = "pubsub#access_model",
			type = "list-single",
			label = "Precondition: Access Model for the node, currently supported models are presence, open and whitelist",
			value = {
				{ value = "presence", default = (node.config.access_model == "presence" or node.config.access_model == nil) and true },
				{ value = "open", default = node.config.access_model == "open" and true },
				{ value = "whitelist", default = node.config.access_model == "whitelist" and true }
			}
		},
		{
			name = "pubsub#publish_model",
			type = "list-single",
			label = "Precondition: Publisher Model for the node, currently supported models are publishers and open",
			value = {
				{ value = "publishers", default = (node.config.publish_model == "publishers" or node.config.publish_model == nil) and true },
				{ value = "open", default = node.config.publish_model == "open" and true }
			}
		}
	});
end

local function send_options_form(service, name, origin, stanza)
	return origin.send(st.reply(stanza)
		:tag("pubsub", { xmlns = "http://jabber.org/protocol/pubsub" })
			:tag("publish-options", { node = name })
				:add_child(options_form_layout(service, name):form()):up()
	);
end

local function process_options_form(service, name, form)
	local node_config, node;
	node_config = {};
	node = service.nodes[name];

	if not form or form.attr.type ~= "submit" or #form.tags == 0 then return false, "bad-request"; end

	for _, field in ipairs(form.tags) do
		local value = field:get_child_text("value");
		if field.attr.var == "pubsub#max_items" then
			node_config.max_items = tonumber(value) or 20;
		elseif field.attr.var == "pubsub#persist_items" then
			node_config.persist_items = ((value == 0 or value == "false") and false) or ((value == "1" or value == "true") and true);
		elseif field.attr.var == "pubsub#access_model" then
			if value == "presence" or value == "open" or value == "whitelist" then node_config.access_model = value; end
		elseif field.attr.var == "pubsub#publish_model" then
			if value == "publishers" or value == "open" then node_config.publish_model = value; end
		end
	end

	if node then -- just compare that publish-options match configuration
		local config = node.config;
		for option, value in pairs(node_config) do
			if config[option] ~= value then return false, "precondition-not-met"; end
		end
	end
	
	return true, node_config;
end

local function send_event(self, node, message, jid)
	local subscribers = self.nodes[node].subscribers;
	if subscribers[jid] then
		log("debug", "%s -- service sending %s notification to %s", self.name, node, jid);
		message.attr.to = jid; fire_event("route/post", self.session, message);
	end
end

local function broadcast(self, node, jids, item)
	if self.is_new then return; end -- don't broadcast just yet.

	local message;
	if type(item) == "string" and item == "deleted" then
		message = st.message({ from = self.name, type = "headline" })
			:tag("event", { xmlns = xmlns_pubsub_event })
				:tag("deleted", { node = node });
	elseif type(item) == "string" and item == "purged" then
		message = st.message({ from = self.name, type = "headline" })
			:tag("event", { xmlns = xmlns_pubsub_event })
				:tag("purged", { node = node });
	else
		message = st.message({ from = self.name, type = "headline" })
			:tag("event", { xmlns = xmlns_pubsub_event })
				:tag("items", { node = node });
		
		if item then
			item = st.clone(item);
			item.attr.xmlns = nil; -- Clear pubsub ns
			message:get_child("event", xmlns_pubsub_event):get_child("items"):add_child(item);
		end
	end

	if type(jids) == "table" then
		for jid in pairs(jids) do send_event(self, node, message, jid); end
	else send_event(self, node, message, jids); end
end

local function get_affiliation(self, jid, node)
	local bare_jid = jid_bare(jid);
	if bare_jid == self.name or um_is_admin(bare_jid, module.host) then
		return "owner";
	else
		local node = self.nodes[node];
		local access_model = node and node.config.access_model;
		if node and (not access_model or access_model == "presence") then
			local user, host = jid_split(self.name);
			if not is_contact_subscribed(user, host, bare_jid) then return "no_access"; end
		elseif node and access_model == "whitelist" then
			return "no_access";
		end
			
		return "none";
	end
end

local function pep_new(node)
	local encoded_node = encode_node(node);

	local new_service = {
			capabilities = {
				no_access = {
					create = false;
					delete = false;
					publish = false;
					purge = false;
					retract = false;
					get_nodes = false;

					subscribe = false;
					unsubscribe = false;
					get_subscription = false;
					get_subscriptions = false;
					get_items = false;

					subscribe_other = false;
					unsubscribe_other = false;
					get_subscription_other = false;
					get_subscriptions_other = false;

					be_subscribed = false;
					be_unsubscribed = false;

					set_affiliation = false;

					dummy = true;
				};
				none = {
					create = false;
					delete = false;
					publish = false;
					purge = false;
					retract = false;
					get_nodes = true;

					subscribe = false;
					unsubscribe = true;
					get_subscription = true;
					get_subscriptions = true;
					get_items = true;

					subscribe_other = false;
					unsubscribe_other = false;
					get_subscription_other = false;
					get_subscriptions_other = false;

					be_subscribed = true;
					be_unsubscribed = true;

					set_affiliation = false;
				};
				publisher = {
					create = false;
					delete = false;
					publish = true;
					purge = false;
					retract = true;
					get_nodes = true;

					subscribe = true;
					unsubscribe = true;
					get_subscription = true;
					get_subscriptions = true;
					get_items = true;

					subscribe_other = false;
					unsubscribe_other = false;
					get_subscription_other = false;
					get_subscriptions_other = false;

					be_subscribed = true;
					be_unsubscribed = true;

					set_affiliation = false;
				};
				owner = {
					create = true;
					delete = true;
					publish = true;
					purge = true;
					retract = true;
					get_nodes = true;

					subscribe = true;
					unsubscribe = true;
					get_subscription = true;
					get_subscriptions = true;
					get_items = true;

					subscribe_other = true;
					unsubscribe_other = true;
					get_subscription_other = true;
					get_subscriptions_other = true;

					be_subscribed = true;
					be_unsubscribed = true;

					set_affiliation = true;
				};
			};

			node_default_config = {
				max_items = 20;
			};

			autocreate_on_publish = true;

			broadcaster = broadcast;
			get_affiliation = get_affiliation;

			normalize_jid = jid_bare;

			store = storagemanager.open(module.host, "pep/"..encoded_node);
		};

	return new_service;
end

return {
	features = features,
	singleton_nodes = singleton_nodes,
	set_closures = set_closures,
	pep_error_reply = pep_error_reply,
	subscription_presence = subscription_presence,
	get_caps_hash_from_presence = get_caps_hash_from_presence,
	pep_send = pep_send,
	pep_autosubscribe_recs = pep_autosubscribe_recs,
	send_config_form = send_config_form;
	process_config_form = process_config_form;
	send_options_form = send_options_form;
	process_options_form = process_options_form;
	pep_new = pep_new
};
