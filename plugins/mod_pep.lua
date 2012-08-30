local hosts = hosts;
local core_post_stanza = metronome.core_post_stanza;

local pubsub = require "util.pubsub";
local st = require "util.stanza";
local jid_bare = require "util.jid".bare;
local jid_split = require "util.jid".split
local uuid_generate = require "util.uuid".generate;
local is_contact_subscribed = require "core.rostermanager".is_contact_subscribed;
local calculate_hash = require "util.caps".calculate_hash;
local array = require "util.array";
local getpath = datamanager.getpath;
local lfs = require "lfs";

local xmlns_pubsub = "http://jabber.org/protocol/pubsub";
local xmlns_pubsub_errors = "http://jabber.org/protocol/pubsub#errors";
local xmlns_pubsub_event = "http://jabber.org/protocol/pubsub#event";
local xmlns_pubsub_owner = "http://jabber.org/protocol/pubsub#owner";

services = {};
local handlers = {};
local handlers_owner = {};
local NULL = {};

module:add_identity("pubsub", "pep", "Metronome");
module:add_feature("http://jabber.org/protocol/pubsub#access-presence");
module:add_feature("http://jabber.org/protocol/pubsub#auto-create");
module:add_feature("http://jabber.org/protocol/pubsub#create-and-configure");
module:add_feature("http://jabber.org/protocol/pubsub#create-nodes");
module:add_feature("http://jabber.org/protocol/pubsub#delete-items");
module:add_feature("http://jabber.org/protocol/pubsub#delete-nodes");
module:add_feature("http://jabber.org/protocol/pubsub#filtered-notifications");
module:add_feature("http://jabber.org/protocol/pubsub#persistent-items");
module:add_feature("http://jabber.org/protocol/pubsub#publish");
module:add_feature("http://jabber.org/protocol/pubsub#purge-nodes");
module:add_feature("http://jabber.org/protocol/pubsub#retrieve-items");
module:add_feature("http://jabber.org/protocol/pubsub#subscribe");

local function subscription_presence(user_bare, recipient)
	local recipient_bare = jid_bare(recipient);
	if (recipient_bare == user_bare) then return true end
	local username, host = jid_split(user_bare);
	return is_contact_subscribed(username, host, recipient_bare);
end

function handle_pubsub_iq(event)
	local origin, stanza = event.origin, event.stanza;
	local user = stanza.attr.to or (origin.username..'@'..origin.host);
	local username, host = jid_split(user);
	if hosts[host].sessions[username] and not services[user] then -- create service.
		set_service(pubsub.new(pep_new(username)), user);
	end
	
	local pubsub = stanza.tags[1];
	local action = pubsub.tags[1];
	local handler = handlers[stanza.attr.type.."_"..action.name];
	local config = (pubsub.tags[2] and pubsub.tags[2].name == "configure") and pubsub.tags[2];
	local handler;

	if pubsub.attr.xmlns == xmlns_pubsub_owner then
		handler = handlers_owner[stanza.attr.type.."_"..action.name];
	else
		handler = handlers[stanza.attr.type.."_"..action.name];
	end	

	-- Update session to the one of the owner.
	if origin.username and origin.host and services[user].name == origin.username.."@"..origin.host then services[user].session = origin; end

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
	["forbidden"] = { "cancel", "forbidden" };
};
function pubsub_error_reply(stanza, error)
	local e = pubsub_errors[error];
	local reply = st.error_reply(stanza, unpack(e, 1, 3));
	if e[4] then
		reply:tag(e[4], { xmlns = xmlns_pubsub_errors }):up();
	end
	return reply;
end

function handlers.get_items(origin, stanza, items)
	local node = items.attr.node;
	local item = items:get_child("item");
	local id = item and item.attr.id;
	local max = item and item.attr.max_items;
	local user = stanza.attr.to or (origin.username..'@'..origin.host);
	
	local ok, results, max_tosend = services[user]:get_items(node, stanza.attr.from, id, max);
	if not ok then
		return origin.send(pubsub_error_reply(stanza, results));
	end
	
	local data = st.stanza("items", { node = node });
	for _, id in ipairs(array(max_tosend):reverse()) do data:add_child(results[id]); end

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
	local user = stanza.attr.to or (origin.username..'@'..origin.host);
	local ok, ret = services[user]:get_subscriptions(node, stanza.attr.from, stanza.attr.from);
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

