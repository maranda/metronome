local hosts = hosts;
local tonumber, type = tonumber, type;

local pubsub = require "util.pubsub";
local st = require "util.stanza";
local jid_bare = require "util.jid".bare;
local uuid_generate = require "util.uuid".generate;
local dataforms = require "util.dataforms";

local xmlns_pubsub = "http://jabber.org/protocol/pubsub";
local xmlns_pubsub_errors = "http://jabber.org/protocol/pubsub#errors";
local xmlns_pubsub_event = "http://jabber.org/protocol/pubsub#event";
local xmlns_pubsub_owner = "http://jabber.org/protocol/pubsub#owner";

local autocreate_on_publish = module:get_option_boolean("autocreate_on_publish", false);
local autocreate_on_subscribe = module:get_option_boolean("autocreate_on_subscribe", false);
local pubsub_disco_name = module:get_option("name");
if type(pubsub_disco_name) ~= "string" then pubsub_disco_name = "Metronome PubSub Service"; end

local service;

local handlers, handlers_owner = {}, {};

function handle_pubsub_iq(event)
	local origin, stanza = event.origin, event.stanza;
	local pubsub = stanza.tags[1];
	local action = pubsub.tags[1];
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
	end
end

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

function handlers_owner.get_configure(origin, stanza, action)
	local node = action.attr.node;
	if not node then
		return origin.send(pubsub_error_reply(stanza, "feature-not-implemented"));
	end

	local ok, ret = service:get_affiliation(stanza.attr.from, node);

	if ret == "owner" then
		return service:send_node_config_form(node, origin, stanza);
	else
		return origin.send(pubsub_error_reply(stanza, "forbidden"));
	end
end

function handlers.get_items(origin, stanza, items)
	local node = items.attr.node;
	local item = items:get_child("item");
	local id = item and item.attr.id;
	local max = item and item.attr.max_items;
	
	local ok, results, max_tosend = service:get_items(node, stanza.attr.from, id, max);
	if not ok then
		return origin.send(pubsub_error_reply(stanza, results));
	end
	
	local data = st.stanza("items", { node = node });
	for _, id in ipairs(max_tosend) do data:add_child(results[id]); end

	local reply;
	if data then
		reply = st.reply(stanza)
			:tag("pubsub", { xmlns = xmlns_pubsub })
				:add_child(data);
	else
		reply = pubsub_error_reply(stanza, "item-not-found");
	end
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
		reply:tag("subscription", { node = sub.node, jid = sub.jid, subscription = 'subscribed' }):up();
	end
	return origin.send(reply);
end

function handlers_owner.set_configure(origin, stanza, action)
	local node = action.attr.node;
	if not node then
		return origin.send(pubsub_error_reply(stanza, "feature-not-implemented"));
	end

	local ok, ret = service:get_affiliation(stanza.attr.from, node)
	
	local reply;
	if ret == "owner" then
		if action:get_child("x", "jabber:x:data") and 
		   (action:get_child("x", "jabber:x:data").attr.type == "submit" or action:get_child("x", "jabber:x:data").attr.type == "cancel") then
			local form = action:get_child("x", "jabber:x:data");
			if form.attr.type == "cancel" then
				reply = st.reply(stanza);
			else
				local ok, ret = service:process_node_config_form(node, form);
				if ok then reply = st.reply(stanza); else reply = pubsub_error_reply(stanza, ret); end
			end
		else
			reply = pubsub_error_reply(stanza, "bad-request");
		end
	else
		reply = pubsub_error_reply(stanza, "forbidden");
	end
	return origin.send(reply);
end

function handlers.set_create(origin, stanza, create, config)
	local node = create.attr.node;
	local ok, ret, reply;

	local node_config;
	if config then
		node_config = {};
		local fields = config:get_child("x", "jabber:x:data");
		for _, field in ipairs(fields.tags) do
			if field.attr.var == "pubsub#title" and field:get_child_text("value") then
				node_config["title"] = field:get_child_text("value");
			elseif field.attr.var == "pubsub#deliver_notifications" and (field:get_child_text("value") == "0" or field:get_child_text("value") == "1") then
				node_config["deliver_notifications"] = (field:get_child_text("value") == "0" and false) or (field:get_child_text("value") == "1" and true);
			elseif field.attr.var == "pubsub#deliver_payloads" and (field:get_child_text("value") == "0" or field:get_child_text("value") == "1") then
				node_config["deliver_payloads"] = (field:get_child_text("value") == "0" and false) or (field:get_child_text("value") == "1" and true);
			elseif field.attr.var == "pubsub#max_items" and (field:get_child_text("value") == "0" or field:get_child_text("value") == "1") then
				node_config["max_items"] = tonumber(field:get_child_text("value"));
			elseif field.attr.var == "pubsub#persist_items" and (field:get_child_text("value") == "0" or field:get_child_text("value") == "1") then
				node_config["persist_items"] = (field:get_child_text("value") == "0" and false) or (field:get_child_text("value") == "1" and true);
			-- Jappix compat below.
			elseif field.attr.var == "pubsub#publish_model" and field:get_child_text("value") == "open" then
				node_config["open_publish"] = true;
			end
		end
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

