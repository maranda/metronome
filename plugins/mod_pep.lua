-- * Metronome IM *
--
-- This file is part of the Metronome XMPP server and is released under the
-- ISC License, please see the LICENSE file in this source package for more
-- information about copyright and licensing.

local hosts = hosts;
local ripairs, tonumber, type, os_remove, os_time, select, setmetatable, t_insert = 
	ripairs, tonumber, type, os.remove, os.time, select, setmetatable, table.insert;

local pubsub = require "util.pubsub";
local st = require "util.stanza";
local jid_bare = require "util.jid".bare;
local jid_join = require "util.jid".join;
local jid_split = require "util.jid".split;
local uuid_generate = require "util.uuid".generate;
local calculate_hash = require "util.caps".calculate_hash;
local encode_node = require "util.datamanager".path_encode;
local get_path = require "util.datamanager".getpath;
local um_user_exists = require "core.usermanager".user_exists;
local storagemanager = require "core.storagemanager";

local xmlns_pubsub = "http://jabber.org/protocol/pubsub";
local xmlns_pubsub_owner = "http://jabber.org/protocol/pubsub#owner";

hash_map = {};
services = {};
local disco_ids = setmetatable({}, { __mode = "v" });
local handlers = {};
local handlers_owner = {};
local NULL = {};

-- Define aux library imports

local pep_lib = module:require "pep_aux";
pep_lib.set_closures(services, hash_map);
local features = pep_lib.features;
local singleton_nodes = pep_lib.singleton_nodes;
local pep_error_reply = pep_lib.pep_error_reply;
local subscription_presence = pep_lib.subscription_presence;
local get_caps_hash_from_presence = pep_lib.get_caps_hash_from_presence;
local pep_send = pep_lib.pep_send;
local pep_autosubscribe_recs = pep_lib.pep_autosubscribe_recs;
local send_config_form = pep_lib.send_config_form;
local process_config_form = pep_lib.process_config_form;
local send_options_form = pep_lib.send_options_form;
local process_options_form = pep_lib.process_options_form;
local pep_new = pep_lib.pep_new;

-- Helpers

singleton_nodes:add_list(module:get_option("pep_custom_singleton_nodes"));

local check_service_inactivity = module:get_option_number("pep_check_service_inactivity", 3600);
module:add_timer(check_service_inactivity, function()
	module:log("debug", "Checking for idle PEP Services...");
	for name, service in pairs(services) do
		if not module:get_bare_session(name) then
			module:log("debug", "Deactivated inactive PEP Service -- %s", name);
			services[name] = nil;
		end
	end
	return check_service_inactivity;
end);

local function disco_info_query(from, to)
	local id = uuid_generate();
	disco_ids[id] = true;
	module:log("debug", "Sending disco info query to: %s", to);
	module:fire_global_event("route/post", hosts[module.host], 
		st.stanza("iq", { from = from, to = to, id = id, type = "get" })
			:query("http://jabber.org/protocol/disco#info")
	);
end

local function probe_jid(from, to)
	module:fire_global_event("route/post", hosts[module.host], 
		st.presence({from = from, to = to, id="peptrigger", type="probe"}));
	module:log("debug", "Sending trigger probe to: %s", to);
end

-- Module definitions

