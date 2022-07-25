-- * Metronome IM *
--
-- This file is part of the Metronome XMPP server and is released under the
-- ISC License, please see the LICENSE file in this source package for more
-- information about copyright and licensing.

-- Backported from: https://git.polynom.me/PapaTutuWawa/prosody-modules

-- TODO: Handle creation and deletion of avatar nodes when publishing to :config
-- TODO: Somehow make the hosts aware of our "presence"

local host = module:get_host();
if module:get_host_type() ~= "component" then
    error("MIX should be loaded as a component", 0);
end

module:depends("stanza_log");

local storagemanager = require "core.storagemanager";

local st = require("util.stanza");
local jid = require("util.jid");
local uuid = require("util.uuid");
local datetime = require("util.datetime");
local dataforms = require("util.dataforms");
local array = require("util.array");
local set = require("util.set");

local helpers = module:require("helpers", "mix");
local namespaces = module:require("namespaces", "mix");
local lib_forms = module:require("forms", "mix");
local lib_mix = module:require("mix", "mix");

local Channel = lib_mix.Channel;
local Participant = lib_mix.Participant;

-- MAM Libraries

local lib_mam = module:require("mam", "mam");
local validate_query = module:require("validate", "mam").validate_query;
local fields_handler, generate_stanzas = lib_mam.fields_handler, lib_mam.generate_stanzas;

-- PubSub Libraries

local lib_pubsub = module:require ("pubsub", "auxlibs");
local handlers = lib_pubsub.handlers;
local handlers_owner = lib_pubsub.handlers_owner;
local pubsub_error_reply = lib_pubsub.pubsub_error_reply;
local pubsub_set_service = lib_pubsub.set_service;

-- Persistent data
local persistent_channels = storagemanager.open(host, "mix_channels");
local persistent_channel_data = storagemanager.open(host, "mix_data");

-- Configuration
local default_channel_description = module:get_option("default_description", "A MIX channel for chatting");
local default_channel_name = module:get_option("default_name", "MIX channel");
local restrict_channel_creation = module:get_option("restrict_local_channels", "local");
local service_name = module:get_option("name", "Metronome's MIX Channels");

-- MIX configuration
local default_mix_nodes = array { namespaces.info, namespaces.participants, namespaces.messages };

local channels = {};

local function find_channel(channel_jid)
    -- Return the channel object from the channels array for which the
    -- JID matches. If none is found, returns -1, nil
    local _, channel = helpers.find(channels, function(c) return c.jid == channel_jid; end);
    return channel;
end

local function save_channels()
    module:log("debug", "Saving channel list...");
    local channel_list = {};
    for _, channel in pairs(channels) do
        table.insert(channel_list, channel.jid);

        persistent_channel_data:set(channel.jid, channel);
    end

    persistent_channels:set("channels", channel_list);
    module:log("debug", "Saving channel list done.");
end

function Channel:save_state()
    -- Store the channel in the persistent channel store
    module:log("debug", "Saving channel %s...", self.jid);
    persistent_channel_data:set(self.jid, self);
    module:log("debug", "Saving done.", self.jid);
end

function module.load()
    module:log("info", "Loading MIX channels...");

    local channel_list = persistent_channels:get("channels");
    if channel_list then
        for _, channel_data in pairs(channel_list) do
            local channel = Channel:from(persistent_channel_data:get(channel_data));
            table.insert(channels, channel);
            module:log("debug", "MIX channel %s loaded", channel.jid);
        end
    else
        module:log("debug", "No MIX channels found.");
    end
    module:log("info", "Loading MIX channels done.");
end

-- PubSub logic
local function handle_pubsub_iq(event)
	local stanza, origin = event.stanza, event.origin;
    local from = jid.bare(stanza.attr.from);

    local channel = find_channel(stanza.attr.to);
    if not channel then
        module:log("error", "PubSub was used for unknown channel");
        origin:send(st.error_reply(stanza, "cancel", "item-not-found"));
        return;
    end;

	pubsub_set_service(channel:get_pubsub_service());

    -- Certain actions we do not want the user to perform, so we need to
    -- catch them here.
	local pubsub = stanza.tags[1];
	local action = pubsub.tags[1];
	if not action then return origin.send(pubsub_error_reply(stanza, "bad-request")); end
	-- We generally do not allow deletion, creation or configuration of
	-- nodes. (Un)Subscribing is not allowed as this is managed via
	-- interaction with the MIX host.
	-- NOTE: Checking for <delete> is not needed as no user is ever set as
	--       owner
	if pubsub:get_child("configure") then
		origin:send(pubsub_not_implemented(stanza, "config-node"));
		return true;
	end
	if pubsub:get_child("unsubscribe") or pubsub:get_child("subscribe") then
		origin:send(st.error_reply(stanza, "auth", "forbidden"));
		return true;
	end

	local handler;

	if pubsub.attr.xmlns == xmlns_pubsub_owner then
		handler = handlers_owner[stanza.attr.type.."_"..action.name];
	else
		handler = handlers[stanza.attr.type.."_"..action.name];
	end

	if handler then
		return handler(origin, stanza, action); 
	else
		return origin.send(pubsub_error_reply(stanza, "feature-not-implemented"));
	end
