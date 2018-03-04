-- * Metronome IM *
--
-- This file is part of the Metronome XMPP server and is released under the
-- ISC License, please see the LICENSE file in this source package for more
-- information about copyright and licensing.
--
-- As per the sublicensing clause, this file is also MIT/X11 Licensed.
-- ** Copyright (c) 2011-2012, Florian Zeitz

-- <session xmlns="http://metronome.im/streams/c2s" jid="alice@example.com/brussels">
--   <encrypted/>
--   <compressed/>
-- </session>

-- <session xmlns="http://metronome.im/streams/s2s" jid="example.com">
--   <encrypted>
--     <valid/> / <invalid/>
--   </encrypted>
--   <compressed/>
--   <in/> / <out/>
-- </session>

module:depends("bosh");

local st = require "util.stanza";
local uuid_generate = require "util.uuid".generate;
local is_admin = usermanager.is_admin;
local pubsub = require "util.pubsub";
local jid_bare = require "util.jid".bare;
local lfs = require "lfs";
local open = io.open;
local select = select;
local stat = lfs.attributes;
local hosts = metronome.hosts;
local incoming_s2s = metronome.incoming_s2s;

module:set_global();

service = {};

local require_secure = module:get_option_boolean("admin_web_require_secure", false);

local http_base = module.path:gsub("/[^/]+$","") .. "/www_files/";

local xmlns_adminsub = "http://metronome.im/protocol/adminsub";
local xmlns_c2s_session = "http://metronome.im/streams/c2s";
local xmlns_s2s_session = "http://metronome.im/streams/s2s";

local mime_map = {
	html = "text/html; charset=utf-8";
	xml = "text/xml; charset=utf-8";
	js = "text/javascript";
	css = "text/css";
};

local idmap = {};
local retract = st.stanza("retract");

function generate_item(name, session, id)
	local xmlns = session.type == "c2s" and xmlns_c2s_session or xmlns_s2s_session;
	local item = st.stanza("item", { id = id }):tag("session", {xmlns = xmlns, jid = name}):up();
	if session.type == "s2sin" then item:tag("in"):up(); end
	if session.type == "s2sout" then item:tag("out"):up(); end
	if session.secure then
		if session.cert_identity_status == "valid" then
			item:tag("encrypted"):tag("valid"):up():up();
		else
			item:tag("encrypted"):tag("invalid"):up():up();
		end
	end
	if session.bidirectional then
		item:tag("bidi"):up();
	end
	if session.compressed then
		item:tag("compressed"):up();
	end
	if session.sm then
		item:tag("sm"):up();
	end
	if session.csi then
		if session.csi == "active" then
			item:tag("csi"):tag("active"):up():up();
		else
			item:tag("csi"):tag("inactive"):up():up();
		end
	end
	return item;
end

function add_client(session, host, update)
	local name = session.full_jid;
	if not name then return; end

	local id = idmap[name];
	if not id then
		id = uuid_generate();
		idmap[name] = id;
	end
	local item_exists = select(2, service[host]:get_items(xmlns_c2s_session, host, id));
	if item_exists and item_exists[id] then
		retract.attr.id = id;
		service[host]:retract(xmlns_c2s_session, host, id, retract);
	end
	local item = generate_item(name, session, id);
	service[host]:publish(xmlns_c2s_session, host, id, item);
	if not update then module:log("debug", "Added client " .. name); end
end

function del_client(session, host)
	local name = session.full_jid;
	local id = idmap[name];
	if id then
		retract.attr.id = id;
		service[host]:retract(xmlns_c2s_session, host, id, retract);
		idmap[name] = nil;
	end
end

