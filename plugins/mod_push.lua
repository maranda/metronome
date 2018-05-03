-- * Metronome IM *
--
-- This file is part of the Metronome XMPP server and is released under the
-- ISC License, please see the LICENSE file in this source package for more
-- information about copyright and licensing.

local ipairs, pairs, t_insert, t_remove = ipairs, pairs, table.insert, table.remove;

local st = require "util.stanza";
local jid_join = require "util.jid".join;
local jid_split = require "util.jid".split;
local uuid = require "util.uuid".generate;
local dm = require "util.datamanager";

local push_xmlns = "urn:xmpp:push:0";
local df_xmlns = "jabber:x:data";
local summary_xmlns = "urn:xmpp:push:summary";

local user_list = {};
local store_cache = {};
local sent_ids = setmetatable({}, { __mode = "v" });

local function ping_app_server(user, app_server, node, stanza, secret)
	module:log("debug", "Sending PUSH notification for %s, from %s, to App Server %s",
		jid_join(user, module.host), stanza.attr.from, app_server);
	local id = uuid();

	local notification = st.iq({ type = "set", to = app_server, from = module.host, id = id })
		:tag("pubsub", { xmlns = "http://jabber.org/protocol/pubsub" })
			:tag("publish", { node = node })
				:tag("item")
					:tag("notification", { xmlns = push_xmlns })
						:tag("field", { var = "FORM_TYPE" }):tag("value"):text(summary_xmlns):up():up()
						:tag("field", { var = "message-count" }):tag("value"):text("1"):up():up()
						:tag("field", { var = "last-message-sender" }):tag("value"):text(stanza.attr.from):up():up()
						:tag("field", { var = "last-message-body" }):tag("value"):text(stanza:get_child_text("body")):up():up()
					:up()
				:up()
			:up();

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

local function push_notify(user, store)
	for _, push in ipairs(store) do ping_app_server(user, push.app_server, push.node, push.stanza, push.secret); end
end

module:hook("iq-set/self/"..push_xmlns..":enable", function(event)
	local origin, stanza = event.origin, event.stanza;
	local enable = stanza.tags[1];

	local user, host = origin.username, origin.host;
	local store = store_cache[user] or dm.load(user, host, "push") or {};

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
	t_insert(store, { app_server = app_server, node = node, secret = secret });
	store_cache[user] = store;
	user_list[user] = true;
	dm.store(nil, host, "push_account_list", user_list);
	dm.store(user, host, "push", store);

	origin.send(st.reply(stanza));
	return true;
end);

module:hook_stanza("iq-set/self/"..push_xmlns..":disable", function(event)
	local origin, stanza = event.origin, event.stanza;
	local disable = stanza.tags[1];

	local user, host = origin.username, origin.host;
	local store = store_cache[user] or dm.load(user, host, "push") or {};

	if not node then
		module:log("debug", "User %s disabled PUSH completely", jid_join(user, host));
		store_cache[user] = nil;
		user_list[user] = nil;
		dm.store(nil, host, "push_account_list", user_list);
		dm.store(user, host, "push");

		origin.send(st.reply(stanza));
		return true;
	end

	local jid, node = disable.attr.jid, disable.attr.node;
	for i, push in ipairs(store) do
		if push.app_server == jid then
			if node and push.node == node or not node then
				module:log("debug", "User %s deactivated PUSH, application service %s, node %s",
					jid_join(user, host), push.app_server, push.node);
				t_remove(store, i);
			end
		end
	end

	if next(store) then
		store_cache[user] = store;
		dm.store(user, host, "push", store);
	else
		user_list[user] = nil;
		store_cache[user] = nil;
		dm.store(nil, host, "push_account_list", user_list);
		dm.store(user, host, "push");
	end

	origin.send(st.reply(stanza));
	return true;
end);

module:hook("account-disco-info", function(event)
	event.stanza:tag("feature", { var = push_xmlns }):up();
end);

module:hook("sm-push-message", function(event)
	local user, stanza = event.username, event.stanza;
	local store = store_cache[user];

	if store and stanza.name == "message" and stanza.attr.type == "chat" and stanza:get_child_text("body") and
		not stanza:child_with_ns("urn:xmpp:carbons:1") then
		push_notify(user, store);
	end
end);

module:hook("sm-process-queue", function(event)
	local user, queue = event.username, event.queue;
	local store = store_cache[user];

	if store then
		for i, stanza in ipairs(queue) do
			if stanza.name == "message" and stanza.attr.type == "chat" and stanza:get_child_text("body") and
				not stanza:child_with_ns("urn:xmpp:carbons:1") then
				push_notify(user, store);
			end
		end
	end
end);

module:hook("message/offline/handle", function(event)
	local stanza = event.stanza;
	local user = jid_split(stanza.attr.to);
	local store = store_cache[user];
	if store and stanza.attr.type == "chat" and stanza:get_child_text("body") then push_notify(user, store); end
end, 1);

module:hook("iq-error/host", function(event)
	if sent_ids[event.stanza.attr.id] then
		local id = event.stanza.attr.id;
		local sent_id = sent_ids[id];
		local err_type, condition = event.stanza:get_error();
		if err_type ~= "wait" then
			local user = sent_id.user
			local store = store_cache[user];
			module:log("debug", "Received error type %s condition %s while sending %s PUSH notification, disabling related App Server for %s",
				err_type, condition, id, user);
			for i, push in ipairs(store) do
				if push.app_server == sent_id.app_server and push.node == sent_id.node then
					t_remove(store[user], i);
				end
			end
		end
		sent_ids[id] = nil;
	end
end);

module:hook("iq-result/host", function(event)
	sent_ids[event.stanza.attr.id] = nil;
end);

function module.load()
	user_list = dm.load(nil, module.host, "push_account_list") or {};
	for user in pairs(user_list) do
		store_cache[user] = dm.load(user, module.host, "push");
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
	dm.store(nil, host, "push_account_list", user_list);
	for user, store in pairs(store_cache) do
		dm.store(user, host, "push", store);
	end
end