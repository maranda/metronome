-- * Metronome IM *
--
-- This file is part of the Metronome XMPP server and is released under the
-- ISC License, please see the LICENSE file in this source package for more
-- information about copyright and licensing.

local base64 = require "util.encodings".base64;
local sha1 = require "util.hashes".sha1;
local st = require "util.stanza";
local storagemanager = require "core.storagemanager";
local uuid = require "util.uuid".generate;

local now, pairs = os.time, pairs;

local xhtml_xmlns = "http://www.w3.org/1999/xhtml";
local bob_xmlns = "urn:xmpp:bob";

local bob_cache = storagemanager.open(module.host, "bob_cache");
local index = bob_cache:get() or {};
local queried = {};

local default_expire = module:get_option_number("muc_bob_default_cache_expire", 86400);
local check_caches = module:get_option_number("muc_bob_check_for_expiration", 900);

module:add_timer(check_caches, function()
	module:log("debug", "checking for BoB caches that need to be expired...");
	for cid, data in pairs(index) do
		if now() - data.time > data.max then 
			index[cid] = nil;
			bob_cache:set(cid, nil);
		end
	end
	return check_caches;
end);

local function get_bob(jid, room, cid)
	local iq = st.iq({ type = "get", from = room, to = jid, id = uuid() })
		:tag("data", { xmlns = "urn:xmpp:bob", cid = cid }):up();
		module:log("debug", "Querying %s for BoB image found into XHTML-IM with cid %s", jid, cid);
		module:send(iq);
		queried[cid] = {};
end

local function cache_data(tag)
	if tag.name ~= "data" or tag.attr.xmlns ~= bob_xmlns then
		return tag;
	end
	local cid, mime, max = tag.attr.cid, tag.attr.type, tag.attr["max-age"];
	local encoded_data = tag:get_text();
	local decoded_data = base64.decode(encoded_data);
	local hash = sha1(decoded_data, true);
	local calculated = "sha1+"..hash.."@bob.xmpp.org"
	if cid ~= calculated then
		module:log("warn", "Invalid BoB, cid doesn't match data, got %s instead of %s", cid, calculated);
		return;
	end

	index[cid] = { time = now(), max = max or default_expire };
	bob_cache:set(cid, { mime = mime, data = encoded_data });
	bob_cache:set(nil, index);
	if queried[cid] then
		local iq = st.iq({ type = "result" });
		iq:add_child(tag);
		for jid, query in pairs(queried[cid]) do
			iq.attr.from, iq.attr.to, iq.attr.id = query.from, jid, query.id;
			module:send(iq);
		end
		query[cid] = nil;
	end
	return nil;
end

local function traverse_xhtml(tag, from, room)
	if tag.name == "img" and tag.attr.xmlns == xhtml_xmlns and tag.attr.src then
		local cid = tag.attr.src:match("^cid:(%w+%+%w+@bob%.xmpp%.org)$");
		if not cid then return; end
		if bob_cache:get(cid) or queried[cid] then return; end
		get_bob(from, room, cid);
	end
	for child in tag:childtags(nil, xhtml_xmlns) do	traverse_xhtml(tag, from, room); end
end

local function message_handler(event)
	local origin, stanza = event.origin, event.stanza;
	local from, room = stanza.attr.from, stanza.attr.to;

	stanza:maptags(cache_data);

	local xhtml_im = stanza:get_child("html", xhtml_xmlns);
	if not xhtml_im then return; end

	for body in xhtml_im:childtags("body", xhtml_xmlns) do traverse_xhtml(body, from, room); end
end

local function iq_handler(event)
	local origin, stanza = event.origin, event.stanza;

	local tag = stanza.tags[1];
	if not tag then return; end
	local cid = tag.attr.cid;
	if (tag.name ~= "data" and tag.attr.xmlns ~= bob_xmlns) or not cid then return; end

	if stanza.attr.type == "result" then cache_data(tag); end
	if stanza.attr.type == "get" then
		local cached = bob_cache:get(cid);
		if not cached then
			if queried[cid] then
				module:log("debug", "IQ for requesting BoB for %s already sent, waiting for replies", cid);
				queried[cid][stanza.attr.from] = { from = stanza.attr.to, id = stanza.attr.id };
				return true;
			else
				module:log("debug", "Bit of Binary requested data is not present in cache (%s), ignoring", cid);
				origin.send(st.error_reply(stanza, "cancel", "item-not-found"));
				return true;
			end
		end

		local iq = st.reply(stanza);
		iq:tag("data", { xmlns = bob_xmlns, cid = cid, type = cached.mime, ["max-age"] = index[cid].max })
			:text(cached.data):up();
		module:log("debug", "Delivering cached BoB data (%s) on behalf of %s", cid, stanza.attr.to);
		module:send(iq);
		return true;
	end
end

module:hook("muc-disco-info-features", function(room, reply)
	reply:tag("feature", { var = bob_xmlns }):up()
end, -98);

module:hook("message/bare", message_handler, 51);
module:hook("iq/full", iq_handler, 51);
module:hook("iq/bare", iq_handler, 51);
