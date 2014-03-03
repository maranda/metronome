-- * Metronome IM *
--
-- This file is part of the Metronome XMPP server and is released under the
-- ISC License, please see the LICENSE file in this source package for more
-- information about copyright and licensing.

-- Implements XEP-267: Server Buddies.

module:depends("adhoc");

local st = require "util.stanza";
local dataforms = require "util.dataforms";
local datamanager = require "util.datamanager";
local jid_split = require "util.jid".split;
local my_host = module.host;
local NULL = {};

local ipairs, pairs, t_insert = ipairs, pairs, table.insert;

module:add_feature("urn:xmpp:server-presence")

local outbound = {};
local pending = {};
local subscribed = {};

local s_xmlns = "http://jabber.org/protocol/admin#server-buddy";
local p_xmlns = "http://metronome.im/protocol/admin#server-buddy-pending";
local r_xmlns = "http://metronome.im/protocol/admin#server-buddy-remove";

local st_subscribe = st.presence({ from = my_host, type = "subscribe" });
local st_unsubscribe = st.presence({ from = my_host, type = "unsubscribe" });
local st_subscribed = st.presence({ from = my_host, type = "subscribed" });
local st_unsubscribed = st.presence({ from = my_host, type = "unsubscribed" });

local subscribe_cmd_layout = dataforms.new{
	title = "Subscribing to a peer server";
	instructions = "Supply the peer server qualified domain name you want to subscribe to.";
	{ name = "FORM_TYPE", type = "hidden", value = "http://jabber.org/protocol/admin" };
	{ name = "peerjid", type = "jid-single", label = "The domain of the peer server" };
}

local function pending_cmd_layout()
	local layout = {
		title = "Pending peer server subscriptions";
		instructions = "Approve or refuse peer server subscriptions.";
		{ name = "FORM_TYPE", type = "hidden", value = "http://jabber.org/protocol/admin" };
	}
	
	for jid in pairs(pending) do
		t_insert(layout, {
			name = jid,
			type = "list-single",
			label = "Pending subscription for: "..jid,
			value = {
				{ value = "approve", default = true },
				{ value = "reject" }
			}
		});
	end
	
	return dataforms.new(layout);
end
	
local function remove_cmd_layout()
	local layout = {
		title = "Remove peer server subscriptions";
		instructions = "You can remove approved peer servers here.";
		{ name = "FORM_TYPE", type = "hidden", value = "http://jabber.org/protocol/admin" };
	}
	
	for jid in pairs(subscribed) do
		t_insert(layout, {
			name = jid,
			type = "boolean",
			label = "Remove "..jid.." subscription?",
			value = false;
		});
	end
	
	return dataforms.new(layout);	
end

-- Adhoc Handlers

local function subscribe_command_handler(self, data, state)
	local layout = dataforms.new(subscribe_cmd_layout);
	
	if state then
		if data.action == "cancel" then return { status = "canceled" }; end
		local fields = layout:data(data.form);
		
		local peer = fields.peerjid;
		if not peer or peer == "" then 
			return { status = "completed", error = { message = "You need to supply the server QDN." } };
		else
			if peer == my_host then
				return { status = "completed", error = { message = "I can't subscribe to myself!!! *rolls eyes*" } };
			elseif subscribed[peer] then
				return { status = "completed", error = { message = "I'm already subscribed to this entity." } };
			end
			local subscribe = st.presence({ to = peer, from = my_host, type = "subscribe" });
			outbound[peer] = true;
			module:send(subscribe);
			datamanager.store("outbound", my_host, "server_presence", outbound);
			return { status = "completed", info = "Subscription request sent." };
		end
	else
		return { status = "executing", form = layout }, "executing"
	end
end

local function pending_command_handler(self, data, state)
	local layout = pending_cmd_layout();

	if state then
		if data.action == "cancel" then return { status = "canceled" }; end
		local fields = layout:data(data.form);
		fields["FORM_TYPE"] = nil;
		
		local _changed;
		for jid, action in pairs(fields) do
			if action == "approve" then
				st_subscribed.attr.to = jid;
				module:send(st_subscribed);
				subscribed[jid], _changed = true, true;
				pending[jid] = nil;
				module:fire_event("peer-subscription-completed", jid);
			else
				st_unsubscribed.attr.to = jid;
				module:send(st_unsubscribed);
				pending[jid] = nil;
			end
		end
		
		if _changed then datamanager.store("subscribed", my_host, "server_presence", subscribed); end
		datamanager.store("pending", my_host, "server_presence", pending);
		return { status = "completed", info = "Done." };
	else
		return { status = "executing", form = layout }, "executing"
	end
