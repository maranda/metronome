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
local metronome = metronome;

local vcard_max = module:get_option_number("vcard_max_size");

module:add_feature("vcard-temp");

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

module:hook_global("vcard-synchronize", handle_synchronize);
module:hook("iq/bare/vcard-temp:vCard", handle_vcard);
module:hook("iq/host/vcard-temp:vCard", handle_vcard);