function handlers.set_create(origin, stanza, create, config)
	local node = create.attr.node;
	local user = stanza.attr.to or (origin.username..'@'..origin.host);
	local ok, ret, reply;

	local node_config;
	if config then
		node_config = {};
		local fields = config:get_child("x", "jabber:x:data");
		for _, field in ipairs(fields.tags) do
			if field.attr.var == "pubsub#persist_items" and (field:get_child_text("value") == "0" or field:get_child_text("value") == "1") then
				node_config["persist_items"] = (field:get_child_text("value") == "0" and false) or (field:get_child_text("value") == "1" and true);
			-- Jappix compat below.
			elseif field.attr.var == "pubsub#publish_model" and field:get_child_text("value") == "open" then
				node_config["open_publish"] = true;
			end
		end
	end

	if node then
		ok, ret = services[user]:create(node, stanza.attr.from, node_config);
		if ok then
			reply = st.reply(stanza);
		else
			reply = pubsub_error_reply(stanza, ret);
		end
	else
		repeat
			node = uuid_generate();
			ok, ret = services[user]:create(node, stanza.attr.from);
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
	local user = stanza.attr.to or (origin.username..'@'..origin.host);
	local ok, ret, reply;
	if node then
		ok, ret = services[user]:delete(node, stanza.attr.from);
		if ok then reply = st.reply(stanza); else reply = pubsub_error_reply(stanza, ret); end
	else
		reply = pubsub_error_reply(stanza, "bad-request");
	end
	return origin.send(reply);
end

function handlers.set_subscribe(origin, stanza, subscribe)
	local node, jid = subscribe.attr.node, subscribe.attr.jid;
	local user = stanza.attr.to or (origin.username..'@'..origin.host);
	local options_tag, options = stanza.tags[1]:get_child("options"), nil;
	if options_tag then
		options = options_form:data(options_tag.tags[1]);
	end
	local ok, ret = services[user]:add_subscription(node, stanza.attr.from, jid, options);
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
		local ok, items, orderly = services[user]:get_items(node, stanza.attr.from);
		if items then
			local jids = { [jid] = options or true };
			for _, id in pairs(array(orderly):reverse()) do
				services[user]:broadcaster(node, jids, items[id]);
			end
		end
	end
	return true;
end

function handlers_owner.set_purge(origin, stanza, purge)
	local node = purge.attr.node;
	local user = stanza.attr.to or (origin.username..'@'..origin.host);
	local ok, ret, reply;
	if node then
		ok, ret = services[user]:purge(node, stanza.attr.from);
		if ok then reply = st.reply(stanza); else reply = pubsub_error_reply(stanza, ret); end
	else
		reply = pubsub_error_reply(stanza, "bad-request");
	end
	return origin.send(reply);
end

function handlers.set_unsubscribe(origin, stanza, unsubscribe)
	local node, jid = unsubscribe.attr.node, unsubscribe.attr.jid;
	local user = stanza.attr.to or (origin.username..'@'..origin.host);
	local ok, ret = services[user]:remove_subscription(node, stanza.attr.from, jid);
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
	local user = stanza.attr.to or (origin.username..'@'..origin.host);
	local item = publish:get_child("item");
	local recs = {};
	local recs_count = 0;
	local id = (item and item.attr.id) or uuid_generate();
	if node == "http://jabber.org/protocol/activity" and services[user].nodes[node] or
	   node == "http://jabber.org/protocol/mood" and services[user].nodes[node] or
	   node == "http://jabber.org/protocol/tune" and services[user].nodes[node] or
	   node == "urn:xmpp:avatar:data" and services[user].nodes[node] or 
	   node == "urn:xmpp:avatar:metadata" and services[user].nodes[node]then
		services[user].nodes[node].data = {} end -- Clear activity/mood/tune/avatar nodes, wonder if this is the right thing to do?
							 -- Clients don't do it and mess up. *Spec To Be Checked*

	local ok, ret = services[user]:publish(node, stanza.attr.from, id, item);
	local reply;
	
	if ok then
		reply = st.reply(stanza)
			:tag("pubsub", { xmlns = xmlns_pubsub })
				:tag("publish", { node = node })
					:tag("item", { id = id })
	else
		reply = pubsub_error_reply(stanza, ret);
	end
	
	return origin.send(reply);
