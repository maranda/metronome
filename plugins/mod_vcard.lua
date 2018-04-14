-- * Metronome IM *
--
-- This file is part of the Metronome XMPP server and is released under the
-- ISC License, please see the LICENSE file in this source package for more
-- information about copyright and licensing.
--
-- As per the sublicensing clause, this file is also MIT/X11 Licensed.
-- ** Copyright (c) 2008-2012, Matthew Wild, Waqas Hussain

if hosts[module.host].anonymous_host then
	module:log("error", "vCards won't be available on anonymous hosts as storage is explicitly disabled");
	modulemanager.unload(module.host, "vcard");
	return;
end

local tostring = tostring;

local st = require "util.stanza";
local jid_split = require "util.jid".split;
local datamanager = require "util.datamanager";
local sha1 = require "util.hashes".sha1;
local b64_decode = require "util.encodings".base64.decode;
local t_remove = table.remove;
local metronome = metronome;

local data_xmlns, metadata_xmlns = "urn:xmpp:avatar:data", "urn:xmpp:avatar:metadata";

local vcard_max = module:get_option_number("vcard_max_size");

module:add_feature("vcard-temp");
module:add_feature("urn:xmpp:pep-vcard-conversion:0");

local function handle_synchronize(event)
	local node, host = event.node, event.host;
	if host ~= module.host then return; end

	local vCard = st.deserialize(datamanager.load(node, host, "vcard"));

	if vCard then
		return vCard;
	else
		return false;
	end
end		

local function handle_vcard(event)
	local session, stanza = event.origin, event.stanza;
	local to = stanza.attr.to;
	if stanza.attr.type == "get" then
		local vCard;
		if to then
			local node, host = jid_split(to);
			vCard = st.deserialize(datamanager.load(node, host, "vcard")); -- load vCard for user or server
		else
			vCard = st.deserialize(datamanager.load(session.username, session.host, "vcard"));-- load user's own vCard
		end
		if vCard then
			session.send(st.reply(stanza):add_child(vCard)); -- send vCard!
		else
			session.send(st.error_reply(stanza, "cancel", "item-not-found"));
		end
	else
		if not to then
			local vCard = stanza.tags[1];
			
			if vcard_max and tostring(vCard):len() > vcard_max then
				return session.send(st.error_reply(stanza, "modify", "policy-violation", "The vCard data exceeded the max allowed size!"));
			end
			
			local ok, err = datamanager.store(session.username, session.host, "vcard", st.preserialize(vCard));
			if ok then
				session.send(st.reply(stanza));
				metronome.events.fire_event("vcard-updated", { node = session.username, host = session.host, vcard = vCard });

				local from = stanza.attr.from or origin.full_jid;
				local pep_service = module:fire_event("pep-get-service", session.username, true, from);
				if pep_service then -- sync avatar
					local photo = vCard:child_with_name("PHOTO");
					if photo then
						local data, type = photo:child_with_name("BINVAL"), photo:child_with_name("TYPE");
						if data and type then
							module:log("debug", "Converting vCard-based Avatar to User Avatar...");
							data, type = data:get_text(), type:get_text();
							local bytes, id = data:len(), sha1(b64_decode(data), true);

							local data_item = st.stanza("item", { id = id })
								:tag("data", { xmlns = data_xmlns }):text(data):up():up();
							
							local metadata_item = st.stanza("item", { id = id })
								:tag("metadata", { xmlns = metadata_xmlns })
									:tag("info", { bytes = bytes, id = id, type = type }):up():up():up();

							if not pep_service.nodes[data_xmlns] then
								pep_service:create(data_xmlns, from, { max_items = 1 });
								module:fire_event("pep-autosubscribe-recipients", pep_service, data_xmlns);
							end
							if not pep_service.nodes[metadata_xmlns] then
								pep_service:create(metadata_xmlns, from, { max_items = 1 });
								module:fire_event("pep-autosubscribe-recipients", pep_service, data_xmlns);
							end

							pep_service:publish(data_xmlns, from, id, data_item);
							pep_service:publish(metadata_xmlns, from, id, metadata_item);
						else
							module:log("warn", "Failed to perform avatar conversion, PHOTO element is not valid");
						end
					end
				end
			else
				-- TODO unable to write file, file may be locked, etc, what's the correct error?
				session.send(st.error_reply(stanza, "wait", "internal-server-error", err));
			end
		else
			session.send(st.error_reply(stanza, "auth", "forbidden"));
		end
	end
	return true;
end

local waiting_metadata = setmetatable({}, { __mode = "v" });

local function handle_user_avatar(event)
	local node, item, from = event.node, event.item, event.from or event.origin.full_jid;

	if node == metadata_xmlns then
		local meta = item:get_child("metadata", node);
		local info = meta and meta:child_with_name("info");

		if info then
			local data = waiting_metadata[info.attr.id];
			if not data then return; end
			waiting_metadata[info.attr.id] = nil;

			local type = info.attr.type;
			local user, host = jid_split(from);
			local vCard = st.deserialize(datamanager.load(user, host, "vcard"));
			if vCard then
				for n, tag in ipairs(vCard.tags) do	
					if tag.name == "PHOTO" then t_remove(tag, n); end
				end

				vCard:tag("PHOTO")
					:tag("TYPE"):text(type):up()
					:tag("BINVAL"):text(data):up():up();
			else
				vCard = st.stanza("vcard", { xmlns = "vcard-temp" })
					:tag("PHOTO")
						:tag("TYPE"):text(type):up()
						:tag("BINVAL"):text(data):up():up();
			end

			module:log("debug", "Converting User Avatar to vCard-based Avatar...");
			datamanager.store(session.username, session.host, "vcard", st.preserialize(vCard));
		end
	elseif node == data_xmlns then
		local data = item:get_child_text("data", node);
		if data then waiting_metadata[sha1(b64_decode(data), true)] = data;	end
	end
end

module:hook_global("vcard-synchronize", handle_synchronize);
module:hook("iq/bare/vcard-temp:vCard", handle_vcard);
module:hook("iq/host/vcard-temp:vCard", handle_vcard);
module:hook("pep-node-publish", handle_user_avatar);
