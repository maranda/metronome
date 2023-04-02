-- * Metronome IM *
--
-- This file is part of the Metronome XMPP server and is released under the
-- ISC License, please see the LICENSE file in this source package for more
-- information about copyright and licensing.

-- Backported from: https://git.polynom.me/PapaTutuWawa/prosody-modules

local module_host = module:get_host();

local jid = require("util.jid");
local st = require("util.stanza");
local send_to_available_resources = require("core.sessionmanager").send_to_available_resources;
local storagemanager = require("core.storagemanager");
local rm_remove_from_roster = require("util.rostermanager").remove_from_roster;
local rm_add_to_roster = require("util.rostermanager").add_to_roster;
local rm_roster_push = require("util.rostermanager").roster_push;
local rm_load_roster = require("util.rostermanager").load_roster;

-- Persistent storage
local mix_pam = storagemanager.open(module_host, "mix_pam");

-- Runtime data
local mix_hosts = {}; -- MIX host's JID -> Reference Counter

-- Namespaceing
local mix_pam_xmlns = "urn:xmpp:mix:pam:2";
local mix_roster_xmlns = "urn:xmpp:mix:roster:0";

module:add_feature(mix_pam_xmlns);
-- NOTE: To show that we archive messages
-- module:add_feature(mix_pam_xmlns.."#archive");

local function add_mix_host(host)
    if mix_hosts[host] then
        mix_hosts[host] = mix_hosts[host] + 1;
        module:log("debug", "Known MIX host has a new user");
    else
        module:log("debug", "Added %s as a new MIX host", host);
        mix_hosts[host] = 1;
    end

    mix_pam:set("hosts", mix_hosts);
end
local function remove_mix_host(host)
    if mix_hosts[host] then
        local count = mix_hosts[host];
        if count == 1 then
            mix_hosts[host] = nil;
            module:log("debug", "Removing %s as a mix host", host);
        else
            mix_hosts[host] = count - 1;
            module:log("debug", "Decrementing %s's user counter", host);
        end
    else
        module:log("debug", "Attempt to remove unknown MIX host");
    end

    mix_pam:set("hosts", mix_hosts);
end
local function is_mix_host(host)
    return mix_hosts[host] ~= nil;
end

local function is_mix_message(stanza)
    return stanza:get_child("mix", "urn:xmpp:mix:core:1") ~= nil;
end

function module.load()
    mix_hosts = mix_pam:get("hosts");
    module:log("info", "Loaded known MIX hosts");

    if not mix_hosts then
        module:log("info", "No known MIX hosts loaded");
        mix_hosts = {};
    end
    for host, _ in pairs(mix_hosts) do
        module:log("debug", "Known host: %s", host);
    end
end

local function handle_client_join(event)
    -- Client requests to join
    module:log("debug", "client-join received");
    local stanza, origin = event.stanza, event.origin;

    local client_join = stanza:get_child("client-join", mix_pam_xmlns);
    if client_join.attr.channel == nil then
        origin.send(st.error_reply(stanza, "cancel", "bad-request", "No channel specified"));
        return true;
    end
    local join = client_join:get_child("join", "urn:xmpp:mix:core:1");
    if join == nil then
        origin.send(st.error_reply(stanza, "cancel", "bad-request", "No join stanza"));
        return true;
    end

    -- Transform the client-join into a join
    local join_iq = st.iq({
        type = "set";
        from = jid.bare(stanza.attr.from);
        to = client_join.attr.channel;
        id = stanza.attr.id, xmlns = "jabber:client"
    });
    join_iq:add_child(join);

    module:send_iq(join_iq)
        :next(function(resp)
                -- Success
                handle_mix_join(resp, origin);
            end, function(resp)
                -- Error
                -- TODO
                local error_stanza = resp.stanza;
                error_stanza.attr.to = origin.full_jid;
                module:send(error_stanza);
            end);
    return true;
end

local function handle_client_leave(event)
    -- Client requests to leave
    module:log("debug", "client-leave received");
    local stanza, origin = event.stanza, event.origin;

    local client_leave = stanza:get_child("client-leave", mix_pam_xmlns);
    if client_leave.attr.channel == nil then
        origin.send(st.error_reply(stanza, "cancel", "bad-request", "No channel specified"));
        return true;
    end
    local leave = client_leave:get_child("leave", "urn:xmpp:mix:core:1");
    if leave == nil then
        origin.send(st.error_reply(stanza, "cancel", "bad-request", "No leave stanza"));
        return true;
    end

    -- Transform the client-join into a join
    local leave_iq = st.iq({
        type = "set";
        from = jid.bare(stanza.attr.from);
        to = client_leave.attr.channel;
        id = stanza.attr.id
    });
    leave_iq:add_child(leave);

    module:send_iq(leave_iq)
        :next(function(resp)
                handle_mix_leave(resp, origin);
            end, function(resp)
                -- Error
                -- TODO
                local error_stanza = resp.stanza;
                error_stanza.attr.to = origin.full_jid;
                module:send(error_stanza);
            end);
    return true;
