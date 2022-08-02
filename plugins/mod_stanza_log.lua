-- * Metronome IM *
--
-- This file is part of the Metronome XMPP server and is released under the
-- ISC License, please see the LICENSE file in this source package for more
-- information about copyright and licensing.

local util_jid = require "util.jid";
local storagemanager = require "core.storagemanager";

local os_date = os.date;

local stanzalog_lib = module:require("stanzalog", "auxlibs");
logs = { index = {} };

local function load_stanza_log(node, host, start, fin, before, after)
	local jid = util_jid.join(node, host)
	local metadata = storagemanager.open(host, "stanza_log_metada"):get(node) or {};
	local log, set = logs[util_jid.join(node, host)];
	if not log then
		logs[jid] = stanzalog_lib.load_batch(node, host, {}, start, fin, before, after, metadata, logs.index);
		storagemanager.open(host, "stanza_log_metada"):set(node, metadata);
		return logs[jid];
	end
	if #log > 0 then -- otherwise it's empty, good bye
		-- in case we miss argument try to construct the archive timeframes basing either on saved metadata or
		-- first and last entries in the log cache array, that we have
		if not start then
			if metadata.first then
				start = metadata.first;
			else
				start = log[1].timestamp;
			end
		end
		if not fin then
			if metadata.last then
				fin = metadata.last;
			else
				fin = log[#log].timestamp;
			end
		end
	else
		return log;
	end
	if not before and not after and (metadata.first and start >= metadata.first) and (metadata.last and fin <= metadata.last) then
		return log;
	else
		if before then
			start = start - 2630000;
		elseif after then -- one month after
			fin = fin + 2630000;
		end
	end
	log = stanzalog_lib.load_batch(node, host, log, start, fin, before, after, metadata, logs.index);
	storagemanager.open(host, "stanza_log_metada"):set(node, metadata);
	return log;
end

local function store_stanza_log(node, host, data, last)
	local metadata = storagemanager.open(host, "stanza_log_metada"):get(node) or {};
	metadata.last = last.timestamp;
	logs.index[last.uid] = last.timestamp;
	local jid = util_jid.join(node, host);
	if logs[jid] then
		logs[jid] = data;
	end
	storagemanager.open(host, "stanza_log_metada"):set(node, metadata);
	return storagemanager.open(host, "stanza_log/" .. os_date("!%Y%m%d")):set(node, data);
end

local function purge_stanza_log(node, host)
	for store in storagemanager.get_driver(host):stores(node, "keyval", "stanza_log") do
		local entries = storagemanager.open(host, store):get(node) or {};
		for _, entry in ipairs(entries) do logs[entry.uid] = nil; end
		storagemanager.open(host, store):set(node);
	end
	storagemanager.open(host, "stanza_log_metadata"):set(node);
end

module:hook_global("config-reloaded", function()
	module:log("debug", "Purging stanza log cache...");
	logs = { index = {} };
end);

module:hook("load-stanza-log", load_stanza_log);
module:hook("store-stanza-log", store_stanza_log);
module:hook("purge-stanza-log", purge_stanza_log);