-- * Metronome IM *
--
-- This file is part of the Metronome XMPP server and is released under the
-- ISC License, please see the LICENSE file in this source package for more
-- information about copyright and licensing.

local hosts = hosts;
local ripairs, tonumber, type = ripairs, tonumber, type;

local pubsub = require "util.pubsub";
local st = require "util.stanza";
local jid_bare, jid_split = require "util.jid".bare, require "util.jid".split;
local uuid_generate = require "util.uuid".generate;
local dataforms = require "util.dataforms";

local xmlns_pubsub = "http://jabber.org/protocol/pubsub";
local xmlns_pubsub_errors = "http://jabber.org/protocol/pubsub#errors";
local xmlns_pubsub_event = "http://jabber.org/protocol/pubsub#event";
local xmlns_pubsub_owner = "http://jabber.org/protocol/pubsub#owner";

local autocreate_on_publish = module:get_option_boolean("autocreate_on_publish", false);
local autocreate_on_subscribe = module:get_option_boolean("autocreate_on_subscribe", false);
local unrestricted_node_creation = module:get_option_boolean("unrestricted_node_creation", false);

local pubsub_disco_name = module:get_option("name");
if type(pubsub_disco_name) ~= "string" then pubsub_disco_name = "Metronome PubSub Service"; end

local service;

local handlers, handlers_owner = {}, {};

-- Util functions and mappings

local pubsub_errors = {
	["conflict"] = { "cancel", "conflict" };
	["invalid-jid"] = { "modify", "bad-request", nil, "invalid-jid" };
	["item-not-found"] = { "cancel", "item-not-found" };
	["not-subscribed"] = { "modify", "unexpected-request", nil, "not-subscribed" };
	["feature-not-implemented"] = { "cancel", "feature-not-implemented" };
	["forbidden"] = { "cancel", "forbidden" };
	["bad-request"] = { "cancel", "bad-request" };
};
function pubsub_error_reply(stanza, error)
	local e = pubsub_errors[error];
	local reply = st.error_reply(stanza, unpack(e, 1, 3));
	if e[4] then
		reply:tag(e[4], { xmlns = xmlns_pubsub_errors }):up();
	end
	return reply;
end

function form_layout(service, name)
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
			name = "pubsub#deliver_notifications",
			type = "boolean",
			label = "Wheter to deliver event notification",
			value = node.config.deliver_notifications or true
		},
		{
			name = "pubsub#deliver_payloads",
			type = "boolean",
			label = "Whether to deliver payloads with event notifications",
			value = ((node.config.deliver_notifications == false and false) or (node.config.deliver_notifications == true and node.config.deliver_payload)) or true
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
			label = "Access Model for the node, currently supported models are open and whitelist",
			value = {
				{ value = "open", default = (node.config.access_model == "open" or node.config.access_model == nil) and true },
				{ value = "whitelist", default = node.config.access_model == "whitelist" and true }
			}
		},
		{
			name = "pubsub#publish_model",
			type = "list-single",
			label = "Publisher Model for the node, currently supported models are publisher and open",
			value = {
				{ value = "publishers", default = (node.config.publish_model == "publishers" or node.config.publish_model == nil) and true },
				{ value = "open", default = node.config.publish_model == "open" and true },
				{ value = "subscribers", default = node.config.publish_model == "subscribers" and true }
			}
		},				
	});
end

function send_config_form(service, name, origin, stanza)
	return origin.send(st.reply(stanza)
		:tag("pubsub", { xmlns = "http://jabber.org/protocol/pubsub#owner" })
			:tag("configure", { node = name })
				:add_child(form_layout(service, name):form()):up()
	);
end

