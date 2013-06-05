-- * Metronome IM *
--
-- This file is part of the Metronome XMPP server and is released under the
-- ISC License, please see the LICENSE file in this source package for more
-- information about copyright and licensing.

local events = require "util.events";
local keys = require "util.iterators".keys;
local st = require "util.stanza";
local table = table;
local type = type;

module("pubsub", package.seeall);

local service = {};
local service_mt = { __index = service };

local default_config = {
	broadcaster = function () end;
	get_affiliation = function () end;
	capabilities = {};
};

function new(config)
	config = config or {};
	return setmetatable({
		config = setmetatable(config, { __index = default_config });
		affiliations = {};
		subscriptions = {};
		nodes = {};
		events = events.new();
	}, service_mt);
end

function service:jids_equal(jid1, jid2)
	local normalize = self.config.normalize_jid;
	return normalize(jid1) == normalize(jid2);
end

function service:may(node, actor, action)
	-- Employ normalization
	if type(actor) ~= "boolean" then actor = self.config.normalize_jid(actor); end

	if actor == true then return true; end
	
	local node_obj = self.nodes[node];
	local node_aff = node_obj and node_obj.affiliations[actor];
	local service_aff = self.affiliations[actor]
	                 or self:get_affiliation(actor, node, action)
	                 or "none";

	-- Check if node allows/forbids it
	local node_capabilities = node_obj and node_obj.capabilities;
	if node_capabilities then
		local caps = node_capabilities[node_aff or service_aff];
		if caps then
			local can = caps[action];
			if can ~= nil then
				return can;
			end
		end
	end
	
	-- Check service-wide capabilities instead
	local service_capabilities = self.config.capabilities;
	local caps = service_capabilities[node_aff or service_aff];
	if caps then
		local can = caps[action];
		if can ~= nil then
			return can;
		end
	end
	
	return false;
end

function service:broadcaster(node, subscribers, item)
	return self.config.broadcaster(self, node, subscribers, item);
end

function service:get_affiliation(jid, node, action)
	return self.config.get_affiliation(self, jid, node, action);
end

function service:get_affiliations(node, actor, owner)
	local nodes = self.nodes;
	local node_obj = nodes[node];
	if node and not node_obj then
		return false, "item-not-found";
	end

	if not self:may(node, actor, "get_affiliations") then
		return false, "forbidden";
	end

	local jid = self.config.normalize_jid and self.config.normalize_jid(actor) or actor;
	local results, has_results = {}, false;

	-- self affiliation check
	if not owner and node and node_obj.affiliations[jid] then
		results[node] = node_obj.affiliations[jid];
		return true, results;
	elseif not owner and node and not node_obj.affiliations[jid] then
		return true, nil;
	elseif not owner and not node then
		for name, object in pairs(nodes) do
			if object.affiliations[jid] then
				has_results = true;
				results[name] = object.affiliations[jid];
			end
		end
	elseif owner and node_obj then
		for jid, affiliation in pairs(node_obj.affiliations) do
			has_results = true;
			results[jid] = affiliation;
		end
	end

	return true, has_results and results or nil;
end

function service:set_affiliation(node, actor, jid, affiliation)
	local node_obj = self.nodes[node];
	if not node_obj then
		return false, "item-not-found";
	end

	if not self:may(node, actor, "set_affiliation") then
		return false, "forbidden";
	end

	if (node_obj.capabilities and not node_obj.capabilities[affiliation]) or
	   not self.config.capabilities[affiliation] then
		return false, "bad-request";
	end

	jid = (self.config.normalize_jid and self.config.normalize_jid(jid)) or jid;
	if affiliation == "none" then -- is this correct?
		node_obj.affiliations[jid] = nil;
		self:save_node(node);
		return true;
	end

	node_obj.affiliations[jid] = affiliation;
	local _, jid_sub = self:get_subscription(node, true, jid);
	if not jid_sub and not self:may(node, jid, "be_unsubscribed") then
		local ok, err = self:add_subscription(node, true, jid);
		if not ok then
			return ok, err;
		end
	elseif jid_sub and not self:may(node, jid, "be_subscribed") then
		local ok, err = self:add_subscription(node, true, jid);
		if not ok then
			return ok, err;
		end
	end
	self:save_node(node);
	return true;
end

