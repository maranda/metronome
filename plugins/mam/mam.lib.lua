-- * Metronome IM *
--
-- This file is part of the Metronome XMPP server and is released under the
-- ISC License, please see the LICENSE file in this source package for more
-- information about copyright and licensing.

-- MAM Module Library

local module_host = module.host;
local dt = require "util.datetime".datetime;
local jid_bare = require "util.jid".bare;
local jid_join = require "util.jid".join;
local jid_section = require "util.jid".section;
local st = require "util.stanza";
local uuid = require "util.uuid".generate;
local storagemanager = storagemanager;
local load_roster = require "util.rostermanager".load_roster;
local ipairs, next, now, pairs, ripairs, select, t_remove, tostring = ipairs, next, os.time, pairs, ripairs, select, table.remove, tostring;
      
local xmlns = "urn:xmpp:mam:0";
local legacy_xmlns = "urn:xmpp:mam:tmp";
local delay_xmlns = "urn:xmpp:delay";
local e2e_xmlns = "http://www.xmpp.org/extensions/xep-0200.html#ns";
local forward_xmlns = "urn:xmpp:forward:0";
local hints_xmlns = "urn:xmpp:hints";
local rsm_xmlns = "http://jabber.org/protocol/rsm";
local markers_xmlns = "urn:xmpp:chat-markers:0";

local store_time = module:get_option_number("mam_save_time", 300);
local stores_cap = module:get_option_number("mam_stores_cap", 5000);
local max_length = module:get_option_number("mam_message_max_length", 3000);
local store_elements = module:get_option_set("mam_allowed_elements");

local session_stores = {};
local storage = {};
local to_save = now();

local valid_markers = {
	markable = "markable", received = "received",
	displayed = "displayed", acknowledged = "acknowledged"
};
if store_elements then
	store_elements:remove("acknowledged");
	store_elements:remove("body");
	store_elements:remove("displayed");
	store_elements:remove("markable");
	store_elements:remove("received");
	if store_elements:empty() then store_elements = nil; end
end

local _M = {};

local function initialize_storage()
	storage = storagemanager.open(module_host, "archiving");
	return storage;
end

local function save_stores()
	to_save = now();
	for bare, store in pairs(session_stores) do
		local user = jid_section(bare, "node");
		if store.changed then
			store.changed = nil;
			storage:set(user, store);
		end
	end	
end

