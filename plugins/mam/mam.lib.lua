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
local load_roster = require "util.rostermanager".load_roster;
local check_policy = module:require("acdf_aux").check_policy;

local ipairs, next, now, pairs, ripairs, t_insert, t_remove, tostring, type, unpack = 
	ipairs, next, os.time, pairs, ripairs, table.insert, table.remove, tostring, type, unpack or table.unpack;
    
local xmlns = "urn:xmpp:mam:2";
local delay_xmlns = "urn:xmpp:delay";
local e2e_xmlns = "http://www.xmpp.org/extensions/xep-0200.html#ns";
local forward_xmlns = "urn:xmpp:forward:0";
local hints_xmlns = "urn:xmpp:hints";
local labels_xmlns = "urn:xmpp:sec-label:0";
local lmc_xmlns = "urn:xmpp:message-correct:0";
local rsm_xmlns = "http://jabber.org/protocol/rsm";
local markers_xmlns = "urn:xmpp:chat-markers:0";
local sid_xmlns = "urn:xmpp:sid:0";

local store_time = module:get_option_number("mam_save_time", 300);
local stores_cap = module:get_option_number("mam_stores_cap", 10000);
local max_length = module:get_option_number("mam_message_max_length", 3000);
local store_elements = module:get_option_set("mam_allowed_elements");
local unload_cache_time = module:get_option_number("mam_unload_cache_time", 3600);

local session_stores = {};
local offline_stores = {};
local to_save = now();
local storage;

local valid_markers = {
	markable = "markable", received = "received",
	displayed = "displayed", acknowledged = "acknowledged"
};
if store_elements then
	store_elements:remove("acknowledged");
	store_elements:remove("body");
	store_elements:remove("displayed");
	store_elements:remove("markable");
	store_elements:remove("origin-id");
	store_elements:remove("received");
	store_elements:remove("securitylabel");
	if store_elements:empty() then store_elements = nil; end
end

local _M = {};

local function initialize_storage()
	storage = storagemanager.open(module_host, "archiving");
	return storage;
end

local function initialize_session_store(user)
	local bare_jid = jid_join(user, module_host);
	local bare_session = bare_sessions[bare_jid];
	if offline_stores[bare_jid] then
		session_stores[bare_jid] = offline_stores[bare_jid];
		bare_session.archiving = session_stores[bare_jid];
		offline_stores[bare_jid] = nil;
	end
	if not bare_session.archiving then
		session_stores[bare_jid] = storage:get(user) or { logs = {}, prefs = { default = "never" } };
		bare_session.archiving = session_stores[bare_jid];
	end
	session_stores[bare_jid].last_used = now();
	module:add_timer(60, function()
		if session_stores[bare_jid] then
			local store = session_stores[bare_jid];
			if now() - store.last_used > unload_cache_time then
				module:log("debug", "Removing %s archive cache due to inactivity", bare_jid);
				if store.changed then
					store.changed, store.last_used = nil, nil;
					storage:set(user, store);
				end
				bare_sessions[bare_jid].archiving = nil;
				session_stores[bare_jid] = nil;
			else
				return 60;
			end
		end
	end);
end

local function save_stores()
	to_save = now();
	for bare, store in pairs(session_stores) do
		local user = jid_section(bare, "node");
		local last_used = store.last_used;
		if store.changed then
			store.changed, store.last_used = nil, nil;
			storage:set(user, store);
		end
		store.last_used = last_used;
	end	
end

local function make_placemarker(entry)
	entry.body = nil;
	entry.marker = nil;
	entry.marker_id = nil;
	entry.oid = nil;
	entry.tags = nil;
end

