-- * Metronome IM *
--
-- This file is part of the Metronome XMPP server and is released under the
-- ISC License, please see the LICENSE file in this source package for more
-- information about copyright and licensing.

-- Implements XEP-309: Service Directories

local service;

local my_host = module.host;
local jid_bare = require "util.jid".bare;
local jid_split = require "util.jid".split;
local pubsub = require "util.pubsub";
local st = require "util.stanza";
local type = type;

local xmlns_pubsub = "http://jabber.org/protocol/pubsub";
local xmlns_pubsub_event = "http://jabber.org/protocol/pubsub#event";

module:depends("server_presence");
module:add_identity("directory", "server", "Metronome");

-- Util. functions.

local function publish_item(host, vcard)
	local item = st.stanza("item", { id = host });
	local _vcard = st.clone(vcard);

	item:add_child(_vcard);
	service:publish("urn:xmpp:contacts", true, host, item, my_host);
end

-- Module Handlers.

local function handle_subscribed_peer(host)
	-- send disco info request.
	if not hosts[host] then
		module:log("debug", "Sending disco info request to peer server %s", host);
		local disco_get = st.iq({ from = my_host, to = host, type = "get", id = "directory_probe:disco" })
			:query("http://jabber.org/protocol/disco#info");
		module:send(disco_get);
	else
		-- Querying locally, as IQ routing is not very viable... (yet).
		local public_service_vcard = hosts[host].public_service_vcard;
		if public_service_vcard then
			module:log("debug", "Setting directory item for local host %s", host);
			publish_item(host, public_service_vcard);
		end
	end
end

local function handle_removed_peer(host)
	module:log("debug", "Removing peer server %s subscription", host);
	service:retract("urn:xmpp:contacts", true, host);
end

local function process_disco_response(event)
	local origin, stanza = event.origin, event.stanza;
	local node, remote = jid_split(stanza.attr.from);
	
	if node then return; end -- correct?
	local is_subscribed = module:fire_event("peer-is-subscribed", remote);
	local is_public;
	if is_subscribed then
		local query = stanza:get_child("query", "http://jabber.org/protocol/disco#info")
		if not query then return; end
		
		for i, tag in ipairs(query.tags) do
			if tag.name == "feature" and tag.attr.var == "urn:xmpp:public-server" then
				is_public = true; break;
			end
		end

		if is_public then
			module:log("debug", "Processing disco info response from peer server %s", remote);
			local vcard_get = st.iq({ from = my_host, to = remote, type = "get", id = "directory_probe:vcard" })
				:tag("vcard", { xmlns = "urn:ietf:params:xml:ns:vcard-4.0" });
			module:send(vcard_get);
			return true;
		else
			return true;
		end
	end
end

local function process_vcard_response(event)
	local origin, stanza = event.origin, event.stanza;
	local node, remote = jid_split(stanza.attr.from);
	
	if node then return; end -- correct?	
	local is_subscribed = module:fire_event("peer-is-subscribed", remote);
	if is_subscribed then
		local vcard =  stanza:get_child("vcard", "urn:ietf:params:xml:ns:vcard-4.0");
		if vcard then
			module:log("info", "Processing server vcard from %s", remote);
			publish_item(remote, vcard);
			return true;
		else
			return true;
		end
	end
end

-- Define the Node Service, some stuff based on mod_pubsub.

local pubsub_lib = module:require "pubsub_aux";
local handlers = pubsub_lib.handlers;
local handlers_owner = pubsub_lib.handlers_owner;
local pubsub_error_reply = pubsub_lib.pubsub_error_reply;

function handle_pubsub_iq(event)
	local origin, stanza = event.origin, event.stanza;
	local pubsub = stanza.tags[1];
	local action = pubsub.tags[1];
	if not action then return origin.send(pubsub_error_reply(stanza, "bad-request")); end
	local handler;
	
	if (action.name == "items" or action.name == "subscribe" or action.name == "unsubscribe") and
	   action.attr.node == "urn:xmpp:contacts" then
		handler = handlers[stanza.attr.type.."_"..action.name];
		return handler(origin, stanza, action); 
	else
		return origin.send(pubsub_error_reply(stanza, "forbidden"));
	end
end

local function send(jids, stanza)
	for jid in pairs(jids) do
		stanza.attr.to = jid;
		module:send(stanza);
	end
end

function broadcast(self, node, jids, item)
	if type(item) == "string" and item == "deleted" then
		local deleted = st.message({ from = module.host, type = "headline" })
			:tag("event", { xmlns = xmlns_pubsub_event })
				:tag("delete", { node = node });
		send(jids, deleted);
	elseif type(item) == "string" and item == "purged" then
		local purged = st.message({ from = module.host, type = "headline" })
			:tag("event", { xmlns = xmlns_pubsub_event })
				:tag("purge", { node = node });
		send(jids, purged);
	else
		local message = st.message({ from = module.host, type = "headline" })
			:tag("event", { xmlns = xmlns_pubsub_event })
				:tag("items", { node = node });

		if item then
			item = st.clone(item);
			item.attr.xmlns = nil;
			message:get_child("event", xmlns_pubsub_event):get_child("items"):add_child(item);
		end
		send(jids, message);
	end
end

local function get_affiliation(self, jid, name, action)
	local bare_jid = jid_bare(jid);
	if type(jid) ~= "boolean" and bare_jid == my_host then
		return "owner";
	else
		return "none";
	end
end

function set_service(new_service)
	service = new_service;
	module.environment.service = service;
	pubsub_lib.set_service(service);
	service:restore(true);
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
			get_subscription = false;
			get_subscriptions = false;
			get_items = true;
			
			subscribe_other = false;
			unsubscribe_other = false;
			get_subscription_other = false;
			get_subscriptions_other = false;
			
			be_subscribed = true;
			be_unsubscribed = true;
			
			get_affiliations = false;
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
			
			get_affiliations = true;
			set_affiliation = true;
		};
	};
	
	node_default_config = {
		deliver_notifications = true;
		deliver_payloads = true;
		persist_items = true;
	};
	
	autocreate_on_publish = true;
	
	broadcaster = broadcast;
	get_affiliation = get_affiliation;
	
	normalize_jid = jid_bare;

	store = storagemanager.open(module.host, "sd_node");
}));

-- Hooks

module:hook("iq/host/http://jabber.org/protocol/pubsub:pubsub", handle_pubsub_iq);
module:hook("iq-result/host/directory_probe:disco", process_disco_response);
module:hook("iq-result/host/directory_probe:vcard", process_vcard_response);
module:hook("peer-subscription-completed", handle_subscribed_peer);
module:hook("peer-subscription-removed", handle_removed_peer);