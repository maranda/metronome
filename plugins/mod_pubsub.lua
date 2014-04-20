-- * Metronome IM *
--
-- This file is part of the Metronome XMPP server and is released under the
-- ISC License, please see the LICENSE file in this source package for more
-- information about copyright and licensing.

local hosts = hosts;
local type = type;

local pubsub = require "util.pubsub";
local st = require "util.stanza";
local jid_bare, jid_section = require "util.jid".bare, require "util.jid".section;

local xmlns_pubsub = "http://jabber.org/protocol/pubsub";
local xmlns_pubsub_event = "http://jabber.org/protocol/pubsub#event";
local xmlns_pubsub_owner = "http://jabber.org/protocol/pubsub#owner";

local autocreate_on_publish = module:get_option_boolean("autocreate_on_publish", false);
local autocreate_on_subscribe = module:get_option_boolean("autocreate_on_subscribe", false);
local unrestricted_node_creation = module:get_option_boolean("unrestricted_node_creation", false);

local pubsub_disco_name = module:get_option("name");
if type(pubsub_disco_name) ~= "string" then pubsub_disco_name = "Metronome PubSub Service"; end

local service;

local pubsub_lib = module:require "pubsub_aux";
local handlers = pubsub_lib.handlers;
local handlers_owner = pubsub_lib.handlers_owner;
local pubsub_error_reply = pubsub_lib.pubsub_error_reply;
local form_layout = pubsub_lib.form_layout;
local send_config_form = pubsub_lib.send_config_form;
local process_config_form = pubsub_lib.process_config_form;

-- Begin

function handle_pubsub_iq(event)
	local origin, stanza = event.origin, event.stanza;
	local pubsub = stanza.tags[1];
	local action = pubsub.tags[1];
	if not action then return origin.send(pubsub_error_reply(stanza, "bad-request")); end
	local config = (pubsub.tags[2] and pubsub.tags[2].name == "configure") and pubsub.tags[2];
	local handler;

	if pubsub.attr.xmlns == xmlns_pubsub_owner then
		handler = handlers_owner[stanza.attr.type.."_"..action.name];
	else
		handler = handlers[stanza.attr.type.."_"..action.name];
	end

	if handler then
		if not config then 
			return handler(origin, stanza, action); 
		else 
			return handler(origin, stanza, action, config); 
		end
	else
		return origin.send(pubsub_error_reply(stanza, "feature-not-implemented"));
	end
end

function broadcast(self, node, jids, item)
	local function traverser(jids, stanza)
		for jid in pairs(jids) do
			module:log("debug", "Sending notification to %s", jid);
			stanza.attr.to = jid;
			module:send(stanza);
		end
	end

	if type(item) == "string" and item == "deleted" then
		local deleted = st.message({ from = module.host, type = "headline" })
			:tag("event", { xmlns = xmlns_pubsub_event })
				:tag("delete", { node = node });
		traverser(jids, deleted);
	elseif type(item) == "string" and item == "purged" then
		local purged = st.message({ from = module.host, type = "headline" })
			:tag("event", { xmlns = xmlns_pubsub_event })
				:tag("purge", { node = node });
		traverser(jids, purged);
	else
		local message = st.message({ from = module.host, type = "headline" })
			:tag("event", { xmlns = xmlns_pubsub_event })
				:tag("items", { node = node });

		if item then
			item = st.clone(item);
			item.attr.xmlns = nil; -- Clear pubsub ns
			message:get_child("event", xmlns_pubsub_event):get_child("items"):add_child(item);
		end
		traverser(jids, message);
	end
end

module:hook("iq/host/http://jabber.org/protocol/pubsub:pubsub", handle_pubsub_iq);
module:hook("iq/host/http://jabber.org/protocol/pubsub#owner:pubsub", handle_pubsub_iq);

local disco_info;

local feature_map = {
	[true] = { "access-open", "config-node", "persistent-items", "manage-affiliations", "manage-subscriptions", "meta-data" };
	create = { "create-nodes", "create-and-configure", autocreate_on_publish and "instant-nodes", "item-ids" };
	delete = { "delete-nodes" };
	retract = { "delete-items", "retract-items" };
	publish = { "publish" };
	purge = { "purge-nodes" };
	get_items = { "retrieve-items" };
	add_subscription = { "subscribe" };
	get_affiliations = { "retrieve-affiliations" };
	get_subscriptions = { "retrieve-subscriptions" };
};

local function add_disco_features_from_service(disco, service)
	for method, features in pairs(feature_map) do
		if service[method] or method == true then
			for _, feature in ipairs(features) do
				if feature then
					disco:tag("feature", { var = xmlns_pubsub.."#"..feature }):up();
				end
			end
		end
	end
	for affiliation in pairs(service.config.capabilities) do
		if affiliation ~= "none" and affiliation ~= "owner" and affiliation ~= "local_user" then
			disco:tag("feature", { var = xmlns_pubsub.."#"..affiliation.."-affiliation" }):up();
		end
	end
end