function handle_pubsub_iq(event)
	local origin, stanza = event.origin, event.stanza;
	local user = stanza.attr.to or jid_join(origin.username, origin.host);
	local full_jid = origin.full_jid;
	local username, host = jid_split(user);
	local time_now = os_time();
	local user_service = services[user];
	if not user_service and um_user_exists(username, host) then -- create service on demand.
		user_service = set_service(pubsub.new(pep_new(username)), user, true);
		user_service.is_new = true;
	end

	if not user_service then return; end

	local pubsub = stanza.tags[1];
	local action = pubsub.tags[1];
	if not action then return origin.send(pep_error_reply(stanza, "bad-request")); end
	local handler = handlers[stanza.attr.type.."_"..action.name];
	local config;
	if action.name == "create" then
		config = (pubsub.tags[2] and pubsub.tags[2].name == "configure") and pubsub.tags[2];
	elseif action.name == "publish" then
		config = (pubsub.tags[2] and pubsub.tags[2].name == "publish-options") and pubsub.tags[2];
	end
	local handler;

	if pubsub.attr.xmlns == xmlns_pubsub_owner then
		handler = handlers_owner[stanza.attr.type.."_"..action.name];
	else
		handler = handlers[stanza.attr.type.."_"..action.name];
	end	

	if handler then
		if not config then 
			handler(user_service, origin, stanza, action); 
		else 
			handler(user_service, origin, stanza, action, config); 
		end

		if user_service.is_new and not user_service.starting then 
			return module:fire_event(
				"pep-boot-service", { service = user_service, from = stanza.attr.from or origin.full_jid }
			);
		else
			return true;
		end
	else
		return origin.send(pep_error_reply(stanza, "feature-not-implemented"));
	end
end

-- Pubsub handlers

function handlers.get_affiliations(service, origin, stanza, action)
	local node = action.attr.node;
	local ok, ret, reply;
	if not node then
		return origin.send(pep_error_reply(stanza, "no-node-affiliations"));
	end
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
		reply = pep_error_reply(stanza, ret);
	end
	return origin.send(reply);
end

function handlers.get_items(service, origin, stanza, items)
	local node = items.attr.node;
	local max = items and items.attr.max_items and tonumber(items.attr.max_items);
	local item = items:get_child("item");
	local id = item and item.attr.id;

	local ok, results, max_tosend = service:get_items(node, stanza.attr.from, id, max);
	if not ok then
		return origin.send(pep_error_reply(stanza, results));
	end
	
	local data = st.stanza("items", { node = node });
	if not max or max == 0 then
		for _, id in ripairs(max_tosend) do data:add_child(results[id]); end
	else
		for _, id in ipairs(max_tosend) do data:add_child(results[id]); end		
	end

	local reply = st.reply(stanza)
		:tag("pubsub", { xmlns = xmlns_pubsub })
			:add_child(data);

	return origin.send(reply);
end

handlers["get_publish-options"] = function(service, origin, stanza, action)
	local node = action.attr.node;
	if not node then
		return origin.send(pep_error_reply(stanza, "feature-not-implemented"));
	end

	local node_obj = service.nodes[node];
	if not node_obj then
		return origin.send(pep_error_reply(stanza, "item-not-found"));
	end

	if node_obj.config.publish_model == "open" or service:may(node, from, "publish") then
		return send_options_form(service, node, origin, stanza);
	else
		return origin.send(pep_error_reply(stanza, "forbidden"));
	end
end

function handlers.set_create(service, origin, stanza, create, config)
	local node = create.attr.node;
	local ok, ret, reply;

	local node_config;
	if config then
		local form = config:get_child("x", "jabber:x:data");
		ok, node_config = process_config_form(service, node, form, true);
		if not ok then return origin.send(pep_error_reply(stanza, node_config)); end
	end

	if singleton_nodes:contains(node) and not node_config then
		node_config = { max_items = 1 };
	elseif node_config and not node_config.max_items and singleton_nodes:contains(node) then
		node_config.max_items = 1;
	end

	if node then
		ok, ret = service:create(node, stanza.attr.from, node_config);
		if ok then
			reply = st.reply(stanza);
		else
			reply = pep_error_reply(stanza, ret);
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
			reply = pep_error_reply(stanza, ret);
		end
	end

	if ok then -- auto-resubscribe interested recipients
		module:fire_event("pep-node-created", { node = node, origin = origin, service = service });
		pep_autosubscribe_recs(service, node);
	end
	return origin.send(reply);
end