end
module:hook("iq/bare/"..namespaces.pubsub..":pubsub", handle_pubsub_iq, 1000);

local function can_create_channels(user)
    -- Returns true when the jid is allowed to create MIX channels. False otherwise.
    -- NOTE: Taken from plugins/muc/mod_muc.lua
    local host_suffix = host:gsub("^[^%.]+%.", "");
	local user_host = jid.section(user, "host")

    if restrict_channel_creation == "local" then
        module:log("debug", "Comparing %s (Sender) to %s (Host)", user_host, host_suffix);

        if user_host == host_suffix then
            return true;
        else
            return false;
        end
    elseif type(restrict_channel_creation) == "table" then
        if helpers.find_str(restrict_channel_creation, user) ~= -1 then
            -- User was specifically listed
            return true;
        elseif helpers.find_str(restrict_channel_creation, user_host) then
            -- User's host was allowed
            return true;
        end

        return false;
    end

    -- TODO: Handle also true/"admin" (See mod_muc)
    return true;
end

-- Disco related functionality
module:hook("iq-get/host/http://jabber.org/protocol/disco#items:query", function(event)
    module:log("debug", "host-disco-items called");
    local reply = st.reply(event.stanza):query("http://jabber.org/protocol/disco#items");
    for _, channel in pairs(channels) do
        -- Adhoc channels are supposed to be invisible
        if not channel.adhoc then
            reply:tag("item", { jid = channel.jid }):up();
        end
    end
	event.origin.send(reply);
	return true;
end);

local function handle_channel_disco_items(event)
    module:log("debug", "IQ-GET disco#items");

    local origin, stanza = event.origin, event.stanza;
    if stanza:get_child("query", "http://jabber.org/protocol/disco#items").attr.node ~= "mix" then
        origin.send(st.error_reply(stanza, "modify", "bad-request"));
        return true;
    end

    -- TODO: Maybe here we should check if the user has permissions to get infos
    -- about the channel before saying that it doesn't exist to prevent creating
    -- an oracle.
    local channel = find_channel(stanza.attr.to);
    if not channel then
        origin.send(lib_mix.channel_not_found(stanza));
        return true;
    end

    if not channel:is_participant(jid.bare(stanza.attr.from)) then
        origin.send(st.error_reply(stanza, "cancel", "forbidden"));
        return true;
    end

    local reply = st.reply(stanza):tag("query", { xmlns = "http://jabber.org/protocol/disco#items", node = "mix" });
    for _, node in pairs(channel.nodes) do
        reply:tag("item", { jid = channel.jid, node = node }):up();
    end

    origin.send(reply);
    return true;
end
module:hook("iq/bare/http://jabber.org/protocol/disco#items:query", handle_channel_disco_items);

module:hook("iq-get/host/http://jabber.org/protocol/disco#info:query", function(event)
    module:log("debug", "IQ-GET host disco#info");

    local origin, stanza = event.origin, event.stanza;
    local reply = st.reply(stanza)
                    :tag("query", { xmlns = "http://jabber.org/protocol/disco#info" })
                        :tag("identity", { category = "conference", type = "mix", name = service_name }):up()
                        :tag("feature", { var = "http://jabber.org/protocol/disco#info" }):up()
                        :tag("feature", { var = "http://jabber.org/protocol/disco#items" }):up()
                        :tag("feature", { var = namespaces.mix_core }):up();

    if can_create_channels(stanza.attr.from) then
        reply:tag("feature", { var = namespaces.mix_core.."#create-channel" }):up();
    end
    origin.send(reply);
    return true;
end, 1000);