local function build_disco_info(service)
	local disco_info = st.stanza("query", { xmlns = "http://jabber.org/protocol/disco#info" })
		:tag("identity", { category = "pubsub", type = "service", name = pubsub_disco_name }):up()
		:tag("feature", { var = "http://jabber.org/protocol/pubsub" }):up();
	add_disco_features_from_service(disco_info, service);
	return disco_info;
end

module:hook("iq-get/host/http://jabber.org/protocol/disco#info:query", function (event)
	local origin, stanza = event.origin, event.stanza;
	local node = stanza.tags[1].attr.node;
	if not node then
		return origin.send(st.reply(stanza):add_child(disco_info));
	else
		local ok, ret = service:get_nodes(stanza.attr.from);
		if ok and not ret[node] then
			ok, ret = false, "item-not-found";
		end
		if not ok then
			return origin.send(pubsub_error_reply(stanza, ret));
		end
		local reply = st.reply(stanza)
			:tag("query", { xmlns = "http://jabber.org/protocol/disco#info", node = node })
				:tag("identity", { category = "pubsub", type = "leaf" }):up();
		service:append_metadata(node, reply);
		return origin.send(reply);
	end
end);

local function handle_disco_items_on_node(event)
	local stanza, origin = event.stanza, event.origin;
	local query = stanza.tags[1];
	local node = query.attr.node;
	local ok, ret, orderly = service:get_items(node, stanza.attr.from);
	if not ok then
		return origin.send(pubsub_error_reply(stanza, ret));
	end
	
	local reply = st.reply(stanza)
		:tag("query", { xmlns = "http://jabber.org/protocol/disco#items", node = node });
	
	for _, id in ipairs(orderly) do
		reply:tag("item", { jid = module.host, name = id }):up();
	end
	
	return origin.send(reply);
end


module:hook("iq-get/host/http://jabber.org/protocol/disco#items:query", function (event)
	if event.stanza.tags[1].attr.node then
		return handle_disco_items_on_node(event);
	end
	local ok, ret = service:get_nodes(event.stanza.attr.from);
	if not ok then
		return event.origin.send(pubsub_error_reply(stanza, ret));
	else
		local reply = st.reply(event.stanza)
			:tag("query", { xmlns = "http://jabber.org/protocol/disco#items" });
		for node, node_obj in pairs(ret) do
			reply:tag("item", { jid = module.host, node = node, name = node_obj.config.title }):up();
		end
		return event.origin.send(reply);
	end
end);

module:hook("pubsub-get-service", function()
	return service;
end);

local admin_aff = module:get_option_string("default_admin_affiliation", "owner");
local use_parents_creds = module:get_option_boolean("use_parents_credentials", true);
local pubsub_admins = module:get_option_set("pubsub_admins", {});
local function get_affiliation(self, jid, name, action)
	local bare_jid = jid_bare(jid);
	local service_host = module.host;
	if use_parents_creds then service_host = service_host:match("%.(.*)"); end
	local is_server_admin;

	if bare_jid == module.host or usermanager.is_admin(bare_jid, service_host) or pubsub_admins:contains(bare_jid) then
		is_server_admin = admin_aff;
	end

	if action == "create" and (not is_server_admin or self.affiliations[bare_jid]) then
		local host = jid_section(jid, "host");
		if unrestricted_node_creation or host == module.host:match("%.(.*)") then 
			return "local_user"; 
		end
	end 

	-- check first if this is a node config check
	if name and action == nil then
		local node = self.nodes[name]
		if not node then 
			return false, "item-not-found";
		else
			return true, is_server_admin or node.affiliations[bare_jid] or "none";
		end
	end

	if is_server_admin then
		return is_server_admin;
	else
		return "none";
	end
end

function set_service(new_service)
	service = new_service;
	module.environment.service = service;
	disco_info = build_disco_info(service);
	pubsub_lib.set_service(service);
	service:restore(true);
end

function module.save()
	return { service = service };
end

function module.restore(data)
	set_service(data.service);
end

set_service(pubsub.new({
	capabilities = {
		none = {
			create = false;
			configure = false;
			delete = false;
			publish = false;
			purge = false;
			retract = false;
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
			
			get_affiliations = true;
			set_affiliation = false;
		};
		member = {
			create = false;
			configure = false;
			delete = false;
			publish = false;
			purge = false;
			retract = false;
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
			
			get_affiliations = true;
			set_affiliation = false;
		};
		publisher = {
			create = false;
			configure = false;
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
			
			get_affiliations = true;
			set_affiliation = false;
		};
		owner = {
			create = true;
			configure = true;
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
			
			get_affiliations = true;
			set_affiliation = true;
		};
		-- Allow local users to create nodes.
		local_user = {
			create = true;
			configure = false;
			delete = false;
			publish = false;
			purge = false;
			retract = false;
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

			get_affiliations = true;			
			set_affiliation = false;

			dummy = true;
		};
	};

	node_default_config = {
		deliver_notifications = true;
		deliver_payloads = true;
	};
	
	autocreate_on_publish = autocreate_on_publish;
	autocreate_on_subscribe = autocreate_on_subscribe;
	
	broadcaster = broadcast;
	get_affiliation = get_affiliation;
	
	normalize_jid = jid_bare;

	store = storagemanager.open(module.host, "pubsub");
}));

