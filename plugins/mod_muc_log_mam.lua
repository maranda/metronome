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

local ipairs, ripairs, tonumber, t_remove, tostring, os_date, os_time = 
	ipairs, ripairs, tonumber, table.remove, tostring, os.date, os.time;
local jid_bare = require "util.jid".bare;
local jid_section = require "util.jid".section;
local jid_split = require "util.jid".split;
local datetime = require "util.datetime";
local datamanager = require "util.datamanager";
local st = require "util.stanza";
local data_load = datamanager.load;
local datastore = "muc_log";
local error_reply = require "util.stanza".error_reply;

local host_object = hosts[module.host];

local xmlns = "urn:xmpp:mam:2";
local delay_xmlns = "urn:xmpp:delay";
local forward_xmlns = "urn:xmpp:forward:0";

local mamlib = module:require("mam", "mam");
local validate_query = module:require("validate", "mam").validate_query;
local fields_handler, generate_stanzas = mamlib.fields_handler, mamlib.generate_stanzas;

local check_inactivity = module:get_option_number("muc_log_mam_check_inactive", 1800);
local kill_caches_after = module:get_option_number("muc_log_mam_expire_caches", 3600);

local mam_cache = {};

module:add_timer(check_inactivity, function()
	module:log("debug", "Checking for inactive rooms MAM caches...");

	for jid, room in pairs(host_object.muc.rooms) do
		if os_time() - room.last_used > kill_caches_after and mam_cache[jid] then
			module:log("debug", "Dumping MAM cache for %s", jid);
			mam_cache[jid] = nil;
		end
	end

	return check_inactivity;
end);

local function initialize_mam_cache(jid)
	local node, host = jid_split(jid);
	local room = host_object.muc.rooms[jid];

	if room and not mam_cache[jid] then
		-- load this last month's discussion.
		mam_cache[jid] = {};
		local cache = mam_cache[jid];
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

module:hook("muc-disco-info-features", function(room, reply)
	reply:tag("feature", { var = xmlns }):up()
end, -100);

module:hook("muc-log-add-to-mamcache", function(room, entry)
	local cache = mam_cache[room.jid];
	if cache then cache[#cache + 1] = entry; end
end, -100);

module:hook("muc-log-get-mamcache", function(jid)
	return mam_cache[jid];
end);

module:hook("muc-log-remove-from-mamcache", function(room, from, rid)
	local cache = mam_cache[room.jid];
	if cache then
		local count = 0;
		for i, entry in ripairs(cache) do
			count = count + 1;
			if count < 100 and entry.resource == from and entry.id == rid then
				t_remove(cache, i); break;
			end
		end
	end
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
	
	local room = host_object.muc.rooms[to];
	
	if room._data.logging then
		-- check that requesting entity has access
		if (room:get_option("members_only") and not room:is_affiliated(from)) or
	  		room:get_affiliation(from) == "outcast" then
			origin.send(st.error_reply(stanza, "auth", "not-authorized"));
			return true;
		end
	
		initialize_mam_cache(to);
		local archive = { logs = mam_cache[to] };
	
		local start, fin, with, after, before, max, index;
		local ok, ret = validate_query(stanza, query, qid);
		if not ok then
			return origin.send(ret);
		else
			start, fin, with, after, before, max, index =
				ret.start, ret.fin, ret.with, ret.after, ret.before, ret.max, ret.index;
		end
		
		local messages, rq, count = generate_stanzas(archive, start, fin, with, max, after, before, index, qid);
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
	else
		origin.send(st.error_reply(stanza, "cancel", "forbidden", "Room logging needs to be enabled"));
	end
	
	return true;
end);