-- * Metronome IM *
--
-- This file is part of the Metronome XMPP server and is released under the
-- ISC License, please see the LICENSE file in this source package for more
-- information about copyright and licensing.

-- PubSub exportable standard handlers/function library.

local hosts = hosts;
local ripairs, tonumber, type = ripairs, tonumber, type;

local st = require "util.stanza";
local uuid_generate = require "util.uuid".generate;
local dataforms = require "util.dataforms";

local service;

local xmlns_pubsub = "http://jabber.org/protocol/pubsub";
local xmlns_pubsub_errors = "http://jabber.org/protocol/pubsub#errors";
local xmlns_pubsub_owner = "http://jabber.org/protocol/pubsub#owner";

-- Util functions and mappings

local function set_service(srv) service = srv; end

local pubsub_errors = {
	["conflict"] = { "cancel", "conflict" };
	["invalid-jid"] = { "modify", "bad-request", nil, "invalid-jid" };
	["item-not-found"] = { "cancel", "item-not-found" };
	["not-subscribed"] = { "modify", "unexpected-request", nil, "not-subscribed" };
	["feature-not-implemented"] = { "cancel", "feature-not-implemented" };
	["forbidden"] = { "cancel", "forbidden" };
	["bad-request"] = { "cancel", "bad-request" };
};

local function pubsub_error_reply(stanza, error)
	local e = pubsub_errors[error];
	local reply = st.error_reply(stanza, unpack(e, 1, 3));
	if e[4] then
		reply:tag(e[4], { xmlns = xmlns_pubsub_errors }):up();
	end
	return reply;
end

local function form_layout(service, name)
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
			value = (node.config.deliver_notifications == nil and true) or node.config.deliver_notifications
		},
		{
			name = "pubsub#deliver_payloads",
			type = "boolean",
			label = "Whether to deliver payloads with event notifications",
			value = ((node.config.deliver_notifications == nil or node.config.deliver_notifications) and
				node.config.deliver_payloads == nil and true) or
				((node.config.deliver_notifications == nil or node.config.deliver_notifications) and
				node.config.deliver_payloads) or false
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

local function send_config_form(service, name, origin, stanza)
	return origin.send(st.reply(stanza)
		:tag("pubsub", { xmlns = "http://jabber.org/protocol/pubsub#owner" })
			:tag("configure", { node = name })
				:add_child(form_layout(service, name):form()):up()
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

	if not form or form.attr.type ~= "submit" then return false, "bad-request"; end

	for _, field in ipairs(form.tags) do
		local value = field:get_child_text("value");
		if field.attr.var == "pubsub#title" then
			node_config.title = (value ~= "" and value) or nil;
		elseif field.attr.var == "pubsub#description" then
			node_config.description = (value ~= "" and value) or nil;
		elseif field.attr.var == "pubsub#type" then
			node_config.type = (value ~= "" and value) or nil;
		elseif field.attr.var == "pubsub#deliver_notifications" then
			node_config.deliver_notifications = ((value == 0 or value == "false") and false) or
				((value == "1" or value == "true") and true);
		elseif field.attr.var == "pubsub#deliver_payloads" then
			node_config.deliver_payloads = ((value == 0 or value == "false") and false) or
				((value == "1" or value == "true") and true);
		elseif field.attr.var == "pubsub#max_items" then
			node_config.max_items = tonumber(value);
		elseif field.attr.var == "pubsub#persist_items" then
			node_config.persist_items = ((value == 0 or value == "false") and false) or
				((value == "1" or value == "true") and true);
		elseif field.attr.var == "pubsub#access_model" then
			if value == "open" or value == "whitelist" then node_config.access_model = value; end
		elseif field.attr.var == "pubsub#publish_model" then
			if value == "open" or value == "publishers" or value == "subscribers" then node_config.publish_model = value; end
		end
	end

	if node_config.deliver_notifications == false and
	   (node_config.deliver_payloads == true or node_config.deliver_payloads == nil) then
		node_config.deliver_payloads = false;
	end

	if new then return true, node_config; end

	service:save_node(name);
	service:save();
	return true;
end

-- handlers start

local handlers = {};
local handlers_owner = {};

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
		local deliver_payloads = service.nodes[node].config.deliver_payloads;
		-- Send all current items
		local ok, items, orderly = service:get_items(node, stanza.attr.from, nil, nil,
			(deliver_payloads == nil or deliver_payloads));
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

return { 
	handlers = handlers, 
	handlers_owner = handlers_owner,
	pubsub_error_reply = pubsub_error_reply,
	form_layout = form_layout,
	send_config_form = send_config_form,
	process_config_form = process_config_form,
	set_service = set_service
};
	