function service:add_subscription(node, actor, jid, options)
	local cap;
	if actor == true or jid == actor or self:jids_equal(actor, jid) then
		cap = "subscribe";
	else
		cap = "subscribe_other";
	end

	local can_subscribe, be_subscribed = self:may(node, actor, cap), self:may(node, jid, "be_subscribed");

	local node_obj = self.nodes[node];
	if not node_obj then
		if not self.config.autocreate_on_subscribe then
			return false, "item-not-found";
		elseif can_subscribe and be_subscribed then			
			local ok, err = self:create(node, true);
			if not ok then
				return ok, err;
			end
			node_obj = self.nodes[node];
		else
			return false, "forbidden";
		end
	end

	if not can_subscribe or not be_subscribed then
		return false, "forbidden";
	end

	if type(actor) ~= "boolean" 
	   and node_obj.config.access_model == "whitelist"
	   and self:get_affiliation(actor, node, action) ~= "owner" then
		local is_whitelisted = (node_obj.affiliation[actor] ~= nil or node_obj.affiliation[actor] ~= "outcast") and true;
		if cap == "subscribe" and not is_whitelisted then return false, "forbidden"; end
	end

	node_obj.subscribers[jid] = options or true;
	local normal_jid = self.config.normalize_jid(jid);
	local subs = self.subscriptions[normal_jid];
	if subs then
		if not subs[jid] then
			subs[jid] = { [node] = true };
		else
			subs[jid][node] = true;
		end
	else
		self.subscriptions[normal_jid] = { [jid] = { [node] = true } };
	end
	self.events.fire_event("subscription-added", { node = node, jid = jid, normalized_jid = normal_jid, options = options });
	self:save_node(node);
	return true;
end

function service:remove_subscription(node, actor, jid)
	local node_obj = self.nodes[node];
	if not node_obj then
		return false, "item-not-found";
	end

	local cap;
	if actor == true or jid == actor or self:jids_equal(actor, jid) then
		cap = "unsubscribe";
	else
		cap = "unsubscribe_other";
	end
	if not self:may(node, actor, cap) then
		return false, "forbidden";
	end
	if not self:may(node, jid, "be_unsubscribed") then
		return false, "forbidden";
	end

	if not node_obj.subscribers[jid] then
		return false, "not-subscribed";
	end
	node_obj.subscribers[jid] = nil;
	local normal_jid = self.config.normalize_jid(jid);
	local subs = self.subscriptions[normal_jid];
	if subs then
		local jid_subs = subs[jid];
		if jid_subs then
			jid_subs[node] = nil;
			if next(jid_subs) == nil then
				subs[jid] = nil;
			end
		end
		if next(subs) == nil then
			self.subscriptions[normal_jid] = nil;
		end
	end
	self.events.fire_event("subscription-removed", { node = node, jid = jid, normalized_jid = normal_jid });
	self:save_node(node);
	return true;
end

function service:remove_all_subscriptions(actor, jid)
	local normal_jid = self.config.normalize_jid(jid);
	local subs = self.subscriptions[normal_jid]
	subs = subs and subs[jid];
	if subs then
		for node in pairs(subs) do
			self:remove_subscription(node, true, jid);
		end
	end
	self:save_node(node);
	return true;
end

function service:get_subscription(node, actor, jid)
	local cap;
	if actor == true or jid == actor or self:jids_equal(actor, jid) then
		cap = "get_subscription";
	else
		cap = "get_subscription_other";
	end

	local node_obj = self.nodes[node];
	if not node_obj then
		return false, "item-not-found";
	end

	if not self:may(node, actor, cap) then
		return false, "forbidden";
	end

	return true, node_obj.subscribers[jid];
end

function service:create(node, actor, config)
	if not self:may(node, actor, "create") then
		return false, "forbidden";
	end

	if self.nodes[node] then
		return false, "conflict";
	end

	local _node_default_config;
	if self.config.node_default_config then
		_node_default_config = {};
		for option, value in pairs(self.config.node_default_config) do	_node_default_config[option] = value; end
	end
	
	self.nodes[node] = {
		name = node;
		subscribers = {};
		config = _node_default_config or {};
		data = {};
		data_id = {};
		affiliations = {};
	};

	if config then
		for entry, value in pairs(config) do
			self.nodes[node].config[entry] = value;
		end
	end

	local ok, err = self:set_affiliation(node, true, actor, "owner");
	if not ok then
		self.nodes[node] = nil
		return ok, err;
	end
	ok, err = self:save_node(node);
	if ok then self:save(); end
	return ok, err;
end

function service:delete(node, actor)
	if not self.nodes[node] then
		return false, "item-not-found";
	else
		if not self:may(node, actor, "delete") then
			return false, "forbidden";
		end

		local subscribers = self.nodes[node].subscribers;
		self:purge_node(node);
		self.nodes[node] = nil;
		self:save()
		self:broadcaster(node, subscribers, "deleted");
		return true;
	end
