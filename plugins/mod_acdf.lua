-- * Metronome IM *
--
-- This file is part of the Metronome XMPP server and is released under the
-- ISC License, please see the LICENSE file in this source package for more
-- information about copyright and licensing.

-- This module implements Access Control Decision Function (ACDF) for Security Labels

local apply_policy = module:require("acdf_aux").apply_policy;

local labels_xmlns = "urn:xmpp:sec-label:0";

local function incoming_message_handler(event)
	local session, stanza = event.origin, event.stanza;
	local label = stanza:get_child("securitylabel", labels_xmlns);

	if label then
		local text = label:get_child_text("displaymarking");
		local actions = module:fire_event("sec-labels-fetch-actions", text);
		if actions then return apply_policy(text, session, stanza, actions); end
	end
end

local function outgoing_message_handler(event)
	local session, stanza = event.origin, event.stanza;
	local label = stanza:get_child("securitylabel", labels_xmlns);

	if label then
		local text = label:get_child_text("displaymarking");
		local actions = module:fire_event("sec-labels-fetch-actions", text);
		if actions then return apply_policy(text, session, stanza, actions); end
	end
end

module:hook("message/bare", incoming_message_handler, 90);
module:hook("message/full", incoming_message_handler, 90);
module:hook("pre-message/bare", outgoing_message_handler, 90);
module:hook("pre-message/full", outgoing_message_handler, 90);