local function log_entry(session_archive, to, bare_to, from, bare_from, id, body, marker, marker_id, tags)
	local uid = uuid();
	local entry = {
		from = from,
		bare_from = bare_from,
		to = to,
		bare_to = bare_to,
		id = id,
		body = body,
		marker = marker,
		marker_id = marker_id,
		timestamp = now(),
		uid = uid
	};
	if tags then
		for i, stanza in ipairs(tags) do tags[i] = st.deserialize(stanza); end
		entry.tags = tags;
	end

	local logs = session_archive.logs;
	
	while #logs >= stores_cap do t_remove(logs, 1); end
	logs[#logs + 1] = entry;
	session_archive.changed = true;

	if now() - to_save > store_time then save_stores(); end
	return uid;
end

local function log_entry_with_replace(session_archive, to, bare_to, from, bare_from, id, rid, body)
	-- handle XEP-308 or try to...
	local count = 0;
	local logs = session_archive.logs;
	
	if rid and rid ~= id then
		for i, entry in ripairs(logs) do
			count = count + 1;
			if count < 1000 and entry.to == to and entry.from == from and entry.id == rid then 
				t_remove(logs, i); break;
			end
		end
	end
	
	return log_entry(session_archive, to, bare_to, from, bare_from, id, body);
end

local function log_marker(session_archive, to, bare_to, from, bare_from, id, marker, marker_id)
	local count = 0;

	for i, entry in ripairs(session_archive.logs) do
		count = count + 1;
		local entry_marker, entry_from, entry_to = entry.marker, entry.bare_from, entry.bare_to;

		if count < 1000 and entry.id == marker_id and
		   (entry_from == bare_from or entry_from == bare_to) and
		   (entry_to == bare_to or entry_to == bare_from) and
		   (entry_marker == "markable" or entry_marker == "received") and
		   entry_marker ~= marker then
			return log_entry(session_archive, to, bare_to, from, bare_from, id, nil, marker, marker_id);
		end
	end
end

local function append_stanzas(stanzas, entry, qid, legacy)
	local to_forward = st.message()
		:tag("result", { xmlns = legacy and legacy_xmlns or xmlns, queryid = qid, id = entry.id })
			:tag("forwarded", { xmlns = forward_xmlns })
				:tag("delay", { xmlns = delay_xmlns, stamp = dt(entry.timestamp) }):up()
				:tag("message", { to = entry.to, from = entry.from, id = entry.id });

	if entry.body then to_forward:tag("body"):text(entry.body):up(); end
	if entry.tags then
		for i = 1, #entry.tags do to_forward:add_child(st.preserialize(entry.tags[i])):up(); end
	end
	if entry.marker then to_forward:tag(entry.marker, { xmlns = markers_xmlns, id = entry.marker_id }):up(); end
	
	stanzas[#stanzas + 1] = to_forward;
end

local function generate_set(stanza, first, last, count, index)
	stanza:tag("set", { xmlns = rsm_xmlns })
		:tag("first", { index = index or 0 }):text(first):up()
		:tag("last"):text(last or first):up()
		:tag("count"):text(tostring(count)):up();
end

local function generate_query(stanzas, start, fin, set, first, last, count, index)
	local query = st.stanza("query", { xmlns = legacy_xmlns });
	if start then query:tag("start"):text(dt(start)):up(); end
	if fin then query:tag("end"):text(dt(fin)):up(); end
	if set and #stanzas ~= 0 then generate_set(query, first, last, count); end
	
	return (((start or fin) or (set and #stanzas ~= 0)) and query) or nil;
end

local function generate_fin(stanzas, first, last, count, index, complete)
	local fin = st.stanza("fin", { xmlns = xmlns, complete = (complete or count == 0) and "true" or nil });
	generate_set(fin, first, last, count, index);

	return fin;
end

local function dont_add(entry, with, start, fin, timestamp)
	if with and not (entry.bare_from == with or entry.bare_to == with) then
		return true;
	elseif (start and not fin) and not (timestamp >= start) then
		return true;
	elseif (fin and not start) and not (timestamp <= fin) then
		return true;
	elseif (start and fin) and not (timestamp >= start and timestamp <= fin) then
		return true;
	end
	
	return false;
end

local function get_index(logs, index)
	for i, entry in ipairs(logs) do 
		if entry.uid == index then return i; end
	end
end

local function remove_upto_index(logs, index)
	if index > #logs then
		logs = {};
	else
		for i = 1, #logs do
			if i ~= index then t_remove(logs, i); else break; end
		end
	end
	return logs;
end

local function count_relevant_entries(logs, with, start, fin)
	local count = 0;
	for i, e in ipairs(logs) do
		local timestamp = e.timestamp;
		if with and (start or fin) then
			local bare_from, bare_to = e.bare_from, e.bare_to;
			if (bare_from == with or bare_to == with) and (start and not fin) and (timestamp >= start) then
				count = count + 1;
			elseif (bare_from == with or bare_to == with) and (fin and not start) and (timestamp <= fin) then
				count = count + 1;
			elseif (bare_from == with or bare_to == with) and (start and fin) and 
				(timestamp >= start and timestamp <= fin) then
				count = count + 1;
			end
		elseif (start or fin) then
			if (start and not fin) and (timestamp >= start) then
				count = count + 1;
			elseif (fin and not start) and (timestamp <= fin) then
				count = count + 1;
			elseif (start and fin) and (timestamp >= start and timestamp <= fin) then
				count = count + 1;
			end
		else
			count = count + 1;
		end
	end
	
	return count;
end

local function generate_stanzas(store, start, fin, with, max, after, before, index, qid, rsm, legacy)
	local logs = store.logs;
	local stanzas = {};
	local query;
	
	local _at = 1;
	local first, last, _after, _start, _end, _entries_count, _count;
	local entry_index, to_process;
	
	-- handle paging
	if before then
		if before == true then
			to_process = {};
			local _logs_with;
			if with then
				_logs_with = {};
				for i, e in ipairs(logs) do
					if e.bare_to == with or e.bare_from == with then
						_logs_with[#_logs_with + 1] = e;
					end
				end
			end
						
			-- we clone the table from the end backward count
			local total = (_logs_with and #_logs_with) or #logs;
			local _logs = (_logs_with and _logs_with) or logs;
			for i = (max > total and 1) or total - max, total do to_process[#to_process + 1] = _logs[i]; end
			_entries_count = total;
		else
			entry_index = get_index(logs, before);
			if not entry_index then return nil; end
			to_process = {};
			local sub = (max and entry_index - max) or 1;
			-- we clone the table upto index
			for i = (sub < 0 and 1) or sub, entry_index do to_process[#to_process + 1] = logs[i]; end
			_entries_count = count_relevant_entries(to_process, with, start, fin);
		end

		for i, entry in ipairs(to_process) do
			local timestamp = entry.timestamp;
			local uid = entry.uid
			if not dont_add(entry, with, start, fin, timestamp) then
				append_stanzas(stanzas, entry, qid, legacy);
			end
		end
		if index then
			stanzas = remove_upto_index(stanzas, index);
			if #stanzas == 0 then return nil; end
		end
		if #stanzas ~= 0 then
			local first_e, last_e = to_process[1], to_process[#to_process];
			first, last = first_e.uid, last_e.uid;
			_start, _end = first_e.timestamp, last_e.timestamp;
		end

		_count = max and _entries_count - max or 0;
		query = legacy and
			generate_query(stanzas, (start or _start), (fin or _end), rsm, first, last, (_count < 0 and 0) or _count, index) or
			generate_fin(stanzas, first, last, (_count < 0 and 0) or _count, index, before == true);
		return stanzas, query;
	elseif after then
		entry_index = get_index(logs, after);
		if not entry_index then return nil; end
		to_process = {};
		-- we clone table from index
		for i = entry_index + 1, #logs do to_process[#to_process + 1] = logs[i]; end
	end
	
	_entries_count = count_relevant_entries(to_process or logs, with, start, fin);

	for i, entry in ipairs(to_process or logs) do
		local timestamp = entry.timestamp;
		local uid = entry.uid;
		if not dont_add(entry, with, start, fin, timestamp) then
			append_stanzas(stanzas, entry, qid, legacy);
			if max then
				if _at == 1 then 
					first = uid;
					_start = timestamp;
				elseif _at == max then
					last = uid;
					_end = timestamp;
				end
				_at = _at + 1;
			end
		end
		if max and _at ~= 1 and _at > max then break; end
	end
	if index then
		stanzas = remove_upto_index(stanzas, index);
		if #stanzas == 0 then return nil; end
	end
	if not max and #stanzas > 30 then return false; end
	
	_count = max and _entries_count - max or 0;
	query = legacy and
		generate_query(stanzas, (start or _start), (fin or _end), rsm, first, last, (_count < 0 and 0) or _count, index) or
		generate_fin(stanzas, first, last, (_count < 0 and 0) or _count, index);
	return stanzas, query;
end

local function add_to_store(store, user, recipient)
	local prefs = store.prefs
	if prefs[recipient] and recipient ~= "default" then
		return true;
	else
		if prefs.default == "always" then 
			return true;
		elseif prefs.default == "roster" then
			local roster = load_roster(user, module_host);
			if roster[recipient] then return true; end
		end
		
		return false;
	end
end

local function get_prefs(store)
	local _prefs = store.prefs;

	local stanza = st.stanza("prefs", { xmlns = xmlns, default = _prefs.default or "never" });
	local always = st.stanza("always");
	local never = st.stanza("never");
	for jid, choice in pairs(_prefs) do
		if jid and jid ~= "default" then
			(choice and always or never):tag("jid"):text(jid):up();
		end
	end

	stanza:add_child(always):add_child(never);
	return stanza;
end

local function set_prefs(stanza, store)
	local _prefs = store.prefs;
	local prefs = stanza:child_with_name("prefs");
	
	local default = prefs.attr.default;
	if default and default ~= "always" and default ~= "never" and default ~= "roster" then
		return st.error_reply(stanza, "modify", "bad-request", "Default can be either: always, never or roster");
	end
	
	if default then _prefs.default = default; end

	local always = prefs:get_child("always");
	if always then
		for jid in always:childtags("jid") do _prefs[jid:get_text()] = true; end
	end

	local never = prefs:get_child("never");
	if never then
		for jid in never:childtags("jid") do _prefs[jid:get_text()] = false; end
	end
	
	store.changed = true;
	local reply = st.reply(stanza);
	reply:add_child(get_prefs(store));

	return reply;
end

local function process_message(event, outbound)
	local message, origin = event.stanza, event.origin;
	if message.attr.type ~= "chat" and message.attr.type ~= "normal" then return; end
	local body = message:child_with_name("body");
	local marker = message:child_with_ns(markers_xmlns);
	local marker_id = marker and marker.attr.id;
	if not body and not marker then
		return; 
	else
		if message:get_child("no-store", hints_xmlns) or message:get_child("no-permanent-storage", hints_xmlns) then
			return;
		end
		if body then
			body = body:get_text() or "";
			if body:len() > max_length then return; end
			-- COMPAT, Drop OTR/E2E messages for clients not implementing XEP-334
			if message:get_child("c", e2e_xmlns) or body:match("^%?OTR%:[^%s]*%.$") then return; end
		end
		if marker then marker = valid_markers[marker.name]; end
	end
	
	local from, to = (message.attr.from or origin.full_jid), message.attr.to;
	local bare_from, bare_to = jid_bare(from), jid_bare(to);
	local bare_session, user;
	
	if outbound then
		bare_session = bare_sessions[bare_from];
		user = jid_section(from, "node");
	else
		bare_session = bare_sessions[bare_to];
		user = jid_section(to, "node");
	end
	
	local archive = bare_session and bare_session.archiving;
	
	if not archive and not outbound then -- assume it's an offline message
		local offline_overcap = module:fire_event("message/offline/overcap", { node = user });
		if not offline_overcap then archive = storage:get(user); end
	end

	if archive and add_to_store(archive, user, outbound and bare_to or bare_from) then
		local replace = message:get_child("replace", "urn:xmpp:message-correct:0");
		local id, tags;

		if store_elements then
			tags = {};
			local elements = message.tags;
			for i = 1, #elements do
				if store_elements:contains(elements[i].name) then tags[#tags + 1] = elements[i]; end
			end
			if not next(tags) then tags = nil; end
		end

		if replace then
			id = log_entry_with_replace(archive, to, bare_to, from, bare_from, message.attr.id, replace.attr.id, body);
		else
			if body then
				id = marker == "markable" and log_entry(
					archive, to, bare_to, from, bare_from, message.attr.id, body,
					marker, marker_id, tags
				) or log_entry(archive, to, bare_to, from, bare_from, message.attr.id, body, nil, nil, tags);
			elseif marker and marker ~= "markable" then
				id = log_marker(archive, to, bare_to, from, bare_from, message.attr.id, marker, marker_id);
			end
		end

		if not bare_session then storage:set(user, archive); end
		if not outbound and id then message:tag("archived", { jid = bare_to, id = id }):up(); end
	else
		return;
	end	
end

local function pop_entry(logs, i, jid)
	if jid then
		local entry = logs[i];
		if (entry.bare_from == jid) or (entry.bare_to == jid) then t_remove(logs, i); end
	else
		t_remove(logs, i);
	end
end

local function purge_messages(archive, id, jid, start, fin)
	if not id and not jid and not start and not fin then
		archive.logs = {};
		return;
	end
	
	local logs = archive.logs;
	if id then
		for i, entry in ipairs(logs) do
			if entry.uid == id then t_remove(logs, i); break; end
		end
	elseif jid or start or fin then
		for i, entry in ipairs(logs) do
			local timestamp = entry.timestamp;
			if (start and not fin) and timestamp >= start then
				pop_entry(logs, i, jid);
			elseif (not start and fin) and timestamp <= fin then
				pop_entry(logs, i, jid);
			elseif (start and fin) and (timestamp >= start and timestamp <= fin) then
				pop_entry(logs, i, jid);
			end
		end
	end
end

_M.initialize_storage = initialize_storage;
_M.save_stores = save_stores;
_M.get_prefs = get_prefs;
_M.set_prefs = set_prefs;
_M.generate_stanzas = generate_stanzas;
_M.process_message = process_message;
_M.purge_messages = purge_messages;
_M.session_stores = session_stores;

return _M;
