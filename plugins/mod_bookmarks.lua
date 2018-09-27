-- * Metronome IM *
--
-- This file is part of the Metronome XMPP server and is released under the
-- ISC License, please see the LICENSE file in this source package for more
-- information about copyright and licensing.

-- This module synchronizes XEP-0048 Bookmarks between PEP and Private Storage.

local uuid = require "util.uuid".generate;
local section = require "util.jid".section;

local bookmarks_xmlns = "storage:bookmarks";

module:hook("private-storage-callback", function(event)
	local session, key, data = event.session, event.key, event.data;
	if key == bookmarks_xmlns then
		local pep_service = module:fire_event("pep-get-service", session.username, true, session.full_jid);
		if pep_service then
			local item = st.stanza("item", { id = uuid }):add_child(data):up();

			if not pep_service.nodes[bookmarks_xmlns] then
				pep_service:create(bookmarks_xmlns, from, { access_model = "whitelist", persist_items = true });
				module:fire_event("pep-autosubscribe-recipients", pep_service, bookmarks_xmlns);
			end
			pep_service:publish(bookmarks_xmlns, from, id, data_item);
		end
	end
end);

module:hook("pep-node-publish", function(event)
	local node, item, from = event.node, event.item, event.from or event.origin.full_jid;

	if node == bookmarks_xmlns then
		local data = item:get_child("storage", bookmarks_xmlns);
		if data then
			module:fire_event("private-storage-set", { 
				user = section(from, "node"), key = bookmarks_xmlns, tag = data, from = from
			});
		end
	end
end);