-- * Metronome IM *
--
-- This file is part of the Metronome XMPP server and is released under the
-- ISC License, please see the LICENSE file in this source package for more
-- information about copyright and licensing.

local modulemanager = modulemanager;
if not modulemanager.is_loaded(module.host, "muc") then
	module:log("error", "mod_muc_vcard can only be loaded on a muc component!");
	modulemanager.unload(module.host, "muc_vcard");
	return;
end

local rooms = hosts[module.host].muc.rooms;

local ipairs, tostring, t_remove = ipairs, tostring, table.remove;
local st = require "util.stanza";
local jid_bare, jid_split = require "util.jid".bare, require "util.jid".split;
local load, store = require "util.datamanager".load, require "util.datamanager".store;

local vcard_max = module:get_option_number("vcard_max_size");

module:hook("muc-disco-info-features", function(room, reply)
	reply:tag("feature", { var = "vcard-temp" }):up()
end, -101);

module:hook("muc-room-destroyed", function(event)
	local node, host = jid_split(event.room.jid);
	store(node, host, "room_icons", nil);
end);

module:hook("iq/bare/vcard-temp:vCard", function(event)
	local session, stanza = event.origin, event.stanza;
	local from, to = jid_bare(stanza.attr.from) or session.username.."@"..session.host, stanza.attr.to;
	local node, host = jid_split(to);

	local room = rooms[to];
	if not room then
		session.send(st.error_reply(stanza, "cancel", "item-not-found"));
		return true;
	end

	if stanza.attr.type == "get" then
		local vCard = st.deserialize(load(node, host, "room_icons"));
		if vCard then
			session.send(st.reply(stanza):add_child(vCard));
		else
			session.send(st.error_reply(stanza, "cancel", "item-not-found", "Room icon not found"));
		end
	else
		if room:get_affiliation(from) == "owner" then
			local vCard = stanza.tags[1];

			for n, tag in ipairs(vCard.tags) do
				-- strip everything else
				if tag.name ~= "PHOTO" then t_remove(vCard.tags, n); end
			end
			
			if vcard_max and tostring(vCard):len() > vcard_max then
				session.send(st.error_reply(stanza, "modify", "policy-violation", "The vCard data exceeded the max allowed size!"));
				return true;
			end
			
			if store(node, host, "room_icons", st.preserialize(vCard)) then
				session.send(st.reply(stanza));
			else
				session.send(st.error_reply(stanza, "wait", "internal-server-error", "Failed to store room icon"));
			end
		else
			session.send(st.error_reply(stanza, "auth", "not-authorized", "Only an owner of this room can change the icon"));
		end
	end
	return true;
end);
