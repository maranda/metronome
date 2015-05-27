-- * Metronome IM *
--
-- This file is part of the Metronome XMPP server and is released under the
-- ISC License, please see the LICENSE file in this source package for more
-- information about copyright and licensing.
--
-- As per the sublicensing clause, this file is also MIT/X11 Licensed.
-- ** Copyright (c) 2009-2013, Kim Alvefur, Markus Kutter, Matthew Wild, Waqas Hussain

if module:get_host_type() ~= "component" then
	error("MUC should be loaded as a component.", 0);
end

local muc_host = module:get_host();
local muc_name = module:get_option("name");
if type(muc_name) ~= "string" then muc_name = "Metronomical Chatrooms"; end
local restrict_room_creation = module:get_option("restrict_room_creation");
if restrict_room_creation then
	if restrict_room_creation == true then 
		restrict_room_creation = "admin";
	elseif restrict_room_creation ~= "admin" and restrict_room_creation ~= "local" then
		restrict_room_creation = nil;
	end
end
local muclib = module:require "muc";
local muc_new_room = muclib.new_room;
local jid_section = require "util.jid".section;
local jid_bare = require "util.jid".bare;
local st = require "util.stanza";
local uuid_gen = require "util.uuid".generate;
local datamanager = require "util.datamanager";
local fire_event = metronome.events.fire_event;
local um_is_admin = require "core.usermanager".is_admin;
local hosts = hosts;
local pairs, ipairs = pairs, ipairs;

rooms = {};
local host_session = hosts[muc_host];
local rooms = rooms;
local persistent_rooms = datamanager.load(nil, muc_host, "persistent") or {};

module:add_feature("http://jabber.org/protocol/muc");

-- Configurable options
local max_history_messages = module:get_option_number("max_history_messages", 100);
muclib.set_max_history(max_history_messages);

-- Superuser Adhoc handlers
module:depends("adhoc");
local adhoc_new = module:require "adhoc".new;

local function dummy_change(jid, affiliation)
	local res_aff = affiliation;
	for _, room in pairs(rooms) do
		if not affiliation then --restore affiliation.
			res_aff = room._affiliations[jid_bare(jid)] or "none";
		end
		for _, occupant in pairs(room._occupants) do
			if occupant.jid == jid or occupant.sessions[jid] then
				room:set_affiliation(true, jid, nil, nil, nil, res_aff);
			end
		end
	end
end
local function toggle_muc_su_handler(self, data, state)
	if not muclib.admin_toggles[jid_bare(data.from)] then
		muclib.admin_toggles[jid_bare(data.from)] = true;
		dummy_change(data.from, "owner");
		return { status = "completed", info = "MUC SU mode activated, you will now be an owner of every room you will join." };
	else
		muclib.admin_toggles[jid_bare(data.from)] = nil;
		dummy_change(data.from);
		return { status = "completed", info = "MUC SU mode deactivated." };
	end
end
local toggle_muc_su_descriptor = adhoc_new("Toggle Superuser mode for Multi-user chats.", "toggle", toggle_muc_su_handler, "admin");
module:provides("adhoc", toggle_muc_su_descriptor);

local function is_admin(jid)
	return um_is_admin(jid, module.host);
end

local _set_affiliation = muc_new_room.room_mt.set_affiliation;
local _get_affiliation = muc_new_room.room_mt.get_affiliation;
function muclib.room_mt:get_affiliation(jid)
	if muclib.admin_toggles[jid_bare(jid)] then return "owner"; end
	return _get_affiliation(self, jid);
end
function muclib.room_mt:set_affiliation(actor, jid, affiliation, callback, reason, dummy)
	if dummy then return _set_affiliation(self, actor, jid, affiliation, callback, reason, dummy); end
	if muclib.admin_toggles[jid_bare(jid)] then return nil, "modify", "not-acceptable"; end
	return _set_affiliation(self, actor, jid, affiliation, callback, reason);
end

local function room_route_stanza(room, stanza) 
	fire_event("route/post", host_session, stanza); 
end
local function room_save(room, forced)
	local node = jid_section(room.jid, "node");
	persistent_rooms[room.jid] = room._data.persistent;
	if room._data.persistent then
		local history = room._data.history;
		room._data.history = nil;
		local data = {
			jid = room.jid;
			_data = room._data;
			_affiliations = room._affiliations;
		};
		datamanager.store(node, muc_host, "config", data);
		room._data.history = history;
	elseif forced then
		datamanager.store(node, muc_host, "config", nil);
		if not next(room._occupants) then -- Room empty
			rooms[room.jid] = nil;
		end
	end
	if forced then datamanager.store(nil, muc_host, "persistent", persistent_rooms); end
end

local persistent_errors = false;
for jid in pairs(persistent_rooms) do
	local node = jid_section(jid, "node");
	local data = datamanager.load(node, muc_host, "config");
	if data then
		local history_length = data._data.history_length;
		local room = muc_new_room(jid);
		room._data = data._data;
		room._affiliations = data._affiliations;
		if history_length and history_length > max_history_messages then
			room._data.history_length = 20;
		end 
		room.route_stanza = room_route_stanza;
		room.save = room_save;
		rooms[jid] = room;
	else -- missing room data
		persistent_rooms[jid] = nil;
		module:log("error", "Missing data for room '%s', removing from persistent room list", jid);
		persistent_errors = true;
	end
end
if persistent_errors then datamanager.store(nil, muc_host, "persistent", persistent_rooms); end

local host_room = muc_new_room(muc_host);
host_room.route_stanza = room_route_stanza;
host_room.save = room_save;

