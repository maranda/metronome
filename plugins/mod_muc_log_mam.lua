-- * Metronome IM *
--
-- This file is part of the Metronome XMPP server and is released under the
-- ISC License, please see the LICENSE file in this source package for more
-- information about copyright and licensing.

-- Message Archive Management interface for mod_muc_log

local modulemanager = modulemanager;
if not modulemanager.is_loaded(module.host, "muc") then
	module:log("error", "mod_muc_log_mam can only be loaded on a muc component!");
	modulemanager.unload(module.host, "muc_log_mam");
	return;
end

local ipairs, tonumber, tostring, os_date, os_time = ipairs, tonumber, tostring, os.date, os.time;
local jid_bare = require "util.jid".bare;
local jid_section = require "util.jid".section;
local jid_split = require "util.jid".split;
local datetime = require "util.datetime";
local datamanager = require "util.datamanager";
local st = require "util.stanza";
local data_load = datamanager.load;
local datastore = "muc_log";
local error_reply = require "util.stanza".error_reply;

local muc_object = metronome.hosts[module.host].muc;

local xmlns = "urn:xmpp:mam:2";
local delay_xmlns = "urn:xmpp:delay";
local forward_xmlns = "urn:xmpp:forward:0";

local mamlib = module:require("mam", "mam");
local validate_query = module:require("validate", "mam").validate_query;
local fields_handler, generate_stanzas = mamlib.fields_handler, mamlib.generate_stanzas;

local check_inactivity = module:get_option_number("muc_log_mam_check_inactive", 1800);
local kill_caches_after = module:get_option_number("muc_log_mam_expire_caches", 3600);

local last_caches_clean = os_time();

local function initialize_mam_cache(jid)
	local node, host = jid_split(jid);
	local room = muc_object.rooms[jid];

	if room and not room.mam_cache then
		-- load this last month's discussion.
		room.mam_cache = {};
		local cache = room.mam_cache;
		local yearmonth = os_date("!%Y%m");

		module:log("debug", "Initialize MAM cache for %s", jid);
		for day=1,31 do
			local fday;
			if day < 10 then fday = "0" .. tostring(day); else fday = tostring(day); end 
			local data = data_load(node, host, datastore .. "/" .. yearmonth .. fday);

			if data then
				for n, entry in ipairs(data) do	cache[#cache + 1] = entry; end
			end
		end
	end
end

local function clean_inactive_room_caches(rooms, time_now)
	if time_now - last_caches_clean > check_inactivity then
		module:log("debug", "Checking for inactive rooms MAM caches...");

		for jid, room in pairs(rooms) do
			if time_now - room.last_used > kill_caches_after and room.mam_cache then
				module:log("debug", "Dumping MAM cache for %s", jid);
				room.mam_cache = nil;
			end
		end
		
		last_caches_clean = os_time();
	end
end

function module.unload()
	-- remove all caches when the module is unloaded.
	local rooms = muc_object.rooms;
	for jid, room in pairs(rooms) do room.mam_cache = nil; end
end

module:hook("muc-disco-info-features", function(room, reply)
	reply:tag("feature", { var = xmlns }):up()
end, -100);

module:hook("muc-host-used", clean_inactive_room_caches, -100);

module:hook("muc-log-add-to-mamcache", function(room, entry)
	local cache = room.mam_cache;
	if cache then cache[#cache + 1] = entry; end
end, -100);

module:hook("iq/bare/"..xmlns..":prefs", function(event)
	local origin, stanza = event.origin, event.stanza;
	origin.send(st.error_reply(stanza, "cancel", "feature-not-implemented"));
	return true;
end);

module:hook("iq-get/bare/"..xmlns..":query", fields_handler);
module:hook("iq-set/bare/"..xmlns..":query", function(event)
	local origin, stanza = event.origin, event.stanza;
	local from = stanza.attr.from or origin.full_jid;
	local to = stanza.attr.to;
	local query = stanza.tags[1];
	local qid = query.attr.queryid;
	
	local room = muc_object.rooms[to];
	
	if room._data.logging then
	  -- check that requesting entity has access
	  if (room:get_option("members_only") and not room:is_affiliated(from)) or
	  	room:get_affiliation(from) == "outcast" then
	  		origin.send(st.error_reply(stanza, "auth", "not-authorized"));
	  		return true;
	  end
	
		initialize_mam_cache(to);
		local archive = { logs = room.mam_cache };
	
		local start, fin, with, after, before, max, index, rsm;
		local ok, ret = validate_query(stanza, archive, query, qid);
		if not ok then
			return origin.send(ret);
		else
			start, fin, with, after, before, max, index, rsm =
				ret.start, ret.fin, ret.with, ret.after, ret.before, ret.max, ret.index, ret.rsm;
		end
		
		local messages, rq = generate_stanzas(archive, start, fin, with, max, after, before, index, qid, rsm);
		if not messages then
			module:log("debug", "%s MAM query RSM parameters were out of bounds: After - %s, Before - %s, Max - %s, Index - %s",
				to, tostring(after), tostring(before), tostring(max), tostring(index));
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
	
		module:log("debug", "MAM query %s completed", qid and tostring(qid).." " or "");
	else
		origin.send(st.error_reply(stanza, "cancel", "forbidden", "Room logging needs to be enabled"));
	end
	
	return true;
end);