end

function handlers.set_retract(origin, stanza, retract)
	local node, notify = retract.attr.node, retract.attr.notify;
	local user = stanza.attr.to or (origin.username..'@'..origin.host);
	notify = (notify == "1") or (notify == "true");
	local item = retract:get_child("item");
	local id = item and item.attr.id
	local reply, notifier;
	if notify then
		notifier = st.stanza("retract", { id = id });
	end
	local ok, ret = services[user]:retract(node, stanza.attr.from, id, notifier);
	if ok then
		reply = st.reply(stanza);
	else
		reply = pubsub_error_reply(stanza, ret);
	end
	return origin.send(reply);
end

function broadcast(self, node, jids, item)
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

	local function send_ifrexist(jid)
		local function notify(s,f)
			module:log("debug", "%s -- service sending notification to %s", s, f);
			message.attr.to = f; core_post_stanza(self.session, message);
		end		
		
		if type(self.recipients[jid]) == "table" 
		   and self.recipients[jid][node] then
			notify(self.name,jid);		
		end
	end

	if type(jids) == "table" then
		for jid in pairs(jids) do send_ifrexist(jid); end
	else send_ifrexist(jids); end
end

module:hook("iq/bare/http://jabber.org/protocol/pubsub:pubsub", handle_pubsub_iq);
module:hook("iq/bare/http://jabber.org/protocol/pubsub#owner:pubsub", handle_pubsub_iq);

local disco_info;

local feature_map = {
	create = { "create-nodes", true and "instant-nodes", "item-ids" };
	retract = { "delete-items", "retract-items" };
	publish = { "publish" };
	get_items = { "retrieve-items" };
	add_subscription = { "subscribe" };
	get_subscriptions = { "retrieve-subscriptions" };
};

local function add_disco_features_from_service(disco, service)
	for method, features in pairs(feature_map) do
		if service[method] then
			for _, feature in ipairs(features) do
				if feature then
					disco:tag("feature", { var = xmlns_pubsub_event.."#"..feature }):up();
				end
			end
		end
	end
	for affiliation in pairs(service.config.capabilities) do
		if affiliation ~= "none" and affiliation ~= "owner" then
			disco:tag("feature", { var = xmlns_pubsub_event.."#"..affiliation.."-affiliation" }):up();
		end
	end
end

local function build_disco_info(service)
	local disco_info = st.stanza("query", { xmlns = "http://jabber.org/protocol/disco#info" })
		:tag("identity", { category = "pubsub", type = "pep" })
		:tag("feature", { var = "http://jabber.org/protocol/pubsub#access-presence" })
		:tag("feature", { var = "http://jabber.org/protocol/pubsub#auto-create" })
		:tag("feature", { var = "http://jabber.org/protocol/pubsub#create-and-configure" })
		:tag("feature", { var = "http://jabber.org/protocol/pubsub#create-nodes" })
		:tag("feature", { var = "http://jabber.org/protocol/pubsub#delete-items" })
		:tag("feature", { var = "http://jabber.org/protocol/pubsub#delete-nodes" })		
		:tag("feature", { var = "http://jabber.org/protocol/pubsub#filtered-notifications" })
		:tag("feature", { var = "http://jabber.org/protocol/pubsub#persistent-items" })
		:tag("feature", { var = "http://jabber.org/protocol/pubsub#publish" })
		:tag("feature", { var = "http://jabber.org/protocol/pubsub#purge-nodes" })
		:tag("feature", { var = "http://jabber.org/protocol/pubsub#retrieve-items" })
		:tag("feature", { var = "http://jabber.org/protocol/pubsub#subscribe" }):up();
	add_disco_features_from_service(disco_info, service);
	return disco_info;
end