function add_host(session, type, host, update)
	local name = (type == "out" and session.to_host) or (type == "in" and session.from_host);
	local id = idmap[name.."_"..type];
	if not id then
		id = uuid_generate();
		idmap[name.."_"..type] = id;
	end
	local item_exists = select(2, service[host]:get_items(xmlns_s2s_session, host, id));
	if item_exists and item_exists[id] then
		retract.attr.id = id;
		service[host]:retract(xmlns_s2s_session, host, id, retract);
	end
	local item = generate_item(name, session, id);
	service[host]:publish(xmlns_s2s_session, host, id, item);
	if not update then module:log("debug", "Added host " .. name .. " s2s" .. type); end
end

function del_host(session, type, host)
	local name = (type == "out" and session.to_host) or (type == "in" and session.from_host);
	local id = idmap[name.."_"..type];
	if id then
		retract.attr.id = id;
		service[host]:retract(xmlns_s2s_session, host, id, retract);
		idmap[name] = nil;
	end
end

function serve_file(event, path)
	local is_secure = event.request.secure;
	if require_secure and not is_secure then return nil; end

	local full_path = http_base .. path;

	if stat(full_path, "mode") == "directory" then
		if stat(full_path.."/index.html", "mode") == "file" then
			return serve_file(event, path.."/index.html");
		end
		return 403;
	end

	local f, err = open(full_path, "rb");
	if not f then
		return 404;
	end

	local data = f:read("*a");
	f:close();
	if not data then
		return 403;
	end

	local ext = path:match("%.([^.]*)$");
	event.response.headers.content_type = mime_map[ext]; -- Content-Type should be nil when not known
	return data;
end

