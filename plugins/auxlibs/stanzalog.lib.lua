-- * Metronome IM *
--
-- This file is part of the Metronome XMPP server and is released under the
-- ISC License, please see the LICENSE file in this source package for more
-- information about copyright and licensing.

local uuid = require "util.uuid".generate;
local get_actions = module:require("acdf", "auxlibs").get_actions;
local deserialize = require "util.stanza".deserialize;
local storagemanager = require "core.storagemanager";

local os_date, t_insert, t_sort = os.date, table.insert, table.sort;

local sid_xmlns = "urn:xmpp:sid:0";
local labels_xmlns = "urn:xmpp:sec-label:0";

local store_elements = module:get_option_set("stanza_log_allowed_elements", {});
store_elements:add("acknowledged");
store_elements:add("apply-to");
store_elements:add("displayed");
store_elements:add("encrypted");
store_elements:add("encryption");
store_elements:add("markable");
store_elements:add("mix");
store_elements:add("openpgp");
store_elements:add("securitylabel");
store_elements:add("received");
store_elements:remove("body");
store_elements:remove("html");
store_elements:remove("origin-id");
store_elements:remove("replace");

local function process_stanza(source, stanza, data)
	local oid = stanza:get_child("origin-id", sid_xmlns);
	local body = stanza:child_with_name("body");
	local subject = stanza:child_with_name("subject");
	local id = stanza.attr.id;
	local uid = uuid();

	local data_entry = {
		time = os_date("!%X"),
		timestamp = os.time(),
		from = source,
		resource = stanza.attr.from,
		id = stanza.attr.id,
		oid = oid and oid.attr.id, -- needed for mod_muc_log_mam
		uid = uid,
		type = stanza.attr.type, -- needed for mod_muc_log_mam
		body = body and body:get_text(),
		subject = subject and subject:get_text()
	};
	data[#data + 1] = data_entry;

	-- store elements

	local tags = {};
	local elements = stanza.tags;
	for i = 1, #elements do
		local element = elements[i];
		if store_elements:contains(element.name) or (element.name == "html" and html) then
			if element.name == "securitylabel" and element.attr.xmlns == labels_xmlns then
				local text = element:get_child_text("displaymarking");
				data_entry.label_actions = get_actions(mod_host, text);
				data_entry.label_name = text;
			end
			t_insert(tags, deserialize(element));
		end
	end
	if not next(tags) then
		tags = nil;
	else
		data_entry.tags = tags;
	end

	return data, data_entry;
end

function get_days_in_month(m, y)
  return os_date('*t', os.time{year=y, month=m+1, day=0})['day'];
end

function calculate_set(start, fin)
	local start_m, start_yr = os_date("!%m", start), os_date("!%Y", start);
	local end_m, end_yr = os_date("!%m", fin), os_date("!%Y", fin);
	local year_offset = tonumber(end_yr) - tonumber(start_yr);
	local month_offset = tonumber(end_m) - tonumber(start_m);
	if year_offset < 0 or month_offset < 0 then
		return false; -- not supporting flipped results
	end
	local start_date, end_date = os_date("!%Y%m%d", start), os_date("!%Y%m%d", fin)
	local set = {}
	-- add dates
	local month, day, year, end_d = start_m, os_date("!%d", start), start_yr, os_date("!%d", fin);
	local remaining_days;
	repeat
		remaining_days = get_days_in_month(tonumber(month), tonumber(year)) - tonumber(day);
		set[#set + 1] = tostring(year) .. tostring(month) .. tostring(day);
		day = tonumber(day) + 1;
		if day > get_days_in_month(tonumber(month), tonumber(year)) then day = 1 end
		if day < 10 then day = "0" .. tostring(day); else day = tostring(day); end
		if remaining_days <= 0 then -- switch month
			month = tonumber(month) + 1;
			if month > 12 then month = 1; year = tostring(tonumber(year) + 1); end
			if month < 10 then month = "0" .. tostring(month); else month = tostring(month); end
		end
	until set[#set] >= end_date
	return set;
end

local function load_batch(node, host, archive, start, fin, before, after, metadata, idx)
    local today = os.time();
	if not start then
		start = metadata.first or today - 2630000;
	end
	if not fin then
		fin = metadata.last or today;
	end
	local set = calculate_set(start, fin);
	for k, value in ipairs(set) do
		local data = storagemanager.open(host, "stanza_log" .. "/" .. value):get(node);
		if data then
			for n, entry in ipairs(data) do
				if not idx[entry.uid] then
					archive[#archive + 1] = entry;
					idx[entry.uid] = entry.timestamp;
				end
			end
		end
	end
	t_sort(archive, function(a, b) return a.timestamp < b.timestamp; end);
	if #archive > 0 and (not metadata.first or metadata.first > archive[1].timestamp) then
		metadata.first = archive[1].timestamp;
	end
	if #archive > 0 and (not metadata.last or metadata.last < archive[#archive].timestamp) then
		metadata.last = archive[#archive].timestamp;
	end
	return archive;
end

return {
	process_stanza = process_stanza;
	load_batch = load_batch;
}