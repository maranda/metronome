-- * Metronome IM *
--
-- This file is part of the Metronome XMPP server and is released under the
-- ISC License, please see the LICENSE file in this source package for more
-- information.

local jid = require "util.jid";
local jid_list, block_pattern;

local function reload_config()
	jid_list = module:get_option_set("tsub_block_jidlist", {});
	block_pattern = module:get_option_string("tsub_block_pattern", "");
end
module:hook("config-reloaded", reload_config);
reload_config();

local function block_transports_sub_to_bots(data)
	local origin, stanza = data.origin, data.stanza;

	if stanza.attr.type == "subscribe"
	   and jid_list:contains(stanza.attr.to)
	   and jid.compare(stanza.attr.from, block_pattern) then
		return true;
	end

	if stanza.attr.type == "set"
	   and jid_list:contains(stanza.attr.to)
	   and jid.compare(stanza.attr.from, block_pattern) then
		return true;
	end
end

module:hook("iq-set/full/http://jabber.org/protocol/rosterx", block_transports_sub_to_bots, 10);
module:hook("presence/bare", block_transports_sub_to_bots, 10);
module:hook("pre-presence/bare", block_transports_sub_to_bots, 10)