local function handle_channel_disco_info(event)
    module:log("debug", "IQ-GET disco#info");

    local origin, stanza = event.origin, event.stanza;
    local channel = find_channel(stanza.attr.to);
    if not channel then
        origin.send(lib_mix.channel_not_found(stanza));
        return true;
    end
    local reply = st.reply(stanza):tag("query", { xmlns = "http://jabber.org/protocol/disco#info" });
    reply:tag("feature", { var = "http://jabber.org/protocol/disco#info" }):up();
    reply:tag("identity", { category = "conference", name = channel.name, type = "mix" }):up();

    reply:tag("feature", { var = namespaces.mix_core }):up();
    reply:tag("feature", { var = "urn:xmpp:mam:2" }):up();

    origin.send(reply);
    return true;
end
module:hook("iq-get/bare/http://jabber.org/protocol/disco#info:query", handle_channel_disco_info);

module:hook("iq-set/bare/"..namespaces.mam..":query", function(event)
    local stanza, origin = event.stanza, event.origin;
	local from = stanza.attr.from or origin.full_jid;
	local to = stanza.attr.to;
	local query = stanza.tags[1];
	local qid = query.attr.queryid;

	local channel = find_channel(to);

    if not channel then
        -- TODO: Is this correct?
        origin.send(lib_mix.channel_not_found(stanza));
        return true;
    end

    -- Check if the user is subscribed to the messages node
    if not channel:is_subscribed(from, namespaces.messages) then
        origin.send(st.error_reply(stanza, "cancel", "forbidden"));
        return true;
    end

	local start, fin, with, after, before, max, index;
	local ok, ret = validate_query(stanza, query, qid);
	if not ok then
		return origin.send(ret);
	else
		start, fin, with, after, before, max, index =
			ret.start, ret.fin, ret.with, ret.after, ret.before, ret.max, ret.index;
	end

	local archive = { 
		logs = module:fire("stanza-log-load", jid_section(to, "node"), host, start, fin, before, after)
	};
		
	local messages, rq, count = generate_stanzas(archive, start, fin, with, max, after, before, index, qid, { origin, stanza });
	if not messages then
		module:log("debug", "%s MAM query RSM parameters were out of bounds", to);
		local rsm_error = st.error_reply(stanza, "cancel", "item-not-found");
		rsm_error:add_child(query);
		return origin.send(rsm_error);
	end
	
	local reply = st.reply(stanza):add_child(rq);
	
	for _, message in ipairs(messages) do
		message.attr.from = to;
		message.attr.to = from;
		origin.send(message);
	end
	origin.send(reply);
	
	module:log("debug", "MAM query %s completed (returned messages: %s)",
		qid and qid or "without id", count == 0 and "none" or tostring(count));

	return true;
end);

module:hook("iq-get/bare/"..namespaces.mam..":query", fields_handler);
module:hook("iq/bare/"..namespaces.mam..":prefs", function(event)
	local origin, stanza = event.origin, event.stanza;
	origin.send(st.error_reply(stanza, "cancel", "feature-not-implemented"));
	return true;
end);

module:hook("iq-set/bare/"..namespaces.mix_core..":leave", function(event)
    module:log("debug", "MIX leave received");
    local origin, stanza = event.origin, event.stanza;
    local from = jid.bare(stanza.attr.from);
    local channel = find_channel(stanza.attr.to);
    if not channel then
        origin.send(lib_mix.channel_not_found(stanza));
        return true;
    end

    local participant = channel:find_participant(from);
    if not participant then
        origin.send(st.error_reply(stanza,
                                   "cancel",
                                   "forbidden",
                                   "Not a participant"));
        channel:debug_print();
        module:log("debug", "%s is not a participant in %s", from, channel.jid);
        return true;
    end

    channel:remove_participant(from);

    module:fire_event("mix-channel-leave", { channel = channel, participant = participant });

    origin.send(st.reply(stanza):tag("leave", { xmlns = namespaces.mix_core }));
    return true;
end);