function process_config_form(service, name, form, new)
	local node_config, node;
	if new then
		node_config = {};
	else
		node = service.nodes[name];
		if not node then return false, "item-not-found"; end
		node_config = node.config;
	end

	if not form or form.attr.type ~= "submit" then return false, "bad-request" end

	for _, field in ipairs(form.tags) do
		if field.attr.var == "pubsub#title" then
			node_config.title = (field:get_child_text("value") ~= "" and field:get_child_text("value")) or nil;
		elseif field.attr.var == "pubsub#description" then
			node_config.description = (field:get_child_text("value") ~= "" and field:get_child_text("value")) or nil;
		elseif field.attr.var == "pubsub#type" then
			node_config.type = (field:get_child_text("value") ~= "" and field:get_child_text("value")) or nil;
		elseif field.attr.var == "pubsub#deliver_notifications" and (field:get_child_text("value") == "0" or field:get_child_text("value") == "1") then
			node_config.deliver_notifications = (field:get_child_text("value") == "0" and false) or (field:get_child_text("value") == "1" and true);
		elseif field.attr.var == "pubsub#deliver_payloads" and (field:get_child_text("value") == "0" or field:get_child_text("value") == "1") then
			node_config.deliver_payloads = (field:get_child_text("value") == "0" and false) or (field:get_child_text("value") == "1" and true);
		elseif field.attr.var == "pubsub#max_items" then
			node_config.max_items = tonumber(field:get_child_text("value"));
		elseif field.attr.var == "pubsub#persist_items" then
			node_config.persist_items = (field:get_child_text("value") == "0" and false) or (field:get_child_text("value") == "1" and true);
		elseif field.attr.var == "pubsub#access_model" then
			local value = field:get_child_text("value");
			if value == "open" or value == "whitelist" then node_config.access_model = value; end
		elseif field.attr.var == "pubsub#publish_model" then
			local value = field:get_child_text("value");
			if value == "open" or value == "publishers" or value == "subscribers" then node_config.publish_model = value; end
		end
	end

	if new then return true, node_config end

	service:save_node(name);
	return true;
end

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

local function _get_affiliations(origin, stanza, action, owner)
	local node = action.attr.node;
	local ok, ret, reply;

	if owner then -- this is node owner request
		reply = st.reply(stanza)
				:tag("pubsub", { xmlns = xmlns_pubsub_owner })
					:tag("affiliations");

		ok, ret = service:get_affiliations(node, stanza.attr.from, true);
		if ok and ret then
			for jid, affiliation in pairs(ret) do
				if affiliation ~= "none" then
					reply:tag("affiliation", { jid = jid, affiliation = affiliation }):up();
				end
			end
		elseif not ok then
			reply = pubsub_error_reply(stanza, ret);
		end
	else
		reply = st.reply(stanza)
			:tag("pubsub", { xmlns = xmlns_pubsub })
				:tag("affiliations");

		ok, ret = service:get_affiliations(node, stanza.attr.from);
		if ok and ret then
			for n, affiliation in pairs(ret) do
				if affiliation ~= "none" then
					reply:tag("affiliation", { node = n, affiliation = affiliation }):up();
				end
			end
		elseif not ok then
			reply = pubsub_error_reply(stanza, ret);
		end
	end

	return origin.send(reply);
end

-- pubsub ns handlers

function handlers.get_items(origin, stanza, items)
	local node = items.attr.node;
	local max = items and items.attr.max_items and tonumber(items.attr.max_items);
	local item = items:get_child("item");
	local id = item and item.attr.id;
	
	local ok, results, max_tosend = service:get_items(node, stanza.attr.from, id, max);
	if not ok then
		return origin.send(pubsub_error_reply(stanza, results));
	end
	
	local data = st.stanza("items", { node = node });
	if not max or max == 0 then
		for _, id in ripairs(max_tosend) do data:add_child(results[id]); end
	else
		for _, id in ipairs(max_tosend) do data:add_child(results[id]); end		
	end

	local reply;
	reply = st.reply(stanza)
		:tag("pubsub", { xmlns = xmlns_pubsub })
			:add_child(data);

	return origin.send(reply);
end

function handlers.get_subscriptions(origin, stanza, subscriptions)
	local node = subscriptions.attr.node;
	local ok, ret = service:get_subscriptions(node, stanza.attr.from, stanza.attr.from);
	if not ok then
		return origin.send(pubsub_error_reply(stanza, ret));
	end
	local reply = st.reply(stanza)
		:tag("pubsub", { xmlns = xmlns_pubsub })
			:tag("subscriptions");
	for _, sub in ipairs(ret) do
		reply:tag("subscription", { node = sub.node, jid = sub.jid, subscription = "subscribed" }):up();
	end
	return origin.send(reply);
end

function handlers.get_affiliations(origin, stanza, action) return _get_affiliations(origin, stanza, action, false); end

function handlers.set_create(origin, stanza, create, config)
	local node = create.attr.node;
	local ok, ret, reply;

	local node_config;
	local node_config;
	if config then
		local form = config:get_child("x", "jabber:x:data");
		ok, node_config = process_config_form(service, node, form, true);
		if not ok then return origin.send(pubsub_error_reply(stanza, node_config)); end
	end

	if node then
		ok, ret = service:create(node, stanza.attr.from, node_config);
		if ok then
			reply = st.reply(stanza);
		else
			reply = pubsub_error_reply(stanza, ret);
		end
	else
		repeat
			node = uuid_generate();
			ok, ret = service:create(node, stanza.attr.from, node_config);
		until ok or ret ~= "conflict";
		if ok then
			reply = st.reply(stanza)
				:tag("pubsub", { xmlns = xmlns_pubsub })
					:tag("create", { node = node });
		else
			reply = pubsub_error_reply(stanza, ret);
		end
	end
	return origin.send(reply);
