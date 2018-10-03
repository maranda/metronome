-- * Metronome IM *
--
-- This file is part of the Metronome XMPP server and is released under the
-- ISC License, please see the LICENSE file in this source package for more
-- information about copyright and licensing.

if not module:host_is_muc() then
	module:log("error", "mod_muc_vcard can only be loaded on a muc component!");
	return;
end

local host_object = module:get_host_session();

local ipairs, tostring, t_remove = ipairs, tostring, table.remove;
local st = require "util.stanza";
local jid_bare, jid_split = require "util.jid".bare, require "util.jid".split;
local sha1 = require "util.hashes".sha1;
local debase64 = require "util.encodings".base64.decode;

local room_icons = storagemanager.open(module.host, "room_icons");

local vcard_max = module:get_option_number("vcard_max_size");

module:hook("muc-disco-info-features", function(room, reply)
	reply:tag("feature", { var = "vcard-temp" }):up()
end, -101);

module:hook("muc-room-destroyed", function(event)
	local node, host = jid_split(event.room.jid);
	room_icons:set(node);
end);

module:hook("muc-occupant-list-sent", function(room, from, nick, origin)
	if room.vcard_hash == nil then -- load and cache
		local node, host = jid_split(room.jid);
		local stored_vcard = room_icons:get(node);
		if stored_vcard and stored_vcard.hash then
			room.vcard_hash = stored_vcard.hash or false;
		else
			room.vcard_hash = false;
		end
	end

	if room.vcard_hash then
		local pr = st.presence({ id = "room-avatar", from = room.jid, to = from })
			:tag("x", { xmlns = "vcard-temp:x:update" }):tag("photo"):text(room.vcard_hash):up():up();
		
		origin.send(pr);
	end
end);

module:hook("iq/bare/vcard-temp:vCard", function(event)
	local session, stanza = event.origin, event.stanza;
	local from, to = jid_bare(stanza.attr.from) or session.username.."@"..session.host, stanza.attr.to;
	local node, host = jid_split(to);

	local room = host_object.muc.rooms[to];
	if not room then
		session.send(st.error_reply(stanza, "cancel", "item-not-found"));
		return true;
	end

	if stanza.attr.type == "get" then
		local stored_vcard = room_icons:get(node);
		if stored_vcard then
			session.send(st.reply(stanza):add_child(st.deserialize(stored_vcard.photo)));
		else
			session.send(st.error_reply(stanza, "cancel", "item-not-found", "Room icon not found"));
		end
	else
		if room:get_affiliation(from) == "owner" then
			local vCard = stanza.tags[1];

			local count = 0;
			for n, tag in ipairs(vCard.tags) do
				-- strip everything else
				if tag.name ~= "PHOTO" then t_remove(vCard.tags, n); t_remove(vCard, n); else count = count + 1; end
			end
			if count > 1 then
				return session.send(st.error_reply(stanza, "modify", "policy-violation", "vCards with multiple PHOTO elements are not supported"));
			end

			if #vCard.tags == 0 then
				if room_icons:set(node) then
					session.send(st.reply(stanza));
				else
					session.send(st.error_reply(stanza, "wait", "internal-server-error", "Failed to remove room icon"));
				end
				return true;
			elseif not vCard.tags[1]:child_with_name("TYPE") or not vCard.tags[1]:child_with_name("BINVAL") then
				session.send(st.error_reply(stanza, "modify", "bad-request", "The PHOTO element is invalid"));
				return true;
			end
			
			if vcard_max and tostring(vCard):len() > vcard_max then
				session.send(st.error_reply(stanza, "modify", "policy-violation", "The vCard data exceeded the max allowed size!"));
				return true;
			end

			local hash = sha1(debase64(vCard.tags[1]:child_with_name("BINVAL"):get_text()), true);
			
			if room_icons:set(node, { photo = st.preserialize(vCard), hash = hash }) then
				session.send(st.reply(stanza));
				room.vcard_hash = hash;
				local pr = st.presence({ id = "room-avatar", from = room.jid })
					:tag("x", { xmlns = "vcard-temp:x:update" }):tag("photo"):text(hash):up():up();
				room:broadcast_except_nick(pr);
			else
				session.send(st.error_reply(stanza, "wait", "internal-server-error", "Failed to store room icon"));
			end
		else
			session.send(st.error_reply(stanza, "auth", "not-authorized", "Only an owner of this room can change the icon"));
		end
	end
	return true;
end);
