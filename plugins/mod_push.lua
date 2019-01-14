-- * Metronome IM *
--
-- This file is part of the Metronome XMPP server and is released under the
-- ISC License, please see the LICENSE file in this source package for more
-- information about copyright and licensing.

-- Implements Push Notifications XEP-0357

module:depends("stream_management");

local ipairs, pairs, tostring = ipairs, pairs, tostring;

local st = require "util.stanza";
local jid_join = require "util.jid".join;
local jid_split = require "util.jid".split;
local uuid = require "util.uuid".generate;

local push_xmlns = "urn:xmpp:push:0";
local df_xmlns = "jabber:x:data";
local summary_xmlns = "urn:xmpp:push:summary";

local user_list = {};
local store_cache = {};
local sent_ids = setmetatable({}, { __mode = "v" });

local push = storagemanager.open(module.host, "push");
local push_account_list = storagemanager.open(module.host, "push_account_list");

-- Adhoc Handlers

module:depends("adhoc");
local adhoc_new = module:require "adhoc".new;

local function change_push_options(self, data, state)
	local node, host = jid_split(data.from);
	local options;
	if not user_list[node] then 
		user_list[node] = { last_sender = true }; options = user_list[node]; 
	else
		options = user_list[node];
	end
		
	if not options.last_sender then
		options.last_sender = true;
		if store_cache[node] then push_account_list:set(nil, user_list); end
		return { status = "completed", info = "PUSH notifications will now contain the last sender of a message/s" };
	else
		options.last_sender = false;
		push_account_list:set(nil, user_list);
		return { status = "completed", info = "PUSH notifications will now be stripped of the last sender of a message/s" };
	end
end

local change_push_options_descriptor = adhoc_new(
	"Toggle last-message-sender in Push Notifications", "change_push_last_sender", change_push_options, "local_user"
);
module:provides("adhoc", change_push_options_descriptor);

-- Utility Functions

local function ping_app_server(user, app_server, node, last_from, count, send_last, secret)
	local id = uuid();
	module:log("debug", "Sending PUSH notification for %s with id %s, from %s with message count %d, to App Server %s",
		jid_join(user, module.host), id, last_from, count, app_server);

	local notification = st.iq({ type = "set", to = app_server, from = module.host, id = id })
		:tag("pubsub", { xmlns = "http://jabber.org/protocol/pubsub" })
			:tag("publish", { node = node })
				:tag("item")
					:tag("notification", { xmlns = push_xmlns })
						:tag("field", { var = "FORM_TYPE" }):tag("value"):text(summary_xmlns):up():up()
						:tag("field", { var = "message-count" }):tag("value"):text(tostring(count)):up():up();

	if send_last then
		notification:tag("field", { var = "last-message-sender" }):tag("value"):text(last_from):up():up();
	end

	notification:up():up():up(); -- close <publish /> element

	if secret then
		notification:tag("publish-options")
			:tag("x", { xmlns = df_xmlns })
				:tag("field", { var = "FORM_TYPE" }):tag("value"):text("http://jabber.org/protocol/pubsub#publish-options"):up():up()
				:tag("field", { var = "secret" }):tag("value"):text(secret):up():up()
			:up()
		:up();
	end

	sent_ids[id] = { app_server = app_server, node = node, user = user };
	module:send(notification);
end

local function push_notify(user, store, last_from, count)
	local options = user_list[user];
	for app_server, push in pairs(store) do
		local nodes = push.nodes;
		for node in pairs(nodes) do ping_app_server(user, app_server, node, last_from, count, options.last_sender, push.secret); end
	end
end

-- Stanza Handlers

module:hook("iq-set/self/"..push_xmlns..":enable", function(event)
	local origin, stanza = event.origin, event.stanza;
	local enable = stanza.tags[1];

	local user, host = origin.username, origin.host;
	local store = store_cache[user] or push:get(user) or {};

	local form, secret = enable:get_child("x", "jabber:x:data");
	if form.attr.type == "submit" then
		for i, field in ipairs(form.tags) do
			if field.attr.var == "secret" then
				secret = field:get_child_text("value");
				break;
			end
		end
	end

	local app_server, node = enable.attr.jid, enable.attr.node;
	if not app_server and node then
		origin.send(st.error_reply(stanza, "modify", "bad-request"));
		return true;
	end

	module:log("debug", "User %s activated PUSH, application service %s, node %s",
		jid_join(user, host), app_server, node);
	if not store[app_server] then
		store[app_server] = { nodes = {}, secret = secret };
		store[app_server].nodes[node] = true;
	else
		store[app_server].secret = secret;
		store[app_server].nodes[node] = true;
	end
	store_cache[user] = store;
	user_list[user] = { last_sender = true };
	push_account_list:set(nil, user_list);
	push:set(user, store);

	origin.send(st.reply(stanza));
	return true;
end);

