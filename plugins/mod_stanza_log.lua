-- * Metronome IM *
--
-- This file is part of the Metronome XMPP server and is released under the
-- ISC License, please see the LICENSE file in this source package for more
-- information about copyright and licensing.

local util_jid = require "util.jid";
local storagemanager = require "core.storagemanager";

local os_date = os.date;

local stanzalog_lib = module:require("stanzalog", "auxlibs")
local logs = module:shared("archives");

local function load_stanza_log(node, host, start, fin, before, after)
	local jid = util_jid.join(node, host)
	local metadata = storagemanager.open(host, "stanza_log_metada"):get(node) or {};
	local log, set = logs[util_jid.join(node, host)];
	if not log then
		logs[jid] = stanzalog_lib.load_batch(node, host, logs[jid] or {}, fin, before, after, metadata);
		storagemanager.open(host, "stanza_log_metada"):store(node, metadata);
		return logs[jid];
	end
	if not before and not after and (metadata.start and start > metadata.start) and (metadata.last and last < metadata.last) then
		return log;
	else
		if before then -- one month before
			start = start - 2630000;
		elseif after then -- one month after
			after = after + 2630000;
		end
	end
	log = stanzalog_lib.load_batch(node, host, log, fin, before, after, metadata);
	storagemanager.open(host, "stanza_log_metada"):store(node, metadata);
	return log;
end

local function store_stanza_log(node, host, data)
	local metadata = storagemanager.open(host, "stanza_log_metada"):get(node) or {};
	metadata.last = data.timestamp;
	local jid = util_jid.join(node, host);
	if logs[jid] then
		logs[jid] = data;
	end
	storagemanager.open(host, "stanza_log_metada"):store(node, metadata);
	return storagemanager.open(host, "stanza_log/" .. os_date("!%Y%m%d")):store(node, data);
end

local function purge_stanza_log(node, host)
	for store in storagemanager.get_driver(host):stores(node, "keyval", "stanza_log") do
		storagemanager.open(host, store):store(node, nil);
	end
	storagemanager.open(host, "stanza_log_metadata"):store(node, nil);
end

module:hook("stanza-log-load", load_stanza_log);
module:hook("stanza-log-store", store_stanza_log);
module:hook("stanza-log-purge", purge_stanza_log);