local function log_entry(session_archive, to, bare_to, from, bare_from, id, type, body, marker, marker_id, oid, tags)
	local uid = uuid();
	local entry = {
		from = from,
		bare_from = bare_from,
		to = to,
		bare_to = bare_to,
		id = id,
		type = type,
		body = body,
		marker = marker,
		marker_id = marker_id,
		timestamp = now(),
		oid = oid,
		uid = uid
	};
	if tags then
		for i, stanza in ipairs(tags) do
			if stanza.name == "securitylabel" and stanza.attr.xmlns == labels_xmlns then
				local text = stanza:get_child_text("displaymarking");
				entry.label_name = text;
			end
			tags[i] = st.deserialize(stanza);
		end
		entry.tags = tags;
	end

	local logs = session_archive.logs;
	
	while #logs >= stores_cap do t_remove(logs, 1); end
	logs[#logs + 1] = entry;
	session_archive.changed = true;

	if now() - to_save > store_time then save_stores(); end
	return uid;
end

local function log_entry_with_replace(session_archive, to, bare_to, from, bare_from, id, rid, type, body, marker, marker_id, oid, tags)
	-- handle XEP-308 or try to...
	local count = 0;
	local logs = session_archive.logs;
	
	if rid and rid ~= id then
		for i, entry in ripairs(logs) do
			count = count + 1;
			if count < 1000 and entry.to == to and entry.from == from and entry.id == rid then 
				make_placemarker(entry); break;
			end
		end
	end
	
	return log_entry(session_archive, to, bare_to, from, bare_from, id, type, body, marker, marker_id, oid, tags);
end

local function log_marker(session_archive, to, bare_to, from, bare_from, id, type, marker, marker_id, oid, tags)
	local count = 0;

	for i, entry in ripairs(session_archive.logs) do
		count = count + 1;
		local entry_marker, entry_from, entry_to = entry.marker, entry.bare_from, entry.bare_to;

		if count < 1000 and entry.id == marker_id and
		   (entry_from == bare_from or entry_from == bare_to) and
		   (entry_to == bare_to or entry_to == bare_from) and
		   (entry_marker == "markable" or entry_marker == "received") and
		   entry_marker ~= marker then
			return log_entry(session_archive, to, bare_to, from, bare_from, id, type, nil, marker, marker_id, oid, tags);
		end
	end
end

local function append_stanzas(stanzas, entry, qid, check_acdf)
	local label = entry.label_name;
	if check_acdf and label then
		local session, request = unpack(check_acdf);
		local jid = session.full_jid or request.attr.from;
		if check_policy(label, jid, { attr = { from = entry.from, resource = entry.resource } }, request) then
			return false;
		end
	end

	local to_forward = st.message()
		:tag("result", { xmlns = xmlns, queryid = qid, id = entry.uid })
			:tag("forwarded", { xmlns = forward_xmlns })
				:tag("delay", { xmlns = delay_xmlns, stamp = dt(entry.timestamp) }):up()
				:tag("message", { to = entry.to, from = entry.from, id = entry.id, type = entry.type });

	if entry.body then to_forward:tag("body"):text(entry.body):up(); end
	if entry.tags then
		for i = 1, #entry.tags do to_forward:add_child(st.preserialize(entry.tags[i])); end
	end
	if entry.marker then to_forward:tag(entry.marker, { xmlns = markers_xmlns, id = entry.marker_id }):up(); end
	if entry.oid then to_forward:tag("origin-id", { xmlns = sid_xmlns, id = entry.oid }):up(); end
	
	stanzas[#stanzas + 1] = to_forward;
	return true;
end

local function generate_set(stanza, first, last, count, index)
	stanza:tag("set", { xmlns = rsm_xmlns });
	if first then stanza:tag("first", { index = index }):text(first):up(); end
	if last then stanza:tag("last"):text(last):up(); end
	stanza:tag("count"):text(tostring(count)):up();
end

local function generate_fin(stanzas, first, last, count, index, complete)
	local fin = st.stanza("fin", { xmlns = xmlns, complete = complete and "true" or nil });
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

local function generate_stanzas(store, start, fin, with, max, after, before, index, qid, check_acdf)
	local logs = store.logs;
	local stanzas = {};
	local query;
	
	local at = 1;
	local first, last, entries_count, count, complete;
	local entry_index, to_process;

	if with or start or fin then
		entries_count = count_relevant_entries(logs, with, start, fin);
	else
		entries_count = #logs;
	end
	
	if max == 0 then
		query = generate_fin(stanzas, first, last, entries_count, count, true);
		return stanzas, query, #stanzas;
	-- handle paging
	elseif index then
		for i, entry in ipairs(logs) do
			local timestamp = entry.timestamp;
			local uid = entry.uid
			if not dont_add(entry, with, start, fin, timestamp) and i - 1 > index then
				local add = append_stanzas(stanzas, entry, qid, check_acdf);
				if add then
					if at == 1 then first = uid; end
					at = at + 1;
					last = uid;
				end
			end
			if at ~= 1 and at > max then break; end
		end
		if #stanzas == 0 then return nil; end
		complete = logs[#logs].uid == last;

		query = generate_fin(stanzas, first, last, entries_count, index, complete);
		return stanzas, query, #stanzas;
	elseif before then
		if before == true then
			to_process = {};
			-- we clone the table from the end backward count
			local total = #logs;
			for i = (max > total and 1) or 1 + total - max, total do to_process[#to_process + 1] = logs[i]; end
		else
			entry_index = get_index(logs, before);
			if not entry_index then return nil; else entry_index = entry_index - 1; end
			to_process = {};
			local sub = 1 + entry_index - max;
			-- we clone the table upto index
			for i = (sub < 0 and 1) or sub, entry_index do to_process[#to_process + 1] = logs[i]; end
		end
		if #to_process == 0 then
			return stanzas, generate_fin(stanzas, first, last, entries_count, count, true), #stanzas;
		end

		for i, entry in ipairs(to_process) do
			local timestamp = entry.timestamp;
			local uid = entry.uid;
			if not dont_add(entry, with, start, fin, timestamp) then
				local add = append_stanzas(stanzas, entry, qid, check_acdf);
				if add then
					if at == 1 then first = uid; end
					at = at + 1;
					last = uid;
				end
			end
			if at ~= 1 and at > max then break; end
		end

		count = (type(before) == "string" and entry_index - max) or entries_count - 1 - max;
		query = generate_fin(stanzas, first, last, entries_count, count < 0 and 0 or count, before == true or count < 1);
		return stanzas, query, #stanzas;
	elseif after then
		entry_index = get_index(logs, after);
		if not entry_index then return nil; else entry_index = entry_index + 1; end
		to_process = {};
		-- we clone table from index
		for i = entry_index, #logs do to_process[#to_process + 1] = logs[i]; end
		if #to_process == 0 then
			return stanzas, generate_fin(stanzas, first, last, entries_count, count, true), #stanzas;
		end
	end
	
	for i, entry in ipairs(to_process or logs) do
		local timestamp = entry.timestamp;
		local uid = entry.uid;
		if not dont_add(entry, with, start, fin, timestamp) then
			local add = append_stanzas(stanzas, entry, qid, check_acdf);
			if add then
				if at == 1 then first = uid; end
				at = at + 1;
				last = uid;
			end
		end
		if at ~= 1 and at > max then break; end
	end
	if #logs ~= 0 then
		complete = (to_process or logs)[to_process and #to_process or #logs].uid == last;
	else
		complete = true;
	end
	
	count = after and entry_index - 1 or 0;
	query = generate_fin(stanzas, first, last, entries_count, count, complete);
	return stanzas, query, #stanzas;
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

local function fields_handler(event)
	local origin, stanza = event.origin, event.stanza;
	return origin.send(
		st.reply(stanza)
			:tag("query", { xmlns = xmlns })
				:tag("x", { xmlns = "jabber:x:data" })
					:tag("field", { type = "hidden", var = "FORM_TYPE" })
						:tag("value"):text(xmlns):up():up()
					:tag("field", { type = "jid-single", var = "with" }):up()
					:tag("field", { type = "text", var = "start" }):up()
					:tag("field", { type = "text", var = "end" }):up()
	);
end

local function process_message(event, outbound)
	local message, origin = event.stanza, event.origin;
	if message.attr.type ~= "chat" and message.attr.type ~= "normal" then return; end
	local body = message:child_with_name("body");
	local marker = message:child_with_ns(markers_xmlns);
	local marker_id = marker and marker.attr.id;
	local markable;
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
		if marker then 
			marker = valid_markers[marker.name];
			if marker == "markable" then markable = true; end
		end
	end
	
	local from, to = (message.attr.from or origin.full_jid), message.attr.to;
	local bare_from, bare_to = jid_bare(from), jid_bare(to);
	local archive, loaded, user;
	
	if outbound then
		user = jid_section(from, "node");
		local bare_session = bare_sessions[bare_from];
		if bare_session and not session_stores[bare_from] then initialize_session_store(user); loaded = true; end
		archive = session_stores[bare_from];
	else
		user = jid_section(to, "node");
		local bare_session = bare_sessions[bare_to];
		if bare_session and not session_stores[bare_to] then initialize_session_store(user); loaded = true; end
		archive = session_stores[bare_to];
	end
	
	if not archive and not outbound then -- assume it's an offline message
		local offline_overcap = module:fire_event("message/offline/overcap", { node = user });
		if not offline_overcap then
			if not offline_stores[bare_to] then
				archive = storage:get(user);
				if archive then
					offline_stores[bare_to] = archive;
					module:add_timer(300, function()
						if offline_stores[bare_to] then
							local store = offline_stores[bare_to];
							if store.changed then
								store.changed, store.last_used = nil, nil;
								storage:set(user, store);
							end
							offline_stores[bare_to] = nil;
						end
					end);
				end
			else
				archive = offline_stores[bare_to];
			end
		end
	end

	if archive and add_to_store(archive, user, outbound and bare_to or bare_from) then
		local label = message:get_child("securitylabel", labels_xmlns);
		local replace = message:get_child("replace", lmc_xmlns);
		local oid = message:get_child("origin-id", sid_xmlns);
		local id, tags;

		if store_elements then
			tags = {};
			local elements = message.tags;
			for i = 1, #elements do
				if store_elements:contains(elements[i].name) then tags[#tags + 1] = elements[i]; end
			end
			if not next(tags) then tags = nil; end
		end

		if label then
			if not tags then tags = {}; end
			t_insert(tags, label);
		end

		if replace and body then
			id = log_entry_with_replace(
				archive, to, bare_to, from, bare_from, message.attr.id, replace.attr.id, message.attr.type, body,
				markable and marker or nil, markable and marker_id or nil, oid and oid.attr.id, tags
			);
		else
			if body then
				id = log_entry(
					archive, to, bare_to, from, bare_from, message.attr.id, message.attr.type, body,
					markable and marker or nil, markable and marker_id or nil, oid and oid.attr.id, tags
				);
			elseif marker and not markable then
				id = log_marker(
					archive, to, bare_to, from, bare_from, message.attr.id, message.attr.type, marker, marker_id,
					oid and oid.attr.id, tags
				);
			end
		end

		if not loaded then archive.last_used = now(); end
		if (not outbound or not to or to == bare_from) and id then message:tag("stanza-id", { xmlns = sid_xmlns, by = bare_to, id = id }):up(); end
	else
		return;
	end	
end

local function pop_entry(logs, i, jid)
	local entry = logs[i];
	if jid then
		if (entry.bare_from == jid) or (entry.bare_to == jid) then make_placemarker(entry); end
	else
		make_placemarker(entry);
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
			if entry.uid == id then make_placemarker(entry); break; end
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
_M.initialize_session_store = initialize_session_store;
_M.save_stores = save_stores;
_M.get_prefs = get_prefs;
_M.set_prefs = set_prefs;
_M.fields_handler = fields_handler;
_M.generate_stanzas = generate_stanzas;
_M.process_message = process_message;
_M.purge_messages = purge_messages;
_M.session_stores = session_stores;

return _M;