end

local function remove_command_handler(self, data, state)
	local layout = remove_cmd_layout();
	
	if state then
		if data.action == "cancel" then return { status = "canceled" }; end
		local fields = layout:data(data.form);
		fields["FORM_TYPE"] = nil;
		
		local _changed;
		for jid, remove in pairs(fields) do
			if remove then
				st_unsubscribe.attr.to = jid;
				module:send(st_unsubscribe);
				subscribed[jid], _changed = nil, true;
				module:fire_event("peer-subscription-removed", jid);
			end
		end

		if _changed then datamanager.store("subscribed", my_host, "server_presence", subscribed); end
		return { status = "completed", info = "Done." };
	else
		return { status = "executing", form = layout }, "executing"
	end
end

local adhoc_new = module:require "adhoc".new;
local subscribe_descriptor = adhoc_new("Subscribe to a Peer Server", s_xmlns, subscribe_command_handler, "admin");
local pending_descriptor = adhoc_new("Pending server presence subscription requests", p_xmlns, pending_command_handler, "admin");
local remove_descriptor = adhoc_new("Remove approved server presence subscription", r_xmlns, remove_command_handler, "admin");
module:provides("adhoc", subscribe_descriptor);
module:provides("adhoc", pending_descriptor);
module:provides("adhoc", remove_descriptor);

-- Hooks

module:hook("presence/host", function(event)
	local stanza, origin = event.stanza, event.origin;

	if not stanza.attr.from then return; end
	local node, host = jid_split(stanza.attr.from);
	
	if node then return; end -- We only handle server subscriptions.
	local t = stanza.attr.type;
	
	if t == "subscribe" then
		if subscribed[host] then
			module:log("info", "auto accepting %s peer subscription", host);
			st_subscribed.attr.to = host;
			module:send(st_subscribed);
		else
			pending[host] = true;
			datamanager.store("pending", my_host, "server_presence", pending);
		end
	elseif t == "subscribed" then
		if outbound[host] then
			module:log("info", "%s has accepted the peer subscription, sending request as well", host);
			st_subscribe.attr.to = host;
			module:send(st_subscribe);
			outbound[host] = nil;
			subscribed[host] = true;
			datamanager.store("outbound", my_host, "server_presence", outbound);
			datamanager.store("subscribed", my_host, "server_presence", subscribed);
			module:fire_event("peer-subscription-completed", host);
		end
	elseif t == "unsubscribe" or t == "unsubscribed" then
		local _pending, _subscribed;
		if pending[host] then pending[host] = nil; _pending = true; end
		if subscribed[host] then subscribed[host] = nil; _subscribed = true; end
		if _pending or _subscribed then
			module:log("info", "%s has removed the peer subscription to us", host);
			if t == "unsubscribe" then 
				st_unsubscribed.attr.to = host;
				module:send(st_unsubscribed);
			end
			if _pending then datamanager.store("pending", my_host, "server_presence", pending); end
			if _subscribed then datamanager.store("subscribed", my_host, "server_presence", subscribed); end
			module:fire_event("peer-subscription-removed", host);
		end
	end

	return true;
end, 30);

module:hook("peer-is-subscribed", function(host)
	if subscribed[host] then return true; else return false; end
end);

-- Module Methods

module.load = function()
	if datamanager.load("outbound", my_host, "server_presence") then outbound = datamanager.load("outbound", my_host, "server_presence"); end
	if datamanager.load("pending", my_host, "server_presence") then pending = datamanager.load("pending", my_host, "server_presence"); end
	if datamanager.load("subscribed", my_host, "server_presence") then subscribed = datamanager.load("subscribed", my_host, "server_presence"); end
end

module.save = function()
	return { outbound = outbound, pending = pending, subscribed = subscribed };
end

module.restore = function(data)
	outbound = data.outbound or {};
	pending = data.pending or {};
	subscribed = data.subscribed or {};		
end