function handlers.set_subscribe(origin, stanza, subscribe)
	local node, jid = subscribe.attr.node, subscribe.attr.jid;
	local options_tag, options = stanza.tags[1]:get_child("options"), nil;
	if options_tag then
		options = options_form:data(options_tag.tags[1]);
	end
	local ok, ret = service:add_subscription(node, stanza.attr.from, jid, options);
	local reply;
	if ok then
		reply = st.reply(stanza)
			:tag("pubsub", { xmlns = xmlns_pubsub })
				:tag("subscription", {
					node = node,
					jid = jid,
					subscription = "subscribed"
				}):up();
		if options_tag then
			reply:add_child(options_tag);
		end
	else
		reply = pubsub_error_reply(stanza, ret);
	end
	origin.send(reply);
	if ok then
		-- Send all current items
		local ok, items, orderly = service:get_items(node, stanza.attr.from);
		if items then
			local jids = { [jid] = options or true };
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

function broadcast(self, node, jids, item)
	local function traverser(jids, stanza)
		for jid in pairs(jids) do
			module:log("debug", "Sending notification to %s", jid);
			stanza.attr.to = jid;
			module:send(stanza);
		end
	end

	if type(item) == "string" and item == "deleted" then
		local deleted = st.message({ from = module.host, type = headline })
			:tag("event", { xmlns = xmlns_pubsub_event })
				:tag("delete", { node = node });
		traverser(jids, deleted);
	elseif type(item) == "string" and item == "purged" then
		local purged = st.message({ from = module.host, type = headline })
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

function form_layout(self, name)
	local c_name = "Node configuration for "..name;
	local node = self.nodes[name];

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
			label = "A friendly name for this node",
			value = node.config.title or ""
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
			type = "boolean",
			label = "Max number of items to persist",
			value = node.config.max_items or 20
		},
		{
			name = "pubsub#persist_items",
			type = "boolean",
			label = "Whether to persist items to storage or not",
			value = node.config.persist_items or false
		}		
	});
end

function send_config_form(self, name, origin, stanza)
	return origin.send(st.reply(stanza)
		:tag("pubsub", { xmlns = "http://jabber.org/protocol/pubsub#owner" })
			:tag("configure", { node = name })
				:add_child(self:node_config_form_layout(name):form()):up()
	);
end

function process_config_form(self, name, form)
	local node = self.nodes[name];
	if not node then return false, "item-not-found" end
	
	local fields = self:node_config_form_get(name):data(form);

	node.config["title"] = fields["pubsub#title"];
	node.config["deliver_notifications"] = fields["pubsub#deliver_notifications"];
	node.config["deliver_payloads"] = fields["pubsub#deliver_payloads"];

	return true;
end

module:hook("iq/host/http://jabber.org/protocol/pubsub:pubsub", handle_pubsub_iq);
module:hook("iq/host/http://jabber.org/protocol/pubsub#owner:pubsub", handle_pubsub_iq);

local disco_info;

local feature_map = {
	process_node_config_form = { "config-node", "persistent-items" };
	create = { "create-nodes", autocreate_on_publish and "instant-nodes", "item-ids" };
	delete = { "delete-nodes" };
	retract = { "delete-items", "retract-items" };
	publish = { "publish" };
	purge = { "purge-nodes" };
	get_items = { "retrieve-items" };
	add_subscription = { "subscribe" };
	get_subscriptions = { "retrieve-subscriptions" };
};

local function add_disco_features_from_service(disco, service)
	for method, features in pairs(feature_map) do
		if service[method] then
			for _, feature in ipairs(features) do
				if feature then
					disco:tag("feature", { var = xmlns_pubsub.."#"..feature }):up();
				end
			end
		end
	end
	for affiliation in pairs(service.config.capabilities) do
		if affiliation ~= "none" and affiliation ~= "owner" then
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
			origin.send(pubsub_error_reply(stanza, ret)); return true;
		end
		local reply = st.reply(stanza)
			:tag("query", { xmlns = "http://jabber.org/protocol/disco#info", node = node })
				:tag("identity", { category = "pubsub", type = "leaf" });
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
			reply:tag("item", { jid = module.host, node = node, name = node_obj.config.name }):up();
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
	service:restore();
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
			
			set_affiliation = true;
		};
	};

	node_default_config = {
		title = "";
		deliver_notifications = true;
		deliver_payloads = true;
	};
	
	autocreate_on_publish = autocreate_on_publish;
	autocreate_on_subscribe = autocreate_on_subscribe;
	
	broadcaster = broadcast;
	send_node_config_form = send_config_form;
	process_node_config_form = process_config_form;
	node_config_form_layout = form_layout;
	get_affiliation = get_affiliation;
	
	normalize_jid = jid_bare;

	store = storagemanager.open(module.host, "pubsub");
}));