function handlers.set_publish(service, origin, stanza, publish, config)
	local node = publish.attr.node;
	local from = stanza.attr.from or origin.full_jid;
	local item = publish:get_child("item");
	local recs = {};
	local recs_count = 0;
	local id = (item and item.attr.id) or uuid_generate();
	local form, ok, ret, reply;
	
	if item and not item.attr.id then item.attr.id = id; end
	if not service.nodes[node] then
	-- normally this would be handled just by publish() but we have to preceed its broadcast,
	-- so since autocreate on publish is in place, do create and then resubscribe interested items.
		local node_config;
		if config then
			form = config:get_child("x", "jabber:x:data");
			ok, node_config = process_options_form(service, node, form);
			if not ok then return origin.send(pep_error_reply(stanza, node_config)); end
		end
		
		if not node_config and singleton_nodes:contains(node) then 
			node_config = { max_items = 1 };
		elseif node_config and not node_config.max_items and singleton_nodes:contains(node) then
			node_config.max_items = 1;
		end
		service:create(node, from, node_config);
		pep_autosubscribe_recs(service, node);
	elseif service.nodes[node] and config then
		-- Test preconditions
		form = config:get_child("x", "jabber:x:data");
		ok, ret = process_options_form(service, node, form);
		if not ok then return origin.send(pep_error_reply(stanza, ret)); end
	end

	ok, ret = service:publish(node, from, id, item);
		
	if ok then
		module:fire_event("pep-node-publish", { from = from, id = id, item = item, node = node, origin = origin, service = service });
		reply = st.reply(stanza)
			:tag("pubsub", { xmlns = xmlns_pubsub })
				:tag("publish", { node = node })
					:tag("item", { id = id });
	else
		reply = pep_error_reply(stanza, ret);
	end

	return origin.send(reply);
end

function handlers.set_retract(service, origin, stanza, retract)
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
		module:fire_event("pep-node-retract", { from = stanza.attr.from, id = id, node = node, origin = origin, service = service });
		reply = st.reply(stanza);
	else
		reply = pep_error_reply(stanza, ret);
	end
	return origin.send(reply);
end

-- Pubsub owner handlers

function handlers_owner.get_affiliations(service, origin, stanza, action)
	local node = action.attr.node;
	local ok, ret, reply;
	if not node then
		return origin.send(pep_error_reply(stanza, "no-node-affiliations"));
	end
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
		reply = pep_error_reply(stanza, ret);
	end
	return origin.send(reply);
end

function handlers_owner.get_configure(service, origin, stanza, action)
	local node = action.attr.node;
	if not node then
		return origin.send(pep_error_reply(stanza, "feature-not-implemented"));
	end

	if not service.nodes[node] then
		return origin.send(pep_error_reply(stanza, "item-not-found"));
	end

	local ret = service:get_affiliation(stanza.attr.from, node);

	if ret == "owner" then
		return send_config_form(service, node, origin, stanza);
	else
		return origin.send(pep_error_reply(stanza, "forbidden"));
	end
end

function handlers_owner.set_affiliations(service, origin, stanza, action)
	local node = action.attr.node;
	if not service.nodes[node] then
		return origin.send(pep_error_reply(stanza, "item-not-found"));
	end

	if not service:may(node, stanza.attr.from, "set_affiliation") then
		return origin.send(pep_error_reply(stanza, "forbidden"));
	end	

	local _to_change = {};
	for _, tag in ipairs(action.tags) do
		if tag.attr.jid and tag.attr.affiliation then
			if tag.attr.jid == service.name and tag.attr.affiliation == "none" then
				return origin.send(pep_error_reply(stanza, "forbidden"));
			end
			_to_change[tag.attr.jid] = tag.attr.affiliation;
		end
	end
	
	local ok, err;
	for jid, affiliation in pairs(_to_change) do
		ok, err = service:set_affiliation(node, true, jid, affiliation);
		if not ok then
			return origin.send(pep_error_reply(stanza, err));
		end
	end

	return origin.send(st.reply(stanza));
end