module:hook_stanza("iq-set/self/"..push_xmlns..":disable", function(event)
	local origin, stanza = event.origin, event.stanza;
	local disable = stanza.tags[1];

	local user, host = origin.username, origin.host;
	local store = store_cache[user] or push:get(user);

	local jid, node = disable.attr.jid, disable.attr.node;
	if not jid then
		origin.send(st.error_reply(stanza, "modify", "bad-request"));
		return true;		
	elseif not store then
		origin.send(st.reply(stanza));
		return true;
	end
	
	if not node then
		module:log("debug", "User %s deactivated PUSH application service %s", jid_join(user, host), push.app_server);
		store[jid] = nil;
	else
		module:log("debug", "User %s deactivated PUSH, application service %s, node %s",
			jid_join(user, host), app_server, node);
		store[jid].nodes[node] = nil;
	end

	if next(store) then
		store_cache[user] = store;
		push:set(user, store);
	else
		if user_list[user].last_sender == true then
			user_list[user] = nil;
		end
		store_cache[user] = nil;
		push_account_list:set(nil, user_list);
		push:set(user);
	end

	origin.send(st.reply(stanza));
	return true;
end);

module:hook("account-disco-info", function(event)
	event.stanza:tag("feature", { var = push_xmlns }):up();
end, 40);

module:hook("sm-push-message", function(event)
	local user, stanza = event.username, event.stanza;
	local store = store_cache[user];
	local type = stanza.attr.type;

	if store and stanza.name == "message" and (type == "chat" or type == "groupchat" or type == "normal") and
		stanza:get_child_text("body") then
		push_notify(user, store, stanza.attr.from, 1);
	end
end);

module:hook("sm-process-queue", function(event)
	local user, queue = event.username, event.queue;
	local store = store_cache[user];

	if store then
		local count, last_from = 0;
		for i, stanza in ipairs(queue) do
			local type = stanza.attr.type;
			if stanza.name == "message" and (type == "chat" or type == "groupchat" or type == "normal") and
				stanza:get_child_text("body") then
				count = count + 1;
				last_from = stanza.attr.from;
			end
		end
		if count > 0 then
			push_notify(user, store, last_from, count);
		end
	end
end);

module:hook("message/offline/handle", function(event)
	local stanza = event.stanza;
	local user = jid_split(stanza.attr.to);
	local store = store_cache[user];
	if store and stanza:get_child_text("body") then
		push_notify(user, store, stanza.attr.from, 1);
	end
end, 1);

module:hook("iq/host", function(event)
	local stanza = event.stanza;
	if stanza.attr.type ~= "error" and stanza.attr.type ~= "result" then return; end

	local id = stanza.attr.id;
	if sent_ids[id] then
		if stanza.attr.type == "error" then
			local sent_id = sent_ids[id];
			local err_type, condition = event.stanza:get_error();
			if err_type ~= "wait" then
				local user = sent_id.user
				local store = store_cache[user];
				module:log("debug", "Received error type %s condition %s while sending %s PUSH notification, disabling related node for %s",
					err_type, condition, id, user);
				store[sent_id.app_server].nodes[sent_id.node] = nil;
				push:set(user, store);
			end
		else
			module:log("debug", "PUSH App Server handled %s", id);
		end
		sent_ids[id] = nil;
		return true;
	end
end, 10);

function module.load()
	user_list = push_account_list:get() or {};
	for user in pairs(user_list) do
		store_cache[user] = push:get(user);
	end
end

function module.save()
	return { user_list = user_list, store_cache = store_cache };
end

function module.restore(data)
	user_list = data.user_list or {};
	store_cache = data.store_cache or {};
end

function module.unload()
	local host = module.host;
	push_account_list:set(nil, user_list);
	for user, store in pairs(store_cache) do
		push:set(user, store);
	end
end