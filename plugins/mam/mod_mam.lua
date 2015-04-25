-- * Metronome IM *
--
-- This file is part of the Metronome XMPP server and is released under the
-- ISC License, please see the LICENSE file in this source package for more
-- information about copyright and licensing.

-- Message Archiving Management for Metronome,
-- This implements XEP-313.

local bare_sessions = metronome.bare_sessions;
local module_host = module.host;

local dt_parse = require "util.datetime".parse;
local st = require "util.stanza";
local jid_bare = require "util.jid".bare;
local jid_join = require "util.jid".join;
local jid_prep = require "util.jid".prep;
local jid_section = require "util.jid".section;
local jid_split = require "util.jid".split;
local ipairs, tonumber, tostring = ipairs, tonumber, tostring;

local xmlns = "urn:xmpp:mam:0";
local legacy_xmlns = "urn:xmpp:mam:tmp";
local purge_xmlns = "http://metronome.im/protocol/mam-purge";
local rsm_xmlns = "http://jabber.org/protocol/rsm";

module:add_feature(xmlns);
module:add_feature(legacy_xmlns);
module:add_feature(purge_xmlns);

local forbid_purge = module:get_option_boolean("mam_forbid_purge", false);

local mamlib = module:require("mam");
local validate_query = module:require("validate").validate_query;
local initialize_storage, save_stores =	mamlib.initialize_storage, mamlib.save_stores;
local get_prefs, set_prefs = mamlib.get_prefs, mamlib.set_prefs;
local generate_stanzas, process_message, purge_messages =
	mamlib.generate_stanzas, mamlib.process_message, mamlib.purge_messages;

local session_stores = mamlib.session_stores;
local storage = initialize_storage();

-- Handlers

local function initialize_session_store(event)
	local user, host = event.session.username, event.session.host;
	local bare_jid = jid_join(user, host);
	
	local bare_session = bare_sessions[bare_jid];
	if bare_session and not bare_session.archiving then
		session_stores[bare_jid] = storage:get(user) or { logs = {}, prefs = { default = "never" } };
		bare_session.archiving = session_stores[bare_jid];
	end	
end

local function remove_session_store(event)
	local user, host = event.session.username, event.session.host;
	local bare_jid = jid_join(user, host);
	local bare_session = bare_sessions[bare_jid];
	if not bare_session then session_stores[bare_jid] = nil; end -- dereference session store.
end

local function save_session_store(event)
	local user, host = event.session.username, event.session.host;
	local bare_jid = jid_join(user, host);
	local user_archive = session_stores[bare_jid];
	if user_archive.changed then
		user_archive.changed = nil;
		storage:set(user, user_archive);
	end
end

local function process_inbound_messages(event)
	process_message(event);
end

local function process_outbound_messages(event)
	process_message(event, true);
end

local function prefs_handler(event)
	local origin, stanza = event.origin, event.stanza;
	local bare_session = bare_sessions[jid_bare(origin.full_jid)];

	if stanza.attr.type == "get" then
		local reply = st.reply(stanza);
		reply:add_child(get_prefs(bare_session.archiving));
		return origin.send(reply);
	else
		local _prefs = stanza.tags[1];
		local reply = set_prefs(stanza, bare_session.archiving);
		return origin.send(reply);
	end
end

local function purge_handler(event)
	local origin, stanza = event.origin, event.stanza;
	local purge = stanza.tags[1];
	local bare_jid = jid_bare(origin.full_jid);
	
	local bare_session = bare_sessions[bare_jid];
	local archive = bare_session.archiving;
	
	if forbid_purge then
		return origin.send(st.error_reply(stanza, "cancel", "not-allowed", "Purging message archives is not allowed"));
	end
	
	local id, jid, start, fin =
		purge:get_child_text("id"), purge:get_child_text("jid"), purge:get_child_text("start"), purge:get_child_text("end");

	local vjid, vstart, vfin = (jid and jid_prep(jid)), (start and dt_parse(start)), (fin and dt_parse(fin));
	if (start and not vstart) or (fin and not vfin) or (jid and not vjid) then
		return origin.send(st.error_reply(stanza, "modify", "bad-request", "Supplied parameters failed verification"));
	end
	
	purge_messages(archive, id, vjid, vstart, vfin);
	module:log("debug", "%s purged Archives", bare_jid);
	return origin.send(st.reply(stanza));