function handlers_owner.set_configure(service, origin, stanza, action)
	local node = action.attr.node;
	if not node then
		return origin.send(pep_error_reply(stanza, "feature-not-implemented"));
	end

	if not service.nodes[node] then
		return origin.send(pep_error_reply(stanza, "item-not-found"));
	end

	local ret = service:get_affiliation(stanza.attr.from, node)
	
	local reply;
	if ret == "owner" then
		local form = action:get_child("x", "jabber:x:data");
		if form and form.attr.type == "cancel" then
			return origin.send(st.reply(stanza));
		end

		local ok, ret = process_config_form(service, node, form);
		if ok then reply = st.reply(stanza); else reply = pep_error_reply(stanza, ret); end
	else
		reply = pep_error_reply(stanza, "forbidden");
	end
	return origin.send(reply);
end

function handlers_owner.set_delete(service, origin, stanza, delete)
	local node = delete.attr.node;
	local ok, ret, reply;
	if node then
		ok, ret = service:delete(node, stanza.attr.from);
		if ok then
			module:fire_event("pep-node-deleted", { node = node, origin = origin, service = service });
			reply = st.reply(stanza);
		else
			reply = pep_error_reply(stanza, ret);
		end
	else
		reply = pep_error_reply(stanza, "bad-request");
	end
	return origin.send(reply);
end

function handlers_owner.set_purge(service, origin, stanza, purge)
	local node = purge.attr.node;
	local ok, ret, reply;
	if node then
		ok, ret = service:purge(node, stanza.attr.from);
		if ok then
			module:fire_event("pep-node-purged", { node = node, origin = origin, service = service });
			reply = st.reply(stanza);
		else
			reply = pep_error_reply(stanza, ret);
		end
	else
		reply = pep_error_reply(stanza, "bad-request");
	end
	return origin.send(reply);
end

-- Handlers end

module:hook("iq/bare/http://jabber.org/protocol/pubsub:pubsub", handle_pubsub_iq);
module:hook("iq/bare/http://jabber.org/protocol/pubsub#owner:pubsub", handle_pubsub_iq);

local function append_disco_features(stanza)
	stanza:tag("identity", { category = "pubsub", type = "pep" }):up();
	stanza:tag("feature", { var = "http://jabber.org/protocol/disco#items" }):up();
	stanza:tag("feature", { var = "http://jabber.org/protocol/pubsub#pubsub-on-a-jid" }):up();
	for _, feature in ipairs(features) do stanza:tag("feature", { var = feature }):up(); end
end

module:hook("account-disco-info", function(event)
	local origin, stanza, node = event.origin, event.stanza, event.node;
	if node then
		local user = jid_bare(stanza.attr.to) or jid_join(origin.username, origin.host);
		local service = services[user];
		if not service then
			stanza[false] = true; 
			stanza.type = "cancel"; stanza.condition = "service-unavailable";
			stanza.description = "User service not found or currently deactivated";
			return; 
		end
		
		local ok, ret = service:get_nodes(stanza.attr.from or user);
		if ok and ret[node] then
			stanza:tag("identity", { category = "pubsub", type = "leaf" }):up();
			service:append_metadata(node, stanza);
			return;
		end
		
		stanza[false] = true;
		stanza.error = (not ok and ret) or "item-not-found";
		stanza.callback = pep_error_reply;
		return true;
	else
		append_disco_features(stanza);
	end
end, 50);

module:hook("account-disco-items", function(event)
	local reply, node = event.reply, event.node;
	local bare = jid_bare(reply.attr.to);
	local user_data = services[bare] and services[bare].nodes;

	if user_data then
		if node then
			local ok, ret, orderly = services[bare]:get_items(node, true);
			if ok then
				reply.tags[1].attr.node = node;
				for _, id in pairs(orderly) do
					reply:tag("item", { jid = bare, name = id }):up();
				end
			else
				reply = pep_error_reply(event.stanza, ret);
				reply.attr.from = bare; return reply;
			end
		else
			for node, data in pairs(user_data) do
				reply:tag("item", { jid = bare, node = node, name = data.config.title }):up();
			end
		end
	end
end);

