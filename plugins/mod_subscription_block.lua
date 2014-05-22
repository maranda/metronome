-- * Metronome IM *
--
-- This file is part of the Metronome XMPP server and is released under the
-- ISC License, please see the LICENSE file in this source package for more
-- information about copyright and licensing.

local jid = require "util.jid";
local st_reply = require "util.stanza".reply;

local jid_list, block_pattern;

local function load_config()
	jid_list = module:get_option_set("subscription_block_jidlist", {});
	block_pattern = module:get_option_string("subscription_block_pattern", "");
end

local function block_subscription(data)
	local origin, stanza = data.origin, data.stanza;

	if stanza.attr.type == "subscribe"
	   and jid_list:contains(stanza.attr.to)
	   and jid.compare(stanza.attr.from, block_pattern) then
		return true;
	end

	if stanza.attr.type == "set"
	   and jid_list:contains(jid.bare(stanza.attr.to))
	   and jid.compare(stanza.attr.from, block_pattern) then
		return origin.send(st_reply(stanza, "cancel", "not-allowed"));
	end
end

module:hook("iq-set/full/http://jabber.org/protocol/rosterx", block_subscription, 10);
module:hook("presence/bare", block_subscription, 10);
module:hook("pre-presence/bare", block_subscription, 10);
module:hook_global("config-reloaded", load_config);

load_config();