end

function handlers.set_subscribe(origin, stanza, subscribe)
	local node, jid = subscribe.attr.node, subscribe.attr.jid;
	local options_tag = stanza.tags[1]:get_child("options") and true;
	if options_tag then
		return origin.send(st.error_reply(stanza, "modify", "bad-request",
				"Subscription options aren't supported by this service"));
	end
	local ok, ret = service:add_subscription(node, stanza.attr.from, jid);
	local reply;
	if ok then
		reply = st.reply(stanza)
			:tag("pubsub", { xmlns = xmlns_pubsub })
				:tag("subscription", {
					node = node,
					jid = jid,
					subscription = "subscribed"
				}):up();
	else
		reply = pubsub_error_reply(stanza, ret);
	end
	origin.send(reply);
	if ok then
		-- Send all current items
		local ok, items, orderly = service:get_items(node, stanza.attr.from);
		if items then
			local jids = { [jid] = true };
			for _, id in ipairs(orderly) do
				service:broadcaster(node, jids, items[id]);
			end
		end
	end
	return true;
end

function handlers.set_unsubscribe(origin, stanza, unsubscribe)
	local node, jid = unsubscribe.attr.node, unsubscribe.attr.jid;
	local ok, ret = service:remove_subscription(node, stanza.attr.from, jid);
	local reply;
	if ok then
		reply = st.reply(stanza);
	else
		reply = pubsub_error_reply(stanza, ret);
	end
	return origin.send(reply);
end

function handlers.set_publish(origin, stanza, publish)
	local node = publish.attr.node;
	local item = publish:get_child("item");
	local id = (item and item.attr.id) or uuid_generate();
	if item and not item.attr.id then item.attr.id = id; end
	local ok, ret = service:publish(node, stanza.attr.from, id, item);
	local reply;
	if ok then
		reply = st.reply(stanza)
			:tag("pubsub", { xmlns = xmlns_pubsub })
				:tag("publish", { node = node })
					:tag("item", { id = id });
	else
		reply = pubsub_error_reply(stanza, ret);
	end
	return origin.send(reply);
end

function handlers.set_retract(origin, stanza, retract)
	local node, notify = retract.attr.node, retract.attr.notify;
	notify = (notify == "1") or (notify == "true");
	local item = retract:get_child("item");
	local id = item and item.attr.id
	local reply, notifier;
	if notify then
		notifier = st.stanza("retract", { id = id });
	end
	local ok, ret = service:retract(node, stanza.attr.from, id, notifier);
	if ok then
		reply = st.reply(stanza);
	else
		reply = pubsub_error_reply(stanza, ret);
	end
	return origin.send(reply);
end

-- pubsub#owner ns handlers

function handlers_owner.get_configure(origin, stanza, action)
	local node = action.attr.node;
	if not node then
		return origin.send(pubsub_error_reply(stanza, "feature-not-implemented"));
	end

	if not service.nodes[node] then
		return origin.send(pubsub_error_reply(stanza, "item-not-found"));
	end

	local ok, ret = service:get_affiliation(stanza.attr.from, node);

	if ret == "owner" then
		return send_config_form(service, node, origin, stanza);
	else
		return origin.send(pubsub_error_reply(stanza, "forbidden"));
	end
end

function handlers_owner.set_configure(origin, stanza, action)
	local node = action.attr.node;
	if not node then
		return origin.send(pubsub_error_reply(stanza, "feature-not-implemented"));
	end

	if not service.nodes[node] then
		return origin.send(pubsub_error_reply(stanza, "item-not-found"));
	end

	local ok, ret = service:get_affiliation(stanza.attr.from, node)
	
	local reply;
	if ret == "owner" then
		local form = action:get_child("x", "jabber:x:data");
		if form and form.attr.type == "cancel" then
			return origin.send(st.reply(stanza));
		end

		local ok, ret = process_config_form(service, node, form);
		if ok then reply = st.reply(stanza); else reply = pubsub_error_reply(stanza, ret); end
	else
		reply = pubsub_error_reply(stanza, "forbidden");
	end
	return origin.send(reply);
end

