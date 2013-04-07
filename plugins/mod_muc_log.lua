-- Imported from prosody-modules, mod_muc_log

local metronome = metronome;
local tostring = tostring;
local splitJid = require "util.jid".split;
local cm = require "core.configmanager";
local datamanager = require "util.datamanager";
local data_load, data_store, data_getpath = datamanager.load, datamanager.store, datamanager.getpath;
local datastore = "muc_log";
local error_reply = require "util.stanza".error_reply;
local storagemanager = storagemanager;

local mod_host = module:get_host();
local config = nil;

-- Helper Functions

local function inject_storage_config()
	local _storage = cm.getconfig()[mod_host].core.storage;

	module:log("debug", "injecting storage config...");
	if type(_storage) == "string" then cm.getconfig()[mod_host].core.default_storage = _storage; end
	if type(_storage) == "table" then -- append
		_storage.muc_log = "internal";
	else
		cm.getconfig()[mod_host].core.storage = { muc_log = "internal" };
	end

	storagemanager.get_driver(mod_host, "muc_log"); -- init
end

-- Module Definitions

function logIfNeeded(e)
	local stanza, origin = e.stanza, e.origin;
	
	if	(stanza.name == "presence") or
		(stanza.name == "iq") or
	   	(stanza.name == "message" and tostring(stanza.attr.type) == "groupchat")
	then
		local node, host, resource = splitJid(stanza.attr.to);
		if node ~= nil and host ~= nil then
			local bare = node .. "@" .. host;
			if host == mod_host and metronome.hosts[host] ~= nil and metronome.hosts[host].muc ~= nil and metronome.hosts[host].muc.rooms[bare] ~= nil then
				local room = metronome.hosts[host].muc.rooms[bare]
				local today = os.date("%y%m%d");
				local now = os.date("%X")
				local mucTo = nil
				local mucFrom = nil;
				local alreadyJoined = false;
				
				if room._data.hidden then -- do not log any data of private rooms
					return;
				end
				if not room._data.logging then -- do not log where logging is not enabled
					return;
				end
				
				if stanza.name == "presence" and stanza.attr.type == nil then
					mucFrom = stanza.attr.to;
					if room._occupants ~= nil and room._occupants[stanza.attr.to] ~= nil then -- if true, the user has already joined the room
						alreadyJoined = true;
						stanza:tag("alreadyJoined"):text("true"); -- we need to log the information that the user has already joined, so add this and remove after logging
					end
				elseif stanza.name == "iq" and stanza.attr.type == "set" then -- kick, to is the room, from is the admin, nick who is kicked is attr of iq->query->item
					if stanza.tags[1] ~= nil and stanza.tags[1].name == "query" then
						local tmp = stanza.tags[1];
						if tmp.tags[1] ~= nil and tmp.tags[1].name == "item" and tmp.tags[1].attr.nick ~= nil then
							tmp = tmp.tags[1];
							for jid, nick in pairs(room._jid_nick) do
								if nick == stanza.attr.to .. "/" .. tmp.attr.nick then
									mucTo = nick;
									break;
								end
							end
						end
					end
				else
					for jid, nick in pairs(room._jid_nick) do
						if jid == stanza.attr.from then
							mucFrom = nick;
							break;
						end
					end
				end

				if (mucFrom ~= nil or mucTo ~= nil) then
					local data = data_load(node, host, datastore .. "/" .. today);
					local realFrom = stanza.attr.from;
					local realTo = stanza.attr.to;
					
					if data == nil then
						data = {};
					end
					
					stanza.attr.from = mucFrom;
					stanza.attr.to = mucTo;
					data[#data + 1] = "<stanza time=\"".. now .. "\">" .. tostring(stanza) .. "</stanza>\n";
					stanza.attr.from = realFrom;
					stanza.attr.to = realTo;
					if alreadyJoined == true then
						if stanza[#stanza].name == "alreadyJoined" then  -- normaly the faked element should be the last, remove it when it is the last
							stanza[#stanza] = nil;
						else
							for i = 1, #stanza, 1 do
								if stanza[i].name == "alreadyJoined" then  -- remove the faked element
									stanza[i] = nil;
									break;
								end
							end
						end
					end
					data_store(node, host, datastore .. "/" .. today, data);
				end
			end
		end
	end
end

module:hook("message/bare", logIfNeeded, 500);
module:hook("iq/bare", logIfNeeded, 500);
module:hook("presence/full", logIfNeeded, 500);

-- Define config methods

local function config_field_method(self)
	local ns = "muc#roomconfig_enablelogging";
	local field = {
		name = ns,
		type = "boolean",
		label = "Enable room logging?",
		value = self.cc_registry[ns].is_method(self);
	};

	return field;
end
local function config_is_method(self) return self._data.logging; end
local function config_set_method(self, logging)
	logging = logging and true or nil;
	if self._data.logging ~= logging then
		self._data.logging = logging;
		if self.save then self:save(true); end
	end
end
local function config_check_method(self, default, custom, stanza)
	local reply;
	if not default.public and custom.logging then
		reply = error_reply(stanza, "cancel", "forbidden", "You can enable logging only into public rooms!");
	end
	return reply;
end
local function config_ac_method(self, logging, msg_st)
	if logging then
		msg_st.tags[1]:tag("status", {code = "170"}):up();
	else
		msg_st.tags[1]:tag("status", {code = "171"}):up();
	end
	return msg_st;
end
local function config_ojp_method(self, pr_st)
	if config_is_method(self) then pr_st:tag("status", {code = "170"}):up(); end
	return pr_st;
end

local function reload()
	inject_storage_config();
end

function module.load()
	inject_storage_config();

	module:fire_event("muc-config-handler", {
		xmlns = "muc#roomconfig_enablelogging",
		params = {
			name = "logging",
			field = config_field_method,
			is_method = config_is_method,
			set_method = config_set_method,
			check_method = config_check_method,
			ac_method = config_ac_method,
			ojp_method = config_ojp_method
		},
		action = "register",
		caller = "muc_log"
	});
end

function module.unload()
	module:fire_event("muc-config-handler", { xmlns = "muc#roomconfig_enablelogging", caller = "muc_log" });
end			

module:log("debug", "module mod_muc_log loaded!");
