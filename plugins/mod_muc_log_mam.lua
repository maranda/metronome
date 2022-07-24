-- * Metronome IM *
--
-- This file is part of the Metronome XMPP server and is released under the
-- ISC License, please see the LICENSE file in this source package for more
-- information about copyright and licensing.

-- Message Archive Management interface for mod_muc_log

if not module:host_is_muc() then
	error("mod_muc_log_mam can only be loaded on a muc component!", 0);
end

local ipairs, ripairs, tonumber, t_remove, tostring, os_date, os_time = 
	ipairs, ripairs, tonumber, table.remove, tostring, os.date, os.time;
local jid_bare = require "util.jid".bare;
local jid_section = require "util.jid".section;
local jid_split = require "util.jid".split;
local datetime = require "util.datetime";
local st = require "util.stanza";
local data_load = require "util.datamanager".load;
local datastore = "muc_log";
local error_reply = require "util.stanza".error_reply;

local host_object = module:get_host_session();

local xmlns = "urn:xmpp:mam:2";
local delay_xmlns = "urn:xmpp:delay";
local forward_xmlns = "urn:xmpp:forward:0";
local markers_xmlns = "urn:xmpp:chat-markers:0";

module:depends("muc_log");

local mamlib = module:require("mam", "mam");
local validate_query = module:require("validate", "mam").validate_query;
local fields_handler, generate_stanzas = mamlib.fields_handler, mamlib.generate_stanzas;

module:hook("muc-disco-info-features", function(room, reply)
	reply:tag("feature", { var = xmlns }):up()
	reply:tag("feature", { var = markers_xmlns }):up()
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
		
		local start, fin, with, after, before, max, index;
		local ok, ret = validate_query(stanza, query, qid);
		if not ok then
			return origin.send(ret);
		else
			start, fin, with, after, before, max, index =
				ret.start, ret.fin, ret.with, ret.after, ret.before, ret.max, ret.index;
		end

		local archive = { 
			logs = module:fire("stanza-log-load", jid_section(to, "node"), module.host, start, fin,	before, after)
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
	else
		origin.send(st.error_reply(stanza, "cancel", "forbidden", "Room logging needs to be enabled"));
	end
	
	return true;
end);