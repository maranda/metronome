-- * Metronome IM *
--
-- This file is part of the Metronome XMPP server and is released under the
-- ISC License, please see the LICENSE file in this source package for more
-- information about copyright and licensing.

-- Backported from: https://git.polynom.me/PapaTutuWawa/prosody-modules

local st = require("util.stanza");
local array = require("util.array");
local jid_lib = require("util.jid");
local new_id = require("util.uuid").generate;
local datetime = require("util.datetime");
local pubsub = require("util.pubsub");
local storagemanager = require("core.storagemanager");

local helpers = module:require("helpers", "mix");
local namespaces = module:require("namespaces", "mix");
local lib_forms = module:require("forms", "mix");
local lib_stanzalog = module:require("stanzalog", "auxlibs");

local t_insert = table.insert;

local Participant = {};
Participant.__index = Participant;
function Participant:new(jid, nick, config)
    return setmetatable({
        jid = jid,
        nick = nick,
        config = config,
    }, Participant);
end

function Participant:from(config)
    return setmetatable(config, Participant);
end

local Channel = {};
Channel.__index = Channel;
function Channel:new(jid, name, description, participants, administrators, owners, subscriptions, spid, contacts, adhoc, allowed, banned, config, nodes)
    return setmetatable({
        jid = jid,
        name = name,
        description = description,
        participants = participants,
        subscriptions = subscriptions,
        spid = spid,
        contacts = contacts,
        adhoc = adhoc,
        administrators = administrators,
        owners = owners,
        config = config,
        nodes = nodes,
        allowed = allowed,
        banned = banned,
    }, Channel);
end
function Channel:from(config)
    -- Turn a channel into a Channel object
    local o = setmetatable(config, Channel);
    for i, _ in pairs(o.participants) do
        o.participants[i] = Participant:from(o.participants[i]);
    end
    return o;
end

function Channel:get_broadcaster()
    local function broadcast(kind, node, jids, item, _, node_obj)
        if node == namespaces.presence then
            -- NOTE: This assumes that we already added all necessary MIX data
            --       before publishing this item
            local presence = {};

            if kind == "retract" then
                presence = st.presence({
                    type = "unavailable",
                    from = self:get_encoded_participant_jid(item.attr.from),
                });
                presence:add_child(item:get_tag("mix", namespaces.mix_presence));
            else
                presence = stanza.clone(item);
            end

            for jid in pairs(jids) do
                module:log("debug", "Sending presence notification to %s from %s", jid, item.attr.from);
                message.attr.to = jid;
                module:send(presence);
            end
        else
        	if node_obj then
        		if node_obj.config["notify_"..kind] == false then
        			return;
        		end
        	end

        	if kind == "retract" then
        		kind = "items"; -- XEP-0060 signals retraction in an <items> container
         	end

        	if item then
        		item = st.clone(item);
        		item.attr.xmlns = nil; -- Clear the pubsub namespace

        		if kind == "items" then
        			if node_obj and node_obj.config.include_payload == false then
        				item:maptags(function () return nil; end);
        			end
        		end
        	end

          	local id = new_id();
            local message = st.message({ from = self.jid, type = "headline", id = id })
            	:tag("event", { xmlns = namespaces.pubsub_event })
            		:tag(kind, { node = node });

            if item then
            	message:add_child(item);
            end

        	for jid in pairs(jids) do
        		module:log("debug", "Sending notification to %s for node %s", jid, node);
        		message.attr.to = jid;
        		module:send(message);
        	end
        end
    end

    return broadcast;
end

-- PubSub stuff
local services = {}; -- room@server -> PubSub services

local function mix_store(channel)
	local driver = storagemanager.get_driver(module.host, "mix_data");
	return driver:open("mix_pubsub/"..channel);
end

