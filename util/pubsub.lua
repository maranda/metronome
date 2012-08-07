local events = require "util.events";

module("pubsub", package.seeall);

local service = {};
local service_mt = { __index = service };

local default_config = {
	broadcaster = function () end;
	get_affiliation = function () end;
	send_node_config_form = function () end;
	node_config_form_layout = function () end;
	process_node_config_form = function () end;
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

function service:send_node_config_form(name, actor)
	return self.config.send_node_config_form(self, name, actor);
end

function service:node_config_form_layout(name)
	return self.config.node_config_form_layout(self, name);
end

function service:process_node_config_form(name, form, actor)
	return self.config.node_config_form_layout(self, name, form, actor);
end

function service:get_affiliation(jid, node, action)
	return self.config.get_affiliation(self, jid, node, action);
end

function service:set_affiliation(node, actor, jid, affiliation)
	-- Access checking
	if not self:may(node, actor, "set_affiliation") then
		return false, "forbidden";
	end
	--
	local node_obj = self.nodes[node];
	if not node_obj then
		return false, "item-not-found";
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
	return true;
end

function service:add_subscription(node, actor, jid, options)
	-- Access checking
	local cap;
	if actor == true or jid == actor or self:jids_equal(actor, jid) then
		cap = "subscribe";
	else
		cap = "subscribe_other";
	end
	if not self:may(node, actor, cap) then
		return false, "forbidden";
	end
	if not self:may(node, jid, "be_subscribed") then
		return false, "forbidden";
	end
	--
	local node_obj = self.nodes[node];
	if not node_obj then
		if not self.config.autocreate_on_subscribe then
			return false, "item-not-found";
		else
			local ok, err = self:create(node, true);
			if not ok then
				return ok, err;
			end
			node_obj = self.nodes[node];
		end
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
	return true;
end

function service:remove_subscription(node, actor, jid)
	-- Access checking
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
	--
	local node_obj = self.nodes[node];
	if not node_obj then
		return false, "item-not-found";
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
	return true;
end

function service:get_subscription(node, actor, jid)
	-- Access checking
	local cap;
	if actor == true or jid == actor or self:jids_equal(actor, jid) then
		cap = "get_subscription";
	else
		cap = "get_subscription_other";
	end
	if not self:may(node, actor, cap) then
		return false, "forbidden";
	end
	--
	local node_obj = self.nodes[node];
	if not node_obj then
		return false, "item-not-found";
	end
	return true, node_obj.subscribers[jid];
end

function service:create(node, actor)
	-- Access checking
	if not self:may(node, actor, "create") then
		return false, "forbidden";
	end
	--
	if self.nodes[node] then
		return false, "conflict";
	end
	
	self.nodes[node] = {
		name = node;
		subscribers = {};
		config = self.config.node_default_config or {};
		data = {};
		affiliations = {};
	};

	-- normalize jid
	if type(actor) ~= "boolean" then actor = self.config.normalize_jid(actor); end

	local ok, err = self:set_affiliation(node, true, actor, "owner");
	if not ok then
		self.nodes[node] = nil;
	end
	return ok, err;
end

function service:delete(node, actor)
	-- Check for access
	if not self:may(node, actor, "delete") then
		return false, "forbidden";
	end
	
	if not self.nodes[node] then
		return false, "item-not-found";
	else
		local subscribers = self.nodes[node].subscribers;
		self.nodes[node] = nil;
		self:broadcaster(node, subscribers, "deleted");
		return true;
	end
end

function service:publish(node, actor, id, item)
	-- Access checking
	if not self:may(node, actor, "publish") then
		return false, "forbidden";
	end
	--
	local node_obj = self.nodes[node];
	if not node_obj then
		if not self.config.autocreate_on_publish then
			return false, "item-not-found";
		end
		local ok, err = self:create(node, true);
		if not ok then
			return ok, err;
		end
		node_obj = self.nodes[node];
	end
	node_obj.data[id] = item;
	if (node_obj.config.deliver_notifications or node_obj.config.deliver_notifications == nil) and
	   (node_obj.config.deliver_payloads or node_obj.config.deliver_payloads == nil) then
		self:broadcaster(node, node_obj.subscribers, item);
	elseif (node_obj.config.deliver_notifications or node_obj.config.deliver_notifications == nil) then
		local item_copy = item;
		for i=1,#item_copy do item_copy[i] = nil end -- reset tags;
		item_copy.attr.xmlns = nil;
		self:broadcaster(node, node_obj.subscribers, item);
	end		
	return true;
end

function service:retract(node, actor, id, retract)
	-- Access checking
	if not self:may(node, actor, "retract") then
		return false, "forbidden";
	end
	--
	local node_obj = self.nodes[node];
	if (not node_obj) or (not node_obj.data[id]) then
		return false, "item-not-found";
	end
	node_obj.data[id] = nil;
	if retract and (node_obj.config.deliver_notifications or node_obj.config.deliver_notifications == nil) then
		-- Should deliver notifications be respected in this case?
		self:broadcaster(node, node_obj.subscribers, retract);
	end
	return true
end

function service:get_items(node, actor, id)
	-- Access checking
	if not self:may(node, actor, "get_items") then
		return false, "forbidden";
	end
	--
	local node_obj = self.nodes[node];
	if not node_obj then
		return false, "item-not-found";
	end
	if id then -- Restrict results to a single specific item
		return true, { [id] = node_obj.data[id] };
	else
		if node_obj.config.deliver_payloads or node_obj.config.deliver_payloads == nil then
			return true, node_obj.data;
		else
			local data_copy = node_obj.data;
			for id, stanza in pairs(data_copy) do -- reset objects tags
				for i=1,#stanza do stanza[i] = nil end
				stanza.attr.xmlns = nil;
			end
			return true, data_copy;
		end
	end
end

function service:get_nodes(actor)
	-- Access checking
	if not self:may(nil, actor, "get_nodes") then
		return false, "forbidden";
	end
	--
	return true, self.nodes;
end

function service:get_subscriptions(node, actor, jid)
	-- Access checking
	local cap;
	if actor == true or jid == actor or self:jids_equal(actor, jid) then
		cap = "get_subscriptions";
	else
		cap = "get_subscriptions_other";
	end
	if not self:may(node, actor, cap) then
		return false, "forbidden";
	end
	--
	local node_obj;
	if node then
		node_obj = self.nodes[node];
		if not node_obj then
			return false, "item-not-found";
		end
	end
	local normal_jid = self.config.normalize_jid(jid);
	local subs = self.subscriptions[normal_jid];
	-- We return the subscription object from the node to save
	-- a get_subscription() call for each node.
	local ret = {};
	if subs then
		for jid, subscribed_nodes in pairs(subs) do
			if node then -- Return only subscriptions to this node
				if subscribed_nodes[node] then
					ret[#ret+1] = {
						node = subscribed_node;
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

-- Access models only affect 'none' affiliation caps, service/default access level...
function service:set_node_capabilities(node, actor, capabilities)
	-- Access checking
	if not self:may(node, actor, "configure") then
		return false, "forbidden";
	end
	--
	local node_obj = self.nodes[node];
	if not node_obj then
		return false, "item-not-found";
	end
	node_obj.capabilities = capabilities;
	return true;
end

return _M;