function presence_handler(event)
	local origin, stanza = event.origin, event.stanza;
	local user = jid_bare(stanza.attr.to) or jid_join(origin.username, origin.host);
	local t = stanza.attr.type;
	local self = not stanza.attr.to;
	local service = services[user];
	local user_bare_session = module:get_bare_session(user);
	
	if not service then return nil; end -- User Service doesn't exist
	local nodes = service.nodes;
	local recipients = service.recipients;
	
	if not t then -- available presence
		if self or subscription_presence(user, stanza.attr.from) then
			local recipient = stanza.attr.from;
			local current = recipients and recipients[recipient];
			local hash = get_caps_hash_from_presence(stanza);
			if not hash then
				if current then	
					hash = current;
				else
					-- We shall drop sending disco infos to all clients which don't include caps
					-- in their presence, it's not perfect, but it's the only way to get optimal
					-- non-volatile states.
					current = false;
					recipients[recipient] = false;
				end
			else
				recipients[recipient] = hash;
			end

			if not hash_map[hash] then
				if current ~= false then disco_info_query(user, recipient); end
			else
				local bare_recipient = jid_bare(recipient);
				if user == bare_recipient and not origin.sent_initial_pep_notifications then
					origin.sent_initial_pep_notifications = true;
					pep_send(recipient, user);
				elseif user ~= bare_recipient then
					pep_send(recipient, user);
				end
			end
			if self and not user_bare_session.initial_pep_broadcast then -- re-broadcast to all interested contacts on connect, shall we?
				local our_jid = origin.full_jid;
				module:log("debug", "%s -- account service sending initial re-broadcast...", user);
				for jid in pairs(recipients) do
					if jid ~= our_jid then pep_send(jid, user); end
				end
				user_bare_session.initial_pep_broadcast = true;
			end
		end
	elseif t == "unavailable" and recipients[stanza.attr.from] then
		local from = stanza.attr.from;
		local client_map = hash_map[recipients[from]];
		for name in pairs(client_map or NULL) do
			if nodes[name] then nodes[name].subscribers[from] = nil; end
		end
		recipients[from] = nil;
	elseif not self and (t == "unsubscribe" or t == "unsubscribed") then
		local from = jid_bare(stanza.attr.from);
		local subscriptions = recipients;
		if subscriptions then
			for subscriber in pairs(subscriptions) do
				if jid_bare(subscriber) == from then
					local client_map = hash_map[recipients[subscriber]];
					for name in pairs(client_map or NULL) do
						if nodes[name] then nodes[name].subscribers[subscriber] = nil; end
					end
					recipients[subscriber] = nil;
				end
			end
		end
	end
end


module:hook("presence/bare", presence_handler, 110);
module:hook("presence/full", presence_handler, 110);

module:hook("pep-boot-service", function(event)
	local service, from = event.service, event.from;
	local user = service.name;
	service.starting = true;
	services[user] = service;
	module:log("debug", "Delaying broadcasts as %s service is being booted...", user);
	if subscription_presence(user, from) then
		service.recipients[from] = "";
		disco_info_query(user, from);
	end
	return true;
end, 100);

module:hook("pep-get-service", function(username, spawn, from)
	local user = jid_join(username, module.host);
	local service = services[user];
	if spawn and from and not service and um_user_exists(username, module.host) then
		service = set_service(pubsub.new(pep_new(username)), user, true);
		service.is_new = true;
		module:fire_event("pep-boot-service", { service = service, from = from });
	end
	return service;
end);

module:hook("pep-autosubscribe-recipients", function(service, node)
	pep_autosubscribe_recs(service, node);
	return true;
end);