module:hook("iq-set/bare/"..namespaces.mix_core..":join", function(event)
    module:log("debug", "MIX join received");

    local origin, stanza = event.origin, event.stanza;
    local from = jid.bare(stanza.attr.from);
    local channel = find_channel(stanza.attr.to);
    if not channel then
        origin:send(lib_mix.channel_not_found(stanza));
        return true;
    end

    -- Prevent the user from joining multiple times
    local participant = channel:find_participant(from);
    if participant then
        module:send(st.error_reply(stanza, "cancel", "conflict", "User already joined"));
        return true;
    end

    -- Is the user allowed to join?
    if not channel:may_join(from) then
        origin:send(st.error_reply(stanza, "cancel", "forbidden", "User or host is banned"));
        return true;
    end

    local spid = channel:get_spid(from) or uuid.generate(); -- Stable Participant ID
    local reply = st.reply(stanza)
                    :tag("join", { xmlns = namespaces.mix_core, id = spid });
    local join = stanza:get_child("join", namespaces.mix_core);
    local nick_tag = join:get_child("nick");

    local nick;
    if not nick_tag then
        nick = jid.node(from);
    else
        nick = nick_tag:get_text();
    end
    module:log("debug", "User joining as nick %s", nick);

    local srv = channel:get_pubsub_service(jid.node(channel.jid));
    local nodes = {};
    local has_subscribed_once = false;
    local first_error = nil;
    for subscribe in join:childtags("subscribe") do
        -- May the user subscribe to the node?
        module:log("debug", "Subscribing user to node %s", subscribe.attr.node);
        if channel:may_subscribe(from, subscribe.attr.node, true) then
            local ok, err = srv:add_subscription(subscribe.attr.node, true, from);
            if not ok then
                module:log("debug", "Error during subscription: %s", err);

                -- MIX-CORE says that the first error should be returned when
                -- no of the requested nodes could be subscribed to
                if first_error ~= nil then
                    first_error = err;
                end
            else
                table.insert(nodes, subscribe.attr.node);
                reply:tag("subscribe", { node = subscribe.attr.node }):up();
                has_subscribed_once = true;
            end

            -- Set the correct affiliation
            channel:set_affiliation(subscribe.attr.node, from, "member");
        else
            module:log("debug", "Error during subscription: may_subscribe returned false");
            if first_error ~= nil then
                first_error = "Channel does not allow subscribing";
            end
        end
    end

    if not has_subscribed_once then
        -- TODO: This does not work
        origin:send(st.error_reply(stanza, "cancel", first_error));
        return true;
    end

    -- TODO: Participant configuration

    local participant = Participant:new(jid.bare(from), nick, {});
    channel.subscriptions[from] = nodes;
    table.insert(channel.participants, participant)
    channel:set_spid(jid.bare(stanza.attr.from), spid);
    channel:publish_participant(spid, participant);
    channel:save_state();

    module:fire_event("mix-channel-join", { channel = channel, participant = participant });

    -- We do not reuse nick_tag as it might be nil
    reply:tag("nick"):text(nick):up();
    origin.send(reply);
    return true
end);

module:hook("iq-set/bare/"..namespaces.mix_core..":setnick", function(event)
    module:log("debug", "MIX setnick received");
    local origin, stanza = event.origin, event.stanza;
    local from = jid.bare(stanza.attr.from);
    local channel = find_channel(stanza.attr.to);
    if not channel then
        origin.send(lib_mix.channel_not_found(stanza));
        return true;
    end

    local participant = channel:find_participant(from);
    if not participant then
        channel:debug_print();
        module:log("debug", "%s is not a participant in %s", from, channel.jid);
        return true;
    end

    local setnick = stanza:get_child("setnick", namespaces.mix_core);
    local nick = setnick:get_child("nick");
    if nick == nil then
        origin.send(st.error_reply(stanza, "cancel", "bad-request", "Missing <nick>"));
        return true;
    end

    -- Change the nick
    participant.nick = nick:get_text();
    -- Inform all other members
    channel:publish_participant(channel:get_spid(participant.jid), participant);

    module:fire_event("mix-change-nick", { channel = channel, participant = participant });

    origin.send(st.reply(stanza)
                    :tag("setnick", { xmlns = namespaces.mix_core })
                        :tag("nick"):text(nick:get_text()));
    channel:save_state();
    return true;
end);

