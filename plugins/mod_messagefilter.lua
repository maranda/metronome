-- * Metronome IM *
--
-- This file is part of the Metronome XMPP server and is released under the
-- ISC License, please see the LICENSE file in this source package for more
-- information about copyright and licensing.

local st = require "util.stanza";
local section = require "util.jid".section;
local hosts = metronome.hosts;

local patterns = module:get_option_table("messagefilter_patterns", {});
local ahosts = module:get_option_set("messagefilter_anon_hosts", {});
local bounce_message = module:get_option_string("messagefilter_bmsg", "Message rejected by server filter");

local function message_filter(event)
	local origin, stanza = event.origin, event.stanza;
	local body_text = stanza:child_with_name("body") and stanza:child_with_name("body"):get_text();
	local fromhost = section(stanza.attr.from, "host");

	local error_reply = st.message{ type = "error", from = stanza.attr.to }
					:tag("error", {type = "modify"})
						:tag("not-acceptable", {xmlns = "urn:ietf:params:xml:ns:xmpp-stanzas"})
							:tag("text", {xmlns = "urn:ietf:params:xml:ns:xmpp-stanzas"}):text(bounce_message):up();

	if body_text then
		local host = ahosts:contains(fromhost) and hosts[fromhost];
		if not host or not host.anonymous then return; end
		
		for _, pattern in ipairs(patterns) do
			if body_text:match(pattern) then
				error_reply.attr.to = stanza.attr.from;
				origin.send(error_reply);
				module:log("info", "Bounced message from anon user %s because it contained profanity", stanza.attr.from);
				return true; -- Drop the stanza now
			end
		end
	end
end

module:hook("message/bare", message_filter, 95);
module:hook("message/full", message_filter, 95);
module:hook("message/host", message_filter, 95);
