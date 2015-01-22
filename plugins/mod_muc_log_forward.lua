-- * Metronome IM *
--
-- This file is part of the Metronome XMPP server and is released under the
-- ISC License, please see the LICENSE file in this source package for more
-- information about copyright and licensing.

-- XEP-297 Interface for mod_muc_log.

local modulemanager = modulemanager;
if not modulemanager.is_loaded(module.host, "muc") then
	module:log("error", "mod_muc_log_forward can only be loaded on a muc component!")
	return;
end

local ipairs, tonumber, tostring, os_date = ipairs, tonumber, tostring, os.date;
local jid_bare = require "util.jid".bare;
local jid_section = require "util.jid".section;
local jid_split = require "util.jid".split;
local datetime = require "util.datetime";
local datamanager = require "util.datamanager";
local st = require "util.stanza";
local data_load, data_getpath = datamanager.load, datamanager.getpath;
local datastore = "muc_log";
local error_reply = require "util.stanza".error_reply;

local muc_object = metronome.hosts[module.host].muc;

local xmlns = "http://metronome.im/protocol/muc-logs-forward";
local delay_xmlns = "urn:xmpp:delay";
local forward_xmlns = "urn:xmpp:forward:0";

module:add_feature(xmlns);

local max_forwarded = module:get_option_number("muc_max_forwarded", 100);
if max_forwarded > 1000 then max_forwarded = 1000; end

local function generate_stanzas(data, date, start, max)
	local stanzas = {};

	for index = start, max do
		local entry = data[index];
		if not entry then break; end

		local i = #stanzas + 1;
		stanzas[i] = st.message()
			:tag("result", { xmlns = xmlns, index = tostring(index) }):up()
			:tag("forwarded", { xmlns = forward_xmlns })
				:tag("delay", {
					xmlns = delay_xmlns,
					stamp = date.."T"..entry.time.."Z" }):up()
				:tag("message", { from = entry.from, id = entry.id });
		if entry.body then stanzas[i]:tag("body"):text(entry.body):up(); end
		if entry.subject then stanzas[i]:tag("subject"):text(entry.subject):up(); end
	end

	return stanzas;
end

module:hook("iq-get/bare/"..xmlns..":query", function(event)
	local origin, stanza = event.origin, event.stanza;
	local to = stanza.attr.to;
	local from = stanza.attr.from;
	local room = muc_object.rooms[to];
	if not room then
		return origin.send(st.error_reply(
			stanza, "cancel", "item-not-found", "Room doesn't exist"
		));
	else
		local query = stanza.tags[1];
		local x_date = query:get_child_text("date");
		local x_entries = query:child_with_name("entries");
		local x_start = query:get_child_text("start");
		local x_max = query:get_child_text("max");
		
		local data, date, start, max, f_date;
		if x_date then
			local y, m, d = x_date:match("^(%d%d%d%d)-(%d%d)-(%d%d)$");
			if not y or not m or not d then
				return origin.send(st.error_reply(
					stanza, "modify", "bad-request", "Date format must be yyyy-mm-dd"
				));
			else
				date, f_date = y..m..d, y.."-"..m.."-"..d;
			end
		else
			date, f_date = os_date("!%Y%m%d"), os_date("!%Y-%m-%d");
		end

		local node, host = jid_split(to);
		data = data_load(node, host, datastore .. "/" .. date);
		if not room:get_option("logging") then
			return origin.send(st.error_reply(
				stanza, "cancel", "service-unavailable", "Logging is not enabled"
			));
		elseif not data then
			return origin.send(st.error_reply(
				stanza, "cancel", "item-not-found", "No logs for the said room"
			));
		end
		
		if x_entries then
			return origin.send(st.reply(stanza):tag("query", { xmlns = xmlns })
				:tag("date"):text(f_date):up()
				:tag("count"):text(tostring(#data)):up()
			);
		end
		
		max = tonumber(x_max) or max_forwarded;
		if max > max_forwarded then max = max_forwarded; end
		start = tonumber(x_start) or (max > #data and 1 or #data - max);
		if start < 1 or tostring(start):match("^%d+%p.*") then
			return origin.send(st.error_reply(
				stanza, "modify", "bad-request", "You need to supply positive integers as indexes"
			));
		elseif start > #data then
			return origin.send(st.error_reply(
				stanza, "modify", "bad-request", "Specified index is too large"
			));
		end

		module:log("debug", "Forwarding log entries for %s to %s", to, from);
		for entry, to_forward in ipairs(generate_stanzas(data, f_date, start, max)) do
			to_forward.attr.to = from;
			to_forward.attr.id = tostring("log_"..entry);
			module:send(to_forward);
		end

		return origin.send(st.reply(stanza):tag("query", { xmlns = xmlns })
			:tag("date"):text(f_date):up()
			:tag("start"):text(tostring(start)):up()
			:tag("max"):text(tostring(max)):up()
		);
	end
end);