end

local function features_handler(event)
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

local function query_handler(event)
	local origin, stanza = event.origin, event.stanza;
	local query = stanza.tags[1];
	local qid = query.attr.queryid;
	local legacy = query.attr.xmlns == legacy_xmlns;
	
	local bare_session = bare_sessions[jid_bare(origin.full_jid)];
	local archive = bare_session.archiving;

	local start, fin, with, after, before, max, index, rsm;
	local ok, ret = validate_query(stanza, archive, query, qid);
	if not ok then
		return origin.send(ret);
	else
		start, fin, with, after, before, max, index, rsm =
			ret.start, ret.fin, ret.with, ret.after, ret.before, ret.max, ret.index, ret.rsm;
	end
	
	local messages, rq = generate_stanzas(archive, start, fin, with, max, after, before, index, qid, rsm, legacy);
	if messages == false then -- Exceeded limit
		module:log("debug", "MAM Query yields too many results, aborted");
		return origin.send(st.error_reply(stanza, "cancel", "policy-violation", "Too many results"));
	elseif not messages then -- RSM item-not-found
		module:log("debug", "MAM Query RSM parameters were out of bounds: After - %s, Before - %s, Max - %s, Index - %s",
			tostring(after), tostring(before), tostring(max), tostring(index));
		local rsm_error = st.error_reply(stanza, "cancel", "item-not-found");
		rsm_error:add_child(query);
		return origin.send(rsm_error);
	end

	local reply = st.reply(stanza);

	if not legacy then origin.send(reply); end
	for _, message in ipairs(messages) do
		message.attr.to = origin.full_jid;
		origin.send(message);
	end
	if legacy then
		if rq then reply:add_child(rq); end
		origin.send(reply);
	else
		origin.send(
			st.message({ to = origin.full_jid, queryid = qid }):add_child(rq)
		);
	end

	module:log("debug", "MAM query %s completed", qid and tostring(qid).." " or "");
	return true;
end

function module.load()
	-- initialize on all existing bare sessions.
	for bare_jid, bare_session in pairs(bare_sessions) do
		local user, host = jid_split(bare_jid);
		if host == module_host then
			session_stores[bare_jid] = storage:get(user) or { logs = {}, prefs = { default = "never" } };
			bare_session.archiving = session_stores[bare_jid];
		end
	end
end
function module.save() return { storage = storage, session_stores = session_stores } end
function module.restore(data) 
	mamlib.storage = data.storage;
	mamlib.session_stores = data.session_stores or {};
	storage, session_stores = mamlib.storage, mamlib.session_stores;
	if not data.storage then storage = initialize_storage(); end
end
function module.unload()
	save_stores();
	-- remove all caches from bare_sessions.
	for bare_jid, bare_session in pairs(bare_sessions) do
		local host = jid_section(bare_jid, "host");
		if host == module_host then bare_session.archiving = nil; end
	end
end

module:hook("pre-resource-unbind", save_session_store, 30);
module:hook("resource-bind", initialize_session_store);
module:hook("resource-unbind", remove_session_store, 30);

module:hook("message/bare", process_inbound_messages, 30);
module:hook("pre-message/bare", process_outbound_messages, 30);
module:hook("message/full", process_inbound_messages, 30);
module:hook("pre-message/full", process_outbound_messages, 30);

module:hook("iq/self/"..legacy_xmlns..":prefs", prefs_handler);
module:hook("iq/self/"..xmlns..":prefs", prefs_handler);
module:hook("iq-set/self/"..purge_xmlns..":purge", purge_handler);
module:hook("iq-get/self/"..legacy_xmlns..":query", query_handler);
module:hook("iq-set/self/"..xmlns..":query", query_handler);
module:hook("iq-get/self/"..xmlns..":query", features_handler);

module:hook_global("server-stopping", save_stores);