function handlers_owner.get_affiliations(origin, stanza, action) return _get_affiliations(origin, stanza, action, true); end

function handlers_owner.set_affiliations(origin, stanza, action)
	local node = action.attr.node;
	if not service.nodes[node] then
		return origin.send(pubsub_error_reply(stanza, "item-not-found"));
	end

	-- pre-emptively check for permission, to save processing power in case of failure
	if not service:may(node, stanza.attr.from, "set_affiliation") then
		return origin.send(pubsub_error_reply(stanza, "forbidden"));
	end	

	-- make a list of affiliations to change
	local _to_change = {};
	for _, tag in ipairs(action.tags) do
		if tag.attr.jid and tag.attr.affiliation then
			_to_change[tag.attr.jid] = tag.attr.affiliation;
		end
	end
	
	local ok, err;
	for jid, affiliation in pairs(_to_change) do
		ok, err = service:set_affiliation(node, true, jid, affiliation);
		if not ok then
			return origin.send(pubsub_error_reply(stanza, err));
		end
	end

	return origin.send(st.reply(stanza));
end

function handlers_owner.set_delete(origin, stanza, delete)
	local node = delete.attr.node;
	local ok, ret, reply;
	if node then
		ok, ret = service:delete(node, stanza.attr.from);
		if ok then reply = st.reply(stanza); else reply = pubsub_error_reply(stanza, ret); end
	else
		reply = pubsub_error_reply(stanza, "bad-request");
	end
	return origin.send(reply);
end

function handlers_owner.set_purge(origin, stanza, purge)
	local node = purge.attr.node;
	local ok, ret, reply;
	if node then
		ok, ret = service:purge(node, stanza.attr.from);
		if ok then reply = st.reply(stanza); else reply = pubsub_error_reply(stanza, ret); end
	else
		reply = pubsub_error_reply(stanza, "bad-request");
	end
	return origin.send(reply);
end

function handlers_owner.get_subscriptions(origin, stanza, subscriptions)
	local node = subscriptions.attr.node;
	local ok, subs = service:get_subscriptions(node, stanza.attr.from);
	if not ok then return origin.send(pubsub_error_reply(stanza, subs)); end

	local reply = st.reply(stanza)
		:tag("pubsub", { xmlns = xmlns_pubsub_owner })
			:tag("subscriptions");

	for _, subscription in ipairs(subs) do
		reply:tag("subscription", { node = node, jid = subscription.jid, subscription = "subscribed" }):up();
	end

	return origin.send(reply);
end

function handlers_owner.set_subscriptions(origin, stanza, subscriptions)
	local node = subscriptions.attr.node;
	local subscriptions = subscriptions.tags;

	-- pre-emptively do checks
	if not service.nodes[node] then
		return origin.send(pubsub_error_reply(stanza, "item-not-found"));
	end

	if not service:may(node, stanza.attr.from, "subscribe_other") or
	   not service:may(node, stanza.attr.from, "unsubscribe_other") then
		return origin.send(pubsub_error_reply(stanza, "forbidden"));
	end

	-- populate list of subscribers
	local _to_change = {};
	for _, sub in ipairs(subscriptions) do
		local subscription = sub.attr.subscription;
		if subscription ~= "none" and subscription ~= "subscribed" then
			return origin.send(st.error_reply(stanza, "cancel", "bad-request",
				"Only none and subscribed subscription types are currently supported"));
		end
		_to_change[sub.attr.jid] = subscription;
	end

	for jid, subscription in pairs(_to_change) do
		if subscription == "subscribed" then
			service:add_subscription(node, true, jid);
		else
			service:remove_subscription(node, true, jid);
		end
	end

	return origin.send(st.reply(stanza));
end

-- handlers end

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

local admin_aff = module:get_option_string("default_admin_affiliation", "owner");
local use_parents_creds = module:get_option_boolean("use_parents_credentials", true);
local pubsub_admins = module:get_option_set("pubsub_admins", {});
local function get_affiliation(self, jid, name, action)
	local bare_jid = jid_bare(jid);
	local service_host = module.host;
	if use_parents_creds then service_host = service_host:match("^[%w+]*%.(.*)"); end
	local is_server_admin;

	if bare_jid == module.host or usermanager.is_admin(bare_jid, service_host) or pubsub_admins:contains(bare_jid) then
		is_server_admin = admin_aff;
	end

	if action == "create" and (not is_server_admin or self.affiliations[bare_jid]) then
		local _, host = jid_split(jid);
		if unrestricted_node_creation or host == module.host:match("^[%w+]*%.(.*)") then 
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