function module.add_host(module)
	module:set_component_inheritable();

	-- Setup HTTP server
	module:depends("http");
	module:provides("http", {
		name = "admin";
		route = {
			["GET"] = function(event)
				event.response.headers.location = event.request.path .. "/";
				return 301;
			end;
			["GET /*"] = serve_file;
		}
	});

	-- Setup adminsub service
	local ok, err;
	service[module.host] = pubsub.new({
		broadcaster = function(self, node, jids, item) return simple_broadcast(self, node, jids, item, module.host) end;
		normalize_jid = jid_bare;
		get_affiliation = function(self, jid) return get_affiliation(self, jid, module.host) end;
		capabilities = {
			member = {
				create = false;
				publish = false;
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

			owner = {
				create = true;
				publish = true;
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
	});

	-- Create node for s2s sessions
	ok, err = service[module.host]:create(xmlns_s2s_session, true, nil, module.host);
	if not ok then
		module:log("warn", "Could not create node " .. xmlns_s2s_session .. ": " .. tostring(err));
	end

	-- Add outgoing s2s sessions 
	for remotehost, session in pairs(hosts[module.host].s2sout) do
		if session.type ~= "s2sout_unauthed" then
			add_host(session, "out", module.host);
		end
	end

	-- Add incomming s2s sessions 
	for session in pairs(incoming_s2s) do
		if session.to_host == module.host then
			add_host(session, "in", module.host);
		end
	end

	-- Create node for c2s sessions
	ok, err = service[module.host]:create(xmlns_c2s_session, true, nil, module.host);
	if not ok then
		module:log("warn", "Could not create node " .. xmlns_c2s_session .. ": " .. tostring(err));
	end

	-- Add c2s sessions
	for username, user in pairs(hosts[module.host].sessions or {}) do
		for resource, session in pairs(user.sessions or {}) do
			add_client(session, module.host);
		end
	end

	-- Register adminsub handler
	module:hook("iq/host/"..xmlns_adminsub..":adminsub", function(event)
		local origin, stanza = event.origin, event.stanza;
		local adminsub = stanza.tags[1];
		local action = adminsub.tags[1];
		local reply;
		if action.name == "subscribe" then
			local ok, ret = service[module.host]:add_subscription(action.attr.node, stanza.attr.from, stanza.attr.from);
			if ok then
				reply = st.reply(stanza)
					:tag("adminsub", { xmlns = xmlns_adminsub });
			else
				reply = st.error_reply(stanza, "cancel", ret);
			end
		elseif action.name == "unsubscribe" then
			local ok, ret = service[module.host]:remove_subscription(action.attr.node, stanza.attr.from, stanza.attr.from);
			if ok then
				reply = st.reply(stanza)
					:tag("adminsub", { xmlns = xmlns_adminsub });
			else
				reply = st.error_reply(stanza, "cancel", ret);
			end
		elseif action.name == "items" then
			local node = action.attr.node;
			local ok, ret = service[module.host]:get_items(node, stanza.attr.from);
			if not ok then
				return origin.send(st.error_reply(stanza, "cancel", ret));
			end

			local data = st.stanza("items", { node = node });
			for _, entry in pairs(ret) do
				data:add_child(entry);
			end
			if data then
				reply = st.reply(stanza)
					:tag("adminsub", { xmlns = xmlns_adminsub })
						:add_child(data);
			else
				reply = st.error_reply(stanza, "cancel", "item-not-found");
			end
		elseif action.name == "adminfor" then
			local data = st.stanza("adminfor");
			for host_name in pairs(hosts) do
				if is_admin(stanza.attr.from, host_name) then
					data:tag("item"):text(host_name):up();
				end
			end
			reply = st.reply(stanza)
				:tag("adminsub", { xmlns = xmlns_adminsub })
					:add_child(data);
		else
			reply = st.error_reply(stanza, "feature-not-implemented");
		end
		return origin.send(reply);
	end);

	-- Add/remove/update c2s sessions
	module:hook("resource-bind", function(event)
		add_client(event.session, module.host);
	end);

	module:hook("c2s-compressed", function(session)
		add_client(session, module.host, true);
	end);	

	module:hook("c2s-sm-enabled", function(session)
		add_client(session, module.host, true);
	end);

	module:hook("client-state-changed", function(event)
		add_client(event.session, module.host, true);
	end);

	module:hook("resource-unbind", function(event)
		del_client(event.session, module.host);
		service[module.host]:remove_subscription(xmlns_c2s_session, module.host, event.session.full_jid);
		service[module.host]:remove_subscription(xmlns_s2s_session, module.host, event.session.full_jid);
	end);

	-- Add/remove/update s2s sessions
	module:hook("bidi-established", function(event)
		if event.type == "outgoing" then
			add_host(event.origin, "out", module.host, true);
		else
			add_host(event.session, "in", module.host, true);
		end
	end);

	module:hook("s2sout-established", function(event)
		add_host(event.session, "out", module.host);
	end);

	module:hook("s2sout-compressed", function(session)
		add_host(session, "out", module.host, true);
	end);
	
	module:hook("s2sout-sm-enabled", function(session)
		add_host(session, "out", module.host, true);
	end);

	module:hook("s2sin-established", function(event)
		add_host(event.session, "in", module.host);
	end);

	module:hook("s2sin-compressed", function(session)
		add_host(session, "in", module.host, true);
	end);
	
	module:hook("s2sin-sm-enabled", function(session)
		add_host(session, "in", module.host, true);
	end);

	module:hook("s2sout-destroyed", function(event)
		del_host(event.session, "out", module.host);
	end);

	module:hook("s2sin-destroyed", function(event)
		del_host(event.session, "in", module.host);
	end);
end

function simple_broadcast(self, node, jids, item, host)
	item = st.clone(item);
	item.attr.xmlns = nil; -- Clear the pubsub namespace
	local message = st.message({ from = host, type = "headline" })
		:tag("event", { xmlns = xmlns_adminsub .. "#event" })
			:tag("items", { node = node })
				:add_child(item);
	for jid in pairs(jids) do
		module:log("debug", "Sending notification to %s", jid);
		message.attr.to = jid;
		module:fire_global_event("route/post", hosts[host], message);
	end
end

function get_affiliation(self, jid, host)
	local bare_jid = jid_bare(jid);

	if is_admin(bare_jid, host) then
		return "member";
	else
		return "none";
	end
end
