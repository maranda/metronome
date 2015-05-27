-- * Metronome IM *
--
-- This file is part of the Metronome XMPP server and is released under the
-- ISC License, please see the LICENSE file in this source package for more
-- information about copyright and licensing.

-- MAM Query parsing tools.

local dt_parse = require "util.datetime".parse;
local st = require "util.stanza";
local jid_bare = require "util.jid".bare;
local jid_prep = require "util.jid".prep;
local jid_split = require "util.jid".split;
local ipairs, tonumber, tostring = ipairs, tonumber, tostring;

local xmlns = "urn:xmpp:mam:0";
local df_xmlns = "jabber:x:data";
local rsm_xmlns = "http://jabber.org/protocol/rsm";

local max_results = module:get_option_number("mam_max_retrievable_results", 50);
if max_results >= 100 then max_results = 100; end

local function rsm_parse(stanza, query)
	local rsm = query:get_child("set", rsm_xmlns);
	if not rsm then return nil, nil, nil, false; end
	local max = rsm and rsm:get_child_text("max");
	local after = rsm and rsm:get_child_text("after");
	local before = rsm and rsm:get_child_text("before");
	local index = rsm and rsm:get_child_text("index");
	before = (before == "" and true) or before;
	max = max and tonumber(max);
	index = index and tonumber(index);
	
	return after, before, max, index, true;
end

local function legacy_parse(query)
	local start, fin, with = query:get_child_text("start"), query:get_child_text("end"), query:get_child_text("with");
	return start, fin, with;
end

local function df_parse(query)
	local data = query:get_child("x", df_xmlns);
	if not data then return; end
	local start = data:child_with_attr_value("field", "var", "start");
	local fin = data:child_with_attr_value("field", "var", "end");
	local with = data:child_with_attr_value("field", "var", "with");
	start, fin, with = 
		start and start:get_child_text("value"),
		fin and fin:get_child_text("value"),
		with and with:get_child_text("value");
	return start, fin, with;
end

local function validate_query(stanza, archive, query, qid)
	local start, fin, with;
	if query.attr.xmlns == xmlns then
		start, fin, with = df_parse(query);
	else
		start, fin, with = legacy_parse(query);
	end

	module:log("debug", "MAM query received, %s with %s from %s until %s",
		(qid and "id "..tostring(qid)) or "idless,", with or "anyone", start or "epoch", fin or "now");

	-- Validate attributes
	local vstart, vfin, vwith = (start and dt_parse(start)), (fin and dt_parse(fin)), (with and jid_prep(with));
	if (start and not vstart) or (fin and not vfin) then
		module:log("debug", "Failed to validate timestamp on query, aborting");
		return false, st.error_reply(stanza, "modify", "bad-request", "Supplied timestamp is invalid")
	end
	start, fin = vstart, vfin;
	if with and not vwith then
		module:log("debug", "Failed to validate 'with' JIDs on query, aborting");
		return false, st.error_reply(stanza, "modify", "bad-request", "Supplied JID is invalid");
	end
	with = jid_bare(vwith);
	
	-- Get RSM set
	local after, before, max, index, rsm = rsm_parse(stanza, query);
	if (before and after) or max == "" or after == "" then
		module:log("debug", "MAM Query RSM parameters were invalid: After - %s, Before - %s, Max - %s, Index - %s",
			tostring(after), tostring(before), tostring(max), tostring(index));
		return false, st.error_reply(stanza, "modify", "bad-request");
	elseif before == true and not max then -- Assume max is equal to max_results
		max = max_results;
	end
	
	if max and max > max_results then
		module:log("debug", "MAM Query RSM supplied 'max' results parameter is above the allowed limit (%d)", max_results);
		return false, st.error_reply(stanza, "cancel", "policy-violation", "Max retrievable results' count is "..tostring(max_results));
	end

	if not start and not fin and not before and not max then -- Assume safe defaults
		before, max = true, 30;
	end

	return true, { start = start, fin = fin, with = with, max = max, after = after, before = before, index = index, rsm = rsm };
end

return { validate_query = validate_query };