end

function service:publish(node, actor, id, item)
	local node_obj = self.nodes[node];
	local open_publish = node_obj and node_obj.config and 
			     node_obj.config.publish_model == "open" and true or false;

	if not node_obj and self.config.autocreate_on_publish then
		if not self:may(node, actor, "publish") then
			return false, "forbidden";
		end

		local ok, err = self:create(node, true);
		if not ok then
			return ok, err;
		end
		node_obj = self.nodes[node];
	end

	if not node_obj then return false, "item-not-found" end

	if not open_publish and not self:may(node, actor, "publish") then
		return false, "forbidden";
	end

	if item then
		node_obj.data[id] = item;
		table.insert(node_obj.data_id, id);

		-- If max items ~= 0, discard exceeding older items
		if node_obj.config.max_items and node_obj.config.max_items ~= 0 then
			if #node_obj.data_id > node_obj.config.max_items then
				local subtract = (#node_obj.data_id - node_obj.config.max_items <= 0) and
						 (node_obj.config.max_items + (#node_obj.data_id - node_obj.config.max_items)) or
						 #node_obj.data_id - node_obj.config.max_items;
				for entry, i_id in ipairs(node_obj.data_id) do
					if entry <= subtract then
						if id ~= i_id then node_obj.data[i_id] = nil; end -- check for id dupes
						table.remove(node_obj.data_id, entry);
					end
				end
			end
		end
	end

	if (node_obj.config.deliver_notifications or node_obj.config.deliver_notifications == nil) and
	   (node_obj.config.deliver_payloads or node_obj.config.deliver_payloads == nil) then
		self:broadcaster(node, node_obj.subscribers, item);
	elseif (node_obj.config.deliver_notifications or node_obj.config.deliver_notifications == nil) then
		local item_copy = item and st.clone(item);
		if item_copy then
			for i=1,#item_copy do item_copy[i] = nil end -- reset tags;
			item_copy.attr.xmlns = nil;
		end
		self:broadcaster(node, node_obj.subscribers, item_copy);
	end
	self:save_node(node);	
	return true;
end

function service:purge(node, actor)
	if not self.nodes[node] then
		return false, "item-not-found";
	else
		if not self:may(node, actor, "purge") then
			return false, "forbidden";
		end

		local subscribers = self.nodes[node].subscribers;
		self.nodes[node].data = {};
		self.nodes[node].data_id = {};
		self:save_node(node);
		self:broadcaster(node, subscribers, "purged");
		return true;
	end
end

function service:retract(node, actor, id, retract)
	local node_obj = self.nodes[node];
	if (not node_obj) or (not node_obj.data[id]) then
		return false, "item-not-found";
	end

	if not self:may(node, actor, "retract") then
		return false, "forbidden";
	end

	node_obj.data[id] = nil;
	for index, value in ipairs(node_obj.data_id) do
		if value == id then table.remove(node_obj.data_id, index); end
	end

	if retract then	self:broadcaster(node, node_obj.subscribers, retract); end
	self:save_node(node);
	return true;
end

function service:get_items(node, actor, id, max)
	local node_obj = self.nodes[node];
	if not node_obj then
		return false, "item-not-found";
	end

	if not self:may(node, actor, "get_items") then
		return false, "forbidden";
	end

	if type(actor) ~= "boolean"
	   and node_obj.config.access_model == "whitelist"
	   and self:get_affiliation(actor, node, action) ~= "owner" then
		local is_whitelisted = (node_obj.affiliation[actor] ~= nil or node_obj.affiliation[actor] ~= "outcast") and true;
		if cap == "subscribe" and not is_whitelisted then return false, "forbidden"; end
	end

	if (id and max) or (max and max < 0) then
		return false, "bad-request";
	end

	local function calculate_items_tosend(data_id, max)
		local _data_id = {};
		if max > #data_id then max = #data_id end
		if max == 0 then return data_id end
		for i = 1, max do table.insert(_data_id, data_id[#data_id - (i - 1)]) end
		return _data_id;
	end

	local _data_id;
	if id then -- Restrict results to a single specific item
		return true, { [id] = node_obj.data[id] }, { [1] = id };
	else
		if node_obj.config.deliver_payloads or node_obj.config.deliver_payloads == nil then
			if max then _data_id = calculate_items_tosend(node_obj.data_id, max); end	
			return true, node_obj.data, _data_id or node_obj.data_id;
		else
			local data_copy = {};
			for id, stanza in pairs(node_obj.data) do -- reset objects tags
				local _stanza = st.clone(stanza);
				for i=1,#_stanza do _stanza[i] = nil end
				_stanza.attr.xmlns = nil;
				data_copy[id] = _stanza;
			end
			if max then _data_id = calculate_items_tosend(node_obj.data_id, max); end
			return true, data_copy, _data_id or node_obj.data_id;
		end
	end
end

function service:get_nodes(actor)
	if not self:may(nil, actor, "get_nodes") then
		return false, "forbidden";
	end

	return true, self.nodes;
end

function service:get_subscriptions(node, actor, jid)
	local cap;
	if actor == true or jid == actor or (jid and self:jids_equal(actor, jid)) then
		cap = "get_subscriptions";
	else
		cap = "get_subscriptions_other";
	end

	local node_obj;
	if node then
		node_obj = self.nodes[node];
		if not node_obj then
			return false, "item-not-found";
		end
	end

	if not self:may(node, actor, cap) then
		return false, "forbidden";
	end

	local ret = {};
	if not jid then
		-- retrieve subscriptions as node owner...
		for jid, subscription in pairs(node_obj.subscribers) do
			ret[#ret+1] = {
				jid = self.config.normalize_jid(jid);
				subscription = subscription;
			};
		end

		return true, ret;
	end

	local normal_jid = self.config.normalize_jid(jid);
	local subs = self.subscriptions[normal_jid];
	-- We return the subscription object from the node to save
	-- a get_subscription() call for each node.
	if subs then
		for jid, subscribed_nodes in pairs(subs) do
			if node then -- Return only subscriptions to this node
				if subscribed_nodes[node] then
					ret[#ret+1] = {
						node = node;
						jid = jid;
						subscription = node_obj.subscribers[jid];
					};
				end
			else -- Return subscriptions to all nodes
				local nodes = self.nodes;
				for subscribed_node in pairs(subscribed_nodes) do
					ret[#ret+1] = {
						node = subscribed_node;
						jid = jid;
						subscription = nodes[subscribed_node].subscribers[jid];
					};
				end
			end
		end
	end
	return true, ret;
end

function service:set_node_capabilities(node, actor, capabilities)
	local node_obj = self.nodes[node];
	if not node_obj then
		return false, "item-not-found";
	end

	if not self:may(node, actor, "configure") then
		return false, "forbidden";
	end

	node_obj.capabilities = capabilities;
	self:save_node(node);
	return true;
end

function service:save()
	if not self.config.store then return true; end

	local function get_persistent_nodes(nodes)
		local self_nodes = {};
		for name, node in pairs(nodes) do
			if node.config.persist_items then self_nodes[name] = node; end
		end
		return self_nodes;
	end

	self.config.store:set(nil, {
		nodes = array.collect(keys(get_persistent_nodes(self.nodes)));
		affiliations = self.affiliations;
		subscriptions = self.subscriptions;
	});
	return true;
end

function service:restore()
	if not self.config.store then return true; end
	local data = self.config.store:get(nil);
	if not data then return; end
	self.affiliations = data.affiliations;
	for i, node in ipairs(data.nodes) do
		self:restore_node(node);
	end
	return true;
end

function service:save_node(node)
	if not self.config.store then return true; end
	local node_obj = self.nodes[node];
	if not node_obj.config.persist_items then return true; end
	local saved_data = {};
	for id, item in pairs(node_obj.data) do
		saved_data[id] = st.preserialize(item);
	end
	self.config.store:set(node, {
		subscribers = node_obj.subscribers;
		affiliations = node_obj.affiliations;
		config = node_obj.config;
		data = saved_data;
		data_id = node_obj.data_id;
	});
	return true;
end

function service:purge_node(node)
	if not self.config.store then return true; end
	local node_obj = self.nodes[node];
	if not node_obj.config.persist_items then return true; end
	self.config.store:set(node, nil);
	return true;		
end

function service:restore_node(node)
	if not self.config.store then return true; end
	local data = self.config.store:get(node);
	if not data then return; end
	local restored_data = {};

	local node_obj = {
		name = node;
		subscribers = data.subscribers;
		affiliations = data.affiliations;
		config = data.config;
		data = restored_data;
		data_id = data.data_id;
	};

	for id, item in pairs(data.data) do
		restored_data[id] = st.deserialize(item);
	end
	self.nodes[node] = node_obj;
	return true;
end

return _M;
