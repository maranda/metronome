-- * Metronome IM *
--
-- This file is part of the Metronome XMPP server and is released under the
-- ISC License, please see the LICENSE file in this source package for more
-- information about copyright and licensing.

-- Message Archiving Management for Metronome,
-- This implements a limited, simplified set of XEP-313.

local bare_sessions = metronome.bare_sessions;
local module_host = module.host;

local dt_parse = require "util.datetime".parse;
local st = require "util.stanza";
local jid_bare = require "util.jid".bare;
local jid_join = require "util.jid".join;
local jid_prep = require "util.jid".prep;
local ipairs, tonumber, tostring = ipairs, tonumber, tostring;

local xmlns = "urn:xmpp:mam:0";
local rsm_xmlns = "http://jabber.org/protocol/rsm";

module:add_feature(xmlns);

local forbid_purge = module:get_option_boolean("mam_forbid_purge", false);
local max_results = module:get_option_number("mam_max_retrievable_results", 50);
if max_results >= 100 then max_results = 100; end

local mamlib = module:require "mam";
local initialize_storage, save_stores =	mamlib.initialize_storage, mamlib.save_stores;
local get_prefs, set_prefs = mamlib.get_prefs, mamlib.set_prefs;
local generate_stanzas, process_message, purge_messages =
	mamlib.generate_stanzas, mamlib.process_message, mamlib.purge_messages;

local session_stores = mamlib.session_stores;
local storage = initialize_storage();

-- Handlers

local function initialize_session_store(event)
	local user, host = event.session.username, event.session.host
	local bare_jid = jid_join(user, host);
	
	local bare_session = bare_sessions[bare_jid];
	if bare_session and not bare_session.archiving then
		session_stores[bare_jid] = storage:get(user) or { logs = {}, prefs = { default = false } };
		bare_session.archiving = session_stores[bare_jid];
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
		local _prefs = stanza:get_child("prefs", xmlns);
		local reply = set_prefs(stanza, bare_session.archiving);
		return origin.send(reply);
	end
end

local function purge_handler(event)
	local origin, stanza = event.origin, event.stanza;
	local purge = stanza:child_with_name("purge");
	local bare_jid = jid_bare(origin.full_jid);
	
	local bare_session = bare_sessions[bare_jid];
	local logs = bare_session.archiving.logs;
	
	if mam_forbid_purge then
		return origin.send(st.error_reply(stanza, "cancel", "not-allowed", "Purging message archives is not allowed"));
	end
	
	local _id, _jid, _start, _end = purge:get_child_text("id"), purge:get_child_text("jid"), purge:get_child_text("start"), purge:get_child_text("end");
	local vjid, vstart, vend = (_jid and jid_prep(_jid)), (_start and dt_parse(_start)), (_end and dt_parse(_end));
	if (_start and not vstart) or (_end and not vend) or (_jid and not vjid) then
		return origin.send(st.error_reply(stanza, "modify", "bad-request", "Supplied parameters failed verification"));
	end
	
	purge_messages(logs, _id, vjid, vstart, vend);
	module:log("debug", "%s purged Archives", bare_jid);
	return origin.send(st.reply(stanza));
end

local function query_handler(event)
	local origin, stanza = event.origin, event.stanza;
	local query = stanza:child_with_name("query");
	local qid = query.attr.queryid;
	
	local bare_session = bare_sessions[jid_bare(origin.full_jid)];
	local archive = bare_session.archiving;
	
	local _start, _end, _with = query:get_child_text("start"), query:get_child_text("end"), query:get_child_text("with");
	module:log("debug", "MAM query received, id %s with %s from %s until %s)", 
		tostring(qid), _with or "anyone", _start or "epoch", _end or "now");

	-- Validate attributes
	local vstart, vend, vwith = (_start and dt_parse(_start)), (_end and dt_parse(_end)), (_with and jid_prep(_with));
	if (_start and not vstart) or (_end and not vend) then
		return origin.send(st.error_reply(stanza, "modify", "bad-request", "Supplied timestamp is invalid"));
	end
	_start, _end = vstart, vend;
	if _with and not vwith then
		return origin.send(st.error_reply(stanza, "modify", "bad-request", "Supplied JID is invalid"));
	end
	_with = jid_bare(vwith);
	
	-- Get RSM set
	local rsm = query:get_child("set", rsm_xmlns);
	local max = rsm and rsm:child_with_name("max"):get_text();
	max = max and tonumber(max);
	
	local logs = archive.logs;
	if #logs > 30 and not max then
		return origin.send(st.error_reply(stanza, "cancel", "policy-violation", "Too many results"));
	elseif max and max > max_results then
		return origin.send(st.error_reply(stanza, "cancel", "policy-violation", "Max retrievable results' count is 100"));
	end
	
	local messages = generate_stanzas(archive, _start, _end, _with, max, qid);
	for _, message in ipairs(messages) do
		message.attr.to = origin.full_jid;
		origin.send(message);
	end
	
	module:log("debug", "MAM query %s completed", tostring(qid));
	return origin.send(st.reply(stanza));
end

function module.save() return { storage = storage, session_stores = session_stores } end
function module.reload(data) 
	mamlib.storage = data.storage;
	mamlib.session_stores = data.session_stores or {};
	storage, session_stores = mamlib.storage, mamlib.session_stores;
	if not data.storage then storage = initialize_storage(); end
end

module:hook("resource-bind", initialize_session_store);

module:hook("message/bare", process_inbound_messages, 30);
module:hook("pre-message/bare", process_outbound_messages, 30);
module:hook("message/full", process_inbound_messages, 30);
module:hook("pre-message/full", process_outbound_messages, 30);

module:hook("iq/self/"..xmlns..":prefs", prefs_handler);
module:hook("iq-set/self/"..xmlns..":purge", purge_handler);
module:hook("iq-get/self/"..xmlns..":query", query_handler);

module:hook_global("server-stopping", save_stores);