module:hook("account-disco-info", function(event)
	local stanza = event.stanza;
	stanza:tag('identity', {category='pubsub', type='pep'}):up();
	stanza:tag('feature', {var='http://jabber.org/protocol/pubsub#access-presence'}):up();
	stanza:tag('feature', {var='http://jabber.org/protocol/pubsub#auto-create'}):up();
	stanza:tag('feature', {var='http://jabber.org/protocol/pubsub#create-and-configure'}):up();
	stanza:tag('feature', {var='http://jabber.org/protocol/pubsub#create-nodes'}):up();
	stanza:tag('feature', {var='http://jabber.org/protocol/pubsub#delete-items'}):up();
	stanza:tag('feature', {var='http://jabber.org/protocol/pubsub#delete-nodes'}):up();
	stanza:tag('feature', {var='http://jabber.org/protocol/pubsub#filtered-notifications'}):up();
	stanza:tag("feature", {var='http://jabber.org/protocol/pubsub#persistent-items'}):up();
	stanza:tag('feature', {var='http://jabber.org/protocol/pubsub#publish'}):up();
	stanza:tag('feature', {var='http://jabber.org/protocol/pubsub#purge-nodes'}):up();
	stanza:tag('feature', {var='http://jabber.org/protocol/pubsub#retrieve-items'}):up();
	stanza:tag('feature', {var='http://jabber.org/protocol/pubsub#subscribe'}):up();
end);

module:hook("account-disco-items", function(event)
	local stanza = event.stanza;
	local bare = stanza.attr.to;
	local user_data = services[bare].nodes;

	if user_data then
		for node, _ in pairs(user_data) do
			stanza:tag('item', {jid=bare, node=node}):up();
		end
	end
end);

local function get_caps_hash_from_presence(stanza, current)
	local t = stanza.attr.type;
	if not t then
		for _, child in pairs(stanza.tags) do
			if child.name == "c" and child.attr.xmlns == "http://jabber.org/protocol/caps" then
				local attr = child.attr;
				if attr.hash then -- new caps
					if attr.hash == 'sha-1' and attr.node and attr.ver then return attr.ver, attr.node.."#"..attr.ver; end
				else -- legacy caps
					if attr.node and attr.ver then return attr.node.."#"..attr.ver.."#"..(attr.ext or ""), attr.node.."#"..attr.ver; end
				end
				return; -- bad caps format
			end
		end
	elseif t == "unavailable" or t == "error" then
		return;
	end
	return current; -- no caps, could mean caps optimization, so return current
end

module:hook("presence/bare", function(event)
	-- inbound presence to bare JID recieved           
	local origin, stanza = event.origin, event.stanza;
	local user = stanza.attr.to or (origin.username..'@'..origin.host);
	local t = stanza.attr.type;
	local self = not stanza.attr.to;
	
	if not services[user] then return nil; end -- User Service doesn't exist
	local nodes = services[user].nodes;
	
	if not t then -- available presence
		if self or subscription_presence(user, stanza.attr.from) then
			local recipient = stanza.attr.from;
			local current = services[user].recipients and services[user].recipients[recipient];
			local hash = get_caps_hash_from_presence(stanza, current);
			if current == hash or (current and current == services[user].hash_map[hash]) then return; end
			if not hash then
				services[user].recipients[recipient] = nil;
			else
				if services[user].hash_map[hash] then
					services[user].recipients[recipient] = services[user].hash_map[hash];
					for node, object in pairs(nodes) do
						object.subscribers[recipient] = true;
						if services[user].recipients[recipient][node] then
							local ok, items, orderly = services[user]:get_items(node, stanza.attr.from);
							if items then
								for _, id in ipairs(array(orderly):reverse()) do
									services[user]:broadcaster(node, recipient, items[id]);
								end
							end
						end
					end
				else
					services[user].recipients[recipient] = hash;
					local from_bare = origin.type == "c2s" and origin.username.."@"..origin.host;
					if self or origin.type ~= "c2s" or (from_bare and origin.full_jid and services[from_bare] and services[from_bare].recipients and services[from_bare].recipients[origin.full_jid]) ~= hash then
						-- COMPAT from ~= stanza.attr.to because OneTeam can't deal with missing from attribute
						origin.send(
							st.stanza("iq", {from=user, to=stanza.attr.from, id="disco", type="get"})
								:query("http://jabber.org/protocol/disco#info")
						);
						module:log("debug", "Sending disco info query to: "..stanza.attr.from);
					end
				end
			end
		end
	elseif t == "unavailable" then
		for name in pairs((type(services[user].recipients[stanza.attr.from]) == "table" and services[user].recipients[stanza.attr.from]) or NULL) do
			if nodes[name] then nodes[name].subscribers[stanza.attr.from] = nil; end
		end
		services[user].recipients[stanza.attr.from] = nil;
	elseif not self and t == "unsubscribe" then
		local from = jid_bare(stanza.attr.from);
		local subscriptions = services[user].recipients;
		if subscriptions then
			for subscriber in pairs(subscriptions) do
				if jid_bare(subscriber) == from then
					for name in pairs((type(services[user].recipients[stanza.attr.from]) == "table" and services[user].recipients[stanza.attr.from]) or NULL) do
						if nodes[name] then nodes[name].subscribers[subscriber] = nil; end
					end
					services[user].recipients[subscriber] = nil;
				end
			end
		end
	end
end, 10);