local function get_disco_info(stanza)
	local done = {};
	local reply = st.iq({type = "result", id = stanza.attr.id, from = muc_host, to = stanza.attr.from})
		:query("http://jabber.org/protocol/disco#info")
			:tag("identity", {category = "conference", type = "text", name = muc_name}):up();

	for _, feature in ipairs(module:get_items("feature")) do
		if not done[feature] then
			reply:tag("feature", {var = feature}):up();
			done[feature] = true;
		end
	end
	return reply;
end
local function get_disco_items(stanza)
	local reply = st.iq({type = "result", id = stanza.attr.id, from = muc_host, to = stanza.attr.from})
		:query("http://jabber.org/protocol/disco#items");
	for jid, room in pairs(rooms) do
		if not room:get_option("hidden") then
			reply:tag("item", {jid = jid, name = room:get_name()}):up();
		end
	end
	return reply; -- TODO cache disco reply
end

local function handle_to_domain(event)
	local origin, stanza = event.origin, event.stanza;
	local type = stanza.attr.type;
	if type == "error" or type == "result" then return; end
	if stanza.name == "iq" and type == "get" then
		local xmlns = stanza.tags[1].attr.xmlns;
		if xmlns == "http://jabber.org/protocol/disco#info" then
			origin.send(get_disco_info(stanza));
		elseif xmlns == "http://jabber.org/protocol/disco#items" then
			origin.send(get_disco_items(stanza));
		elseif xmlns == "http://jabber.org/protocol/muc#unique" then
			origin.send(st.reply(stanza):tag("unique", {xmlns = xmlns}):text(uuid_gen())); -- FIXME Random UUIDs can theoretically have collisions
		else
			origin.send(st.error_reply(stanza, "cancel", "service-unavailable")); -- TODO disco/etc
		end
	else
		host_room:handle_stanza(origin, stanza);
		--origin.send(st.error_reply(stanza, "cancel", "service-unavailable", "The muc server doesn't deal with messages and presence directed at it"));
	end
	return true;
end

function stanza_handler(event)
	local origin, stanza = event.origin, event.stanza;
	local bare = jid_bare(stanza.attr.to);
	local room = rooms[bare];
	if not room then
		if stanza.name ~= "presence" then
			origin.send(st.error_reply(stanza, "cancel", "item-not-found"));
			return true;
		end
		local from_host = jid_section(stanza.attr.from, "host");
		if not origin.is_anonymous and
		   (not restrict_room_creation or (restrict_room_creation == "admin" and is_admin(stanza.attr.from)) or
		   (restrict_room_creation == "local" and from_host == module.host:gsub("^[^%.]+%.", ""))) then
			room = muc_new_room(bare);
			room.route_stanza = room_route_stanza;
			room.save = room_save;
			rooms[bare] = room;
		end
	end
	if room then
		room:handle_stanza(origin, stanza);
		if not next(room._occupants) and not persistent_rooms[room.jid] then -- empty, non-persistent room
			rooms[bare] = nil; -- discard room
		end
	else
		origin.send(st.error_reply(stanza, "cancel", "not-allowed"));
	end
	return true;
end

local function clean_affiliations(event)
	local bare = event.username.."@"..event.host;
	for _, room in pairs(rooms) do
		local has_owner;
		room._affiliations[bare] = nil;
		for _, aff in pairs(room._affiliations) do
			if aff == "owner" then has_owner = true; break; end
		end
		if not has_owner then room:destroy(nil, "Room became orphan as its last owner's account has been deleted, destroying.") end
	end
end

module:hook_global("user-deleted", clean_affiliations);

module:hook("iq/bare", stanza_handler, -1);
module:hook("message/bare", stanza_handler, -1);
module:hook("presence/bare", stanza_handler, -1);
module:hook("iq/full", stanza_handler, -1);
module:hook("message/full", stanza_handler, -1);
module:hook("presence/full", stanza_handler, -1);
module:hook("iq/host", handle_to_domain, -1);
module:hook("message/host", handle_to_domain, -1);
module:hook("presence/host", handle_to_domain, -1);

hosts[module.host].send = function(stanza) -- FIXME do a generic fix
	if stanza.attr.type == "result" or stanza.attr.type == "error" then
		module:send(stanza);
	else error("component.send only supports result and error stanzas at the moment"); end
end

hosts[module:get_host()].muc = { rooms = rooms };

local saved = false;
module.save = function()
	saved = true;
	return { rooms = rooms, admin_toggles = muclib.admin_toggles };
end
module.restore = function(data)
	for jid, oldroom in pairs(data.rooms or {}) do
		local room = muc_new_room(jid);
		room._jid_nick = oldroom._jid_nick;
		room._occupants = oldroom._occupants;
		room._data = oldroom._data;
		room._affiliations = oldroom._affiliations;
		room.route_stanza = room_route_stanza;
		room.save = room_save;
		rooms[jid] = room;
	end
	hosts[module:get_host()].muc = { rooms = rooms };
	muclib.admin_toggles = data.admin_toggles or {};
end

function shutdown_room(room, stanza)
	for nick, occupant in pairs(room._occupants) do
		stanza.attr.from = nick;
		for jid in pairs(occupant.sessions) do
			stanza.attr.to = jid;
			room:_route_stanza(stanza);
			room._jid_nick[jid] = nil;
		end
		room._occupants[nick] = nil;
	end
end
function shutdown_component()
	if not saved then
		local stanza = st.presence({type = "unavailable"})
			:tag("x", {xmlns = "http://jabber.org/protocol/muc#user"})
				:tag("item", {affiliation = "none", role = "none"}):up()
				:tag("status", { code = "332"}):up();
		for roomjid, room in pairs(rooms) do
			shutdown_room(room, stanza);
		end
		shutdown_room(host_room, stanza);
	end
end
module.unload = shutdown_component;
module:hook_global("server-stopping", shutdown_component);