module:hook("iq-result/bare", function(event, result_id)
	if not disco_ids[result_id] then return; end

	local session, stanza = event.origin, event.stanza;
	local disco = stanza.tags[1];
	if disco and disco.name == "query" and disco.attr.xmlns == "http://jabber.org/protocol/disco#info" then
		-- Process disco response
		local user = stanza.attr.to or jid_join(session.username, session.host);
		local service = services[user];
		if not service then return true; end -- User's pep service doesn't exist
		local nodes = service.nodes;
		local recipients = service.recipients;
		local contact = stanza.attr.from;
		local current = recipients[contact];
		if not current then return true; end

		module:log("debug", "Processing disco response from %s", stanza.attr.from);
		local ver = current;
		if not string.find(current, "#") then
			ver = calculate_hash(disco.tags); -- calculate hash
		end
		local notify = {};
		local has_notify = false;
		for _, feature in pairs(disco.tags) do
			if feature.name == "feature" and feature.attr.var then
				local nfeature = feature.attr.var:match("^(.*)%+notify$");
				if nfeature then notify[nfeature] = true; has_notify = true; end
			end
		end
		if not has_notify then 
			hash_map[ver] = notify;
			recipients[contact] = false;
			return true;
		end
		hash_map[ver] = notify; -- update hash map
		recipients[contact] = ver; -- and contact hash
		if service.is_new then
			service.is_new = nil;
			module:log("debug", "Sending probes to roster contacts to discover interested resources...");
			for jid, item in pairs(session.roster or NULL) do -- for all interested contacts
				if item.subscription == "both" or item.subscription == "from" then
					probe_jid(session.full_jid, jid);
				end
			end
			service.starting = nil;
		end
		pep_send(contact, user);
		disco_ids[result_id] = nil;
		return true; -- end cb processing.
	end
end, -1);

module:hook("resource-unbind", function(event)
	local session = event.session;
	local has_sessions = module:get_bare_session(session.username);

	if not has_sessions then -- wipe recipients
		local service = services[jid_join(session.username, session.host)];
		if not service then return; end
		service.recipients = {};
		local nodes = service.nodes;
		for _, node in pairs(nodes) do node.subscribers = {}; end
	end
end);

module:hook_global("user-deleted", function(event)
	local username, host = event.username, event.host;

	if host == module.host then
		local jid = jid_join(username, host);
		local encoded_node = encode_node(username);
		local service = services[jid] or set_service(pubsub.new(pep_new(username)), jid, true);
		local nodes = service.nodes;
		local store = service.config.store;

		for node in pairs(nodes) do
			module:log("debug", "Wiped %s's node %s", jid, node);
			store:set(node, nil); 
		end
		store:set(nil, nil);
		services[jid] = nil;

		local type = select(2, storagemanager.get_driver(host));
		if type == "internal" then
			local path = get_path(encoded_node, host, "pep"):match("^(.*)%.");
			local done = os_remove(path);

			if done then
				module:log("debug", "Removed %s pep store directory (%s)", jid, path);
			end
		end
	end	
end, 100);

function set_service(new_service, jid, restore)
	services[jid] = new_service;
	services[jid].name = jid;
	services[jid].recipients = {};
	module.environment.services[jid] = services[jid];
	if restore then 
		services[jid]:restore(); 
		for name, node in pairs(services[jid].nodes) do 
			node.subscribers = {};
			services[jid]:save_node(name);
		end
	end
	return services[jid];
end

function module.load()
	module:add_identity("pubsub", "pep", "Metronome");
	for _, feature in ipairs(features) do module:add_feature(feature); end
end

function module.save()
	return { hash_map = hash_map, services = services };
end

function module.restore(data)
	hash_map = data.hash_map or {};
	local _services = data.services or {};
	for id, service in pairs(_services) do
		username = jid_split(id);
		services[id] = set_service(pubsub.new(pep_new(username)), id);
		services[id].nodes = service.nodes or {};
		services[id].recipients = service.recipients or {};
	end
	pep_lib.set_closures(services, hash_map);
end