function Channel:get_pubsub_service()
    local service = services[self.jid];
    if service then
        return service;
    end

    service = pubsub.new({
		capabilities = {
			none = {
				create = false;
				configure = false;
				delete = false;
				publish = false;
				purge = false;
				retract = false;
				get_nodes = true;
			
				subscribe = false;
				unsubscribe = false;
				get_subscription = true;
				get_subscriptions = true;
				get_items = true;
			
				subscribe_other = false;
				unsubscribe_other = false;
				get_subscription_other = false;
				get_subscriptions_other = false;
			
				be_subscribed = true;
				be_unsubscribed = true;
			
				get_affiliations = true;
				set_affiliation = false;
			};
			member = {
				create = false;
				configure = false;
				delete = false;
				publish = false;
				purge = false;
				retract = false;
				get_nodes = true;
			
				subscribe = false;
				unsubscribe = false;
				get_subscription = true;
				get_subscriptions = true;
				get_items = true;
			
				subscribe_other = false;
				unsubscribe_other = false;
				get_subscription_other = false;
				get_subscriptions_other = false;
			
				be_subscribed = true;
				be_unsubscribed = true;
			
				get_affiliations = true;
				set_affiliation = false;
			};
			publisher = {
				create = false;
				configure = false;
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
			
				get_affiliations = true;
				set_affiliation = false;
			};
			owner = {
				create = false;
				configure = false;
				delete = false;
				publish = true;
				purge = true;
				retract = true;
				get_nodes = true;
			
				subscribe = false;
				unsubscribe = false;
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
            persist_items = true;
            access_model = "open"; -- TODO
            max_items = 256; -- TODO: Once "max" is supported
        };

		normalize_jid = jid_lib.bare;

        broadcaster = self:get_broadcaster();
        store = mix_store(jid_lib.section(self.jid, "node"));
    });
    services[self.jid] = service;
    return service;
end

function Channel:get_spid(jid)
    -- Returns the Stable Participant ID for the *BARE* jid
    return self.spid[jid];
end

function Channel:set_spid(jid, spid)
    -- Sets the Stable Participant ID for the *BARE* jid
    self.spid[jid] = spid;
end

function Channel:find_participant(jid)
    -- Returns the index of a participant in a channel. Returns -1
    -- if the participant is not found
    local function is_participant(p)
        return p.jid == jid;
    end
    local _, participant = helpers.find(self.participants, is_participant);
    return participant;
end

function Channel:is_participant(jid)
    -- Returns true if jid is a participant of the channel. False otherwise.
    return self:find_participant(jid) ~= nil;
end

function Channel:get_encoded_participant_jid(jid)
    -- TODO: This assumes that jid is a participant
    local spid = self:get_spid(jid_lib.bare(jid));
    return spid.."#"..self.jid;
end

function Channel:is_subscribed(jid, node)
    -- Returns true of JID is subscribed to node on this channel. Returns false
    -- otherwise.
    return helpers.find_str(self.subscriptions[jid], node) ~= -1;
end

function Channel:debug_print()
    module:log("debug", "Channel %s (%s)", self.jid, self.name);
    module:log("debug", "'%s'", self.description);
    for _, p in pairs(self.participants) do
        module:log("debug", "=> %s (%s)", p.jid, p.nick);
    end

    module:log("debug", "Contacts:");
    for _, c in pairs(self.contacts) do
        module:log("debug", "=> %s", c);
    end

    if self.subscriptions then
        module:log("debug", "Subscriptions:");
        for user, subs in pairs(self.subscriptions) do
            module:log("debug", "[%s]", user);
            for _, sub in pairs(subs) do
                module:log("debug", "=> %s", sub);
            end
        end
    end
end

function Channel:broadcast_message(message, participant, archive)
    -- Broadcast a message stanza according to rules layed out by
    -- XEP-0369
    local msg = st.clone(message);
    msg:add_child(st.stanza("mix", { xmlns = namespaces.mix_core })
                    :tag("nick"):text(participant.nick):up()
                    :tag("jid"):text(participant.jid):up());

    msg.attr.from = self.jid;
	module:fire_event("store-stanza-log", jid_lib.section(self.jid, "node"), jid_lib.section(self.jid, "host"),
		lib_stanzalog.process_stanza(self.jid, message, archive)
	);
    msg.attr.from = self.jid.."/"..self:get_spid(participant.jid);

    if module:fire_event("mix-broadcast-message", { message = msg, channel = self }) then
        return;
    end

    for _, p in pairs(self.participants) do
        -- Only users who subscribed to the messages node should receive
        -- messages
        if self:is_subscribed(p.jid, namespaces.messages) then
            local tmp = st.clone(msg);
            tmp.attr.to = p.jid;
            module:send(tmp);
        end
    end
end

function Channel:publish_participant(spid, participant)
    -- Publish a new participant on the service
    -- NOTE: This function has be to called *after* the new participant
    --       has been added to the channel.participants array
    local srv = self:get_pubsub_service();

    srv.nodes(namespaces.participants,
                        true,
                        { ["max_items"] = #self.participants });
    srv:publish(namespaces.participants,
                true,
                spid,
                st.stanza("item", { id = spid, xmlns = "http://jabber.org/protocol/pubsub" })
                    :tag("participant", { xmlns = namespaces.mix_core })
                        :tag("nick"):text(participant["nick"]):up()
                        :tag("jid"):text(participant["jid"]), self.jid);
end

function Channel:remove_participant(jid)
    -- Removes a user form the channel. May be a kick, may be a leave.
    local srv = self:get_pubsub_service();

    -- Step 1: Unsubscribe from all subscribed nodes
    for _, node in ipairs(self.subscriptions[jid]) do
        srv:remove_subscription(node, true, jid);
    end
    self.subscriptions[jid] = nil;

    -- Step 2: Remove affiliations to all nodes
    for _, node in ipairs(self.nodes) do
        srv:set_affiliation(node, true, jid, "outcast");
    end

    -- Step 3: Remove jid as participant
    local participant = self:find_participant(jid);
    self.participants = array.filter(self.participants, function (p) return p.jid ~= jid end);

    -- Step 4: Retract jid from participants node
    local spid = self:get_spid(jid);
    local notifier = st.stanza("retract", { id = spid });
    srv:retract(namespaces.participants, true, jid, notifier);
    self:save_state();
end

function Channel:publish_info(srv)
    local timestamp = datetime.datetime(os.time());
    local info = st.stanza("item", { id = timestamp, xmlns = namespaces.pubsub })
                    :add_child(lib_forms.mix_info:form({
                        ["FORM_TYPE"] = "hidden",
                        ["Name"] = self.name,
                        ["Description"] = self.description,
                        ["Contact"] = self.contacts
                    }, "result"));
    srv:publish(namespaces.info, true, timestamp, info, self.jid);
end


local function get_node_access_model(node, adhoc)
    -- TODO
    if adhoc then
        return "whitelist";
    else
        return "open";
    end
end

local function get_node_max_items(node)
    -- TODO: Would be nice if we could just return "max"
    -- TODO: Handle all nodes
    if node == namespaces.messages then
        return 0;
    elseif node == namespaces.info or
        node == namespaces.config then
        return 1;
    end

    return 256;
end

local function channel_not_found(stanza)
    -- Wrapper for returning a "Channel-not-found" error stanza
    return st.error_reply(stanza,
                          "cancel",
                          "item-not-found",
                          "The MIX channel was not found");
end

function Channel:set_affiliation(node, target, role)
    -- Set the affiliation of target to node depending on what
    -- node it is and whether target is the creator or not
    local srv = self:get_pubsub_service();
    local affiliation = "member";
    if node == namespaces.presence then
        affiliation = "none";
    end

    -- TODO(MIX-ADMIN): Also handle OWNER, ADMIN
    if role == "creator" then
        if node == namespaces.info or
            node == namespaces.allowed or
            node == namespaces.banned or
            node == namespaces.config or
            node == namespaces.avatar or
            node == namespaces.avatar_metadata then
            affiliation = "publisher";
        end
    end

    srv:set_affiliation(node, true, target, affiliation);
end

function Channel:may_subscribe(actor, node, joining)
    if joining then
        -- TODO: Is this true?
        return true;
    end

    if self:is_participant(actor) then
        -- TODO(MIX-ADMIN): This is possible if the actor is an owner or admin
        return node ~= namespaces.config;
    end

    return false;
end

function Channel:may_publish(actor, node)
    return node ~= namespaces.presence and node ~= namespaces.messages;
end

function Channel:may_retract(actor, node)
    -- TODO: Maybe put may_{publish, retract} together
    return node ~= namespaces.presence and node ~= namespaces.messages;
end

function Channel:may_retrieve_items(actor, node)
    return node ~= namespaces.presence and node ~= namespaces.messages;
end

function Channel:may_join(actor)
    -- TODO(MIX-ADMIN): Check the allowed and banned node
    return true;
end

return {
    Channel = Channel;
    Participant = Participant;
    get_node_access_model = get_node_access_model;
    get_node_max_items = get_node_max_items;
    channel_not_found = channel_not_found;
};