module:hook("iq-result/bare/disco", function(event)
	local session, stanza = event.origin, event.stanza;
	if stanza.attr.type == "result" then
		local disco = stanza.tags[1];
		if disco and disco.name == "query" and disco.attr.xmlns == "http://jabber.org/protocol/disco#info" then
			-- Process disco response
			local self = not stanza.attr.to;
			local user = stanza.attr.to or (session.username..'@'..session.host);
			if not services[user] then return nil; end -- User's pep service doesn't exist
			module:log("debug", "Processing disco response from %s", stanza.attr.from);
			local nodes = services[user].nodes;
			local contact = stanza.attr.from;
			local current = services[user].recipients[contact];
			if type(current) ~= "string" then return; end -- check if waiting for recipient's response
			local ver = current;
			if not string.find(current, "#") then
				ver = calculate_hash(disco.tags); -- calculate hash
			end
			local notify = {};
			for _, feature in pairs(disco.tags) do
				if feature.name == "feature" and feature.attr.var then
					local nfeature = feature.attr.var:match("^(.*)%+notify$");
					if nfeature then notify[nfeature] = true; end
				end
			end
			services[user].hash_map[ver] = notify; -- update hash map
			if self then
				for jid, item in pairs(session.roster) do -- for all interested contacts
					if item.subscription == "both" or item.subscription == "from" then
						services[user].recipients[contact] = notify;
						for node, object in pairs(nodes) do
							if services[user].recipients[contact][node] then
								object.subscribers[contact] = true;
								local ok, items, orderly = services[user]:get_items(node, stanza.attr.from);
								if items then
									for _, id in ipairs(array(orderly):reverse()) do
										services[user]:broadcaster(node, contact, items[id]);
									end
								end
							end
						end
					end
				end
			end
			services[user].recipients[contact] = notify;
			for node in pairs(nodes) do
				local ok, items, orderly = services[user]:get_items(node, stanza.attr.from);
				if items then
					for _, id in ipairs(array(orderly):reverse()) do
						services[user]:broadcaster(node, contact, items[id]);
					end
				end
			end
		end
	end
end);

local admin_aff = "owner";
local function get_affiliation(self, jid)
	local bare_jid = jid_bare(jid);
	if bare_jid == jid_bare(jid) then
		return admin_aff;
	end
end

function set_service(new_service, jid)
	services[jid] = new_service;
	services[jid]["hash_map"] = {};
	services[jid]["name"] = jid;
	services[jid]["recipients"] = {};
	module.environment.services[jid] = services[jid];
	disco_info = build_disco_info(services[jid]);
	services[jid]:restore();
end

local function normalize_dummy(jid)
	return jid;
end

function pep_new(node)
	-- this needs a fix.
	local path = getpath(node, module:get_host(), "pep"):match("^(.*)%.[^%.]*$")
	local pre_path = path:match("^(.*)/[^/]*$")
	local p_attributes = lfs.attributes(path);
	local pp_attributes = lfs.attributes(pre_path);

	if pp_attributes == nil then lfs.mkdir(pre_path); end
	if attributes == nil then lfs.mkdir(path); end

	local new_service = {
			capabilities = {
				none = {
					create = false;
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
				persist_items = false;
			};

			autocreate_on_publish = true;
			autocreate_on_subscribe = true;

			broadcaster = broadcast;
			get_affiliation = get_affiliation;

			normalize_jid = normalize_dummy;

			store = storagemanager.open(module.host, "pep/"..node);
		};

	return new_service;
end

function module.save()
	return { services = services };
end

function module.restore(data)
	services = data.services or {};
	for id in pairs(services) do
		username = jid_split(id);
		services[id].config = pep_new(user);
	end
end