end

module:hook("iq/self", function(event)
    local stanza = event.stanza;
    if #stanza.tags == 0 then return; end

    if stanza:get_child("client-join", mix_pam_xmlns) ~= nil then
        return handle_client_join(event);
    elseif stanza:get_child("client-leave", mix_pam_xmlns) ~= nil then
        return handle_client_leave(event);
    end
end);

local function handle_mix_join(event, origin)
    -- The MIX server responded
    module:log("debug", "Received MIX-JOIN result");

    local stanza = event.stanza;
    local spid = stanza:get_child("join", "urn:xmpp:mix:core:1").attr.id;
    local channel_jid = spid.."#"..stanza.attr.from;
    local resource = origin.resource;

    local client_join = st.iq({
        type = "result";
        id = stanza.attr.id;
        from = jid.bare(stanza.attr.to);
        to = stanza.attr.to.."/"..resource
    }):tag("client-join", { xmlns = mix_pam_xmlns, jid = channel_jid });

    client_join:add_child(stanza:get_child("join", "urn:xmpp:mix:core:1"));
    module:send(client_join);

    -- TODO: Error handling?
    rm_add_to_roster(origin, stanza.attr.from, {
        subscription = "none", -- TODO: This depends on MIX-ANON
        groups = {},
        mix_spid = spid,
    });
    rm_roster_push(jid.node(stanza.attr.to), module_host, stanza.attr.from);
    add_mix_host(jid.host(stanza.attr.from));

    return true;
end

local function handle_mix_leave(event, origin)
    -- The MIX server responded
    module:log("debug", "Received MIX-LEAVE result");

    local stanza = event.stanza;
    local resource = origin.resource;

    local client_leave = st.iq({
        type = "result";
        id = stanza.attr.id;
        from = jid.bare(stanza.attr.to);
        to = stanza.attr.to.."/"..resource
    }):tag("client-leave", { xmlns = mix_pam_xmlns });

    client_leave:add_child(stanza:get_child("leave", "urn:xmpp:mix:core:1"));
    module:send(client_leave);

    -- Remove from roster
    -- TODO: Error handling
    rm_remove_from_roster(origin, jid.bare(stanza.attr.from));
    rm_roster_push(jid.node(stanza.attr.to), module_host, jid.bare(stanza.attr.from));
    remove_mix_host(jid.bare(stanza.attr.from));

    return true;
end

module:hook("roster-get", function(event)
    -- NOTE: Currently this requires a patch to make mod_roster emit
    -- the roster-get event
    local reply, stanza = event.reply, event.stanza;
    local client_query = stanza:get_child("query", "jabber:iq:roster");
    if not client_query then return; end

    local annotate = client_query:get_child("annotate", mix_roster_xmlns);
    if not annotate then return; end

    module:log("debug", "Annotated roster request received");

    -- User requested the roster with an <annotate/>
    local roster = rm_load_roster(jid.node(stanza.attr.from), jid.host(stanza.attr.from));
    local query = reply:get_child("query", "jabber:iq:roster");
    query:maptags(function (item)
        -- Bail early, just in case
        if item.name ~= "item" then return item; end

        local spid = roster[item.attr.jid]["mix_spid"];
        if spid ~= nil then
            item:tag("channel", {
                xmlns = mix_roster_xmlns,
                ["participant-id"] = spid,
            });
        end

        return item;
    end);
end);

module:hook("message/bare", function(event)
    local stanza = event.stanza;
    local jid_host = jid.section(stanza.attr.from, "host");
    if not is_mix_host(jid_host) then return; end
    if not is_mix_message(stanza) then return; end

    -- Per XEP we know that stanza.attr.to is the user's bare JID
    -- TODO: Only send to resources that advertise support for MIX (When MIX clients are available for testing)
    local to = stanza.attr.to;
    send_to_available_resources(jid.node(to), jid.host(to), stanza);
    return true;
end);