local function create_channel(node, creator, adhoc)
    -- TODO: Now all properties from the admin dataform are covered
    local channel = Channel:new(jid.join(node, host), -- Channel JID
                                default_channel_name,
                                default_channel_description,
                                {},             -- Participants
                                {},             -- Administrators
                                { creator },    -- Owners
                                {},             -- Subscriptions
                                {},             -- SPID mapping
                                { creator },    -- Contacts
                                adhoc,          -- Is channel an AdHoc channel
                                {},             -- Allowed
                                {},             -- Banned
                                lib_mix.default_channel_configuration, -- Channel config
                                {});            -- Present nodes

    -- Create the PubSub nodes
    local srv = channel:get_pubsub_service();
    for _, psnode in ipairs(default_mix_nodes) do
        srv:create(psnode, true, {
            -- NOTE: Our custom PubSub service is persistent only, so we don't
            --       need to explicitly set it
            access_model = lib_mix.get_node_access_model(psnode, adhoc);
            max_items = lib_mix.get_node_max_items(psnode);
        }, creator);
        channel:set_affiliation(psnode, creator, "creator");
        table.insert(channel.nodes, psnode);
    end

    channel:publish_info(srv);
    table.insert(channels, channel);
end

module:hook("iq-set/host/"..namespaces.mix_core..":create", function(event)
    module:log("debug", "MIX create received");
    local origin, stanza = event.origin, event.stanza;
    local from = jid.bare(stanza.attr.from);

    -- Check permissions
    if not can_create_channels(from) then
        origin.send(st.error_reply(stanza, "cancel", "forbidden", "Not authorized to create channels"));
        return true;
    end

    local create = stanza:get_child("create", namespaces.mix_core);
    local node;
    if create.attr.channel ~= nil then
        -- Create non-adhoc channel
        module:log("debug", "Attempting to create channel %s", create.attr.channel);
        node = create.attr.channel;
        local channel = find_channel(create.attr.channel.."@"..stanza.attr.to);
        if channel then
            origin.send(st.error_reply(stanza,
                                       "cancel",
                                       "conflict",
                                       "Channel already exists"));
            return true;
        end

        create_channel(create.attr.channel, from, false);
    else
        -- Create adhoc channel
        while (true) do
            node = id.short();
            local ch = find_channel(string.format("%s@%s", node, host));
            if not ch then
                break;
            end
        end

        create_channel(node, from, true);
    end
    module:log("debug", "Channel %s created with %s as owner", node, from);
    -- TODO: Add an event

    origin.send(st.reply(stanza)
                :tag("create", { xmlns = namespaces.mix_core, channel = node }));
    save_channels();
    return true;
end);

module:hook("iq-set/host/"..namespaces.mix_core..":destroy", function(event)
    module:log("debug", "MIX destroy received");
    local origin, stanza = event.origin, event.stanza;
    local from = jid.bare(stanza.attr.from);

    local destroy = stanza:get_child("destroy", namespaces.mix_core);
    local node = destroy.attr.channel;
    local node_jid = jid.join(node, host);
    local channel = find_channel(node_jid);
    if not channel then
        origin.send(lib_mix.channel_not_found(stanza));
        return true;
    end

    -- TODO(MIX-ADMIN): Check if the user is the owner of the channel
    -- Until then, we just check if the user is in the contacts
    if helpers.find_str(channel.contacts, from) == -1 then
        origin.send(st.error_reply(stanza, "cancel", "forbidden"));
        return true;
    end

    if module:fire_event("mix-destroy-channel", { channel = channel }) then
        return true;
    end

    -- Remove all registered nodes
    local srv = channel:get_pubsub_service();
    for _, psnode in pairs(channel.nodes) do
        srv:delete(psnode, true);
    end
    channels = array.filter(channels, function (c) return c.jid ~= node_jid end); 

    module:fire_event("mix-channel-destroyed", { channel = channel });
    module:log("debug", "Channel %s destroyed", node);

    origin.send(st.reply(stanza));
    save_channels();
    return true;
end);

module:hook("message/bare", function(event)
    module:log("debug", "MIX message received");
    local stanza, origin = event.stanza, event.origin;
    if stanza.attr.type ~= "groupchat" then
        origin.send(st.error_reply(stanza, "modify", "bad-request", "Non-groupchat message"));
        return true;
    end

    local from = jid.bare(stanza.attr.from);
    local channel = find_channel(stanza.attr.to);
    if not channel then
        origin.send(lib_mix.channel_not_found(stanza));
        return true;
    end

    local participant = channel:find_participant(from);
    if not participant then
        origin.send(st.error_reply(stanza, "cancel", "forbidden", "Not a participant"));
        return true;
    end

	local now = os.time();

    -- Handles sending the message accordingly, firing an event and
    -- even doing nothing if an event handler for "mix-broadcast-message"
    -- returns true.
    channel:broadcast_message(stanza, participant,
		module:fire_event("load-stanza-log", jid.section(stanza.attr.to, "node"), host, now, now) or {}
	);
    return true;
end);
