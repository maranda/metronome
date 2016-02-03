-- * Metronome IM *
--
-- This file is part of the Metronome XMPP server and is released under the
-- ISC License, please see the LICENSE file in this source package for more
-- information about copyright and licensing.
--
-- As per the sublicensing clause, this file is also MIT/X11 Licensed.
-- ** Copyright (c) 2009-2013, Kim Alvefur, Marco Cirillo, Markus Kutter, Matthew Wild, Rob Hoelz, Waqas Hussain

local pairs, ipairs, next, ripairs = pairs, ipairs, next, ripairs;

local datetime = require "util.datetime";

local dataform = require "util.dataforms";

local jid_section = require "util.jid".section;
local jid_split = require "util.jid".split;
local jid_bare = require "util.jid".bare;
local jid_prep = require "util.jid".prep;
local st = require "util.stanza";
local log = require "util.logger".init("mod_muc");
local t_insert, t_remove = table.insert, table.remove;
local setmetatable = setmetatable;
local base64 = require "util.encodings".base64;
local md5 = require "util.hashes".md5;
local add_timer = require "util.timer".add_task;

local muc_domain = nil; --module:get_host();
local default_history_length = 20;
local max_history_length;

------------
local filters = {["http://jabber.org/protocol/muc"]=true;["http://jabber.org/protocol/muc#user"]=true};
local function filter_stanza(tag)
	if not filters[tag.attr.xmlns] then
		return tag;
	else
		return nil;
	end
end

local function get_filtered_presence(stanza)
	local clone = st.clone(stanza);
	return clone:maptags(filter_stanza);
end

local kickable_error_conditions = {
	["gone"] = true;
	["internal-server-error"] = true;
	["item-not-found"] = true;
	["jid-malformed"] = true;
	["recipient-unavailable"] = true;
	["redirect"] = true;
	["remote-server-not-found"] = true;
	["remote-server-timeout"] = true;
	["service-unavailable"] = true;
	["malformed error"] = true;
};

local function get_error_condition(stanza)
	local _, condition = stanza:get_error();
	return condition or "malformed error";
end

local function is_kickable_error(stanza)
	local cond = get_error_condition(stanza);
	return kickable_error_conditions[cond] and cond;
end
local function getUsingPath(stanza, path, getText)
	local tag = stanza;
	for _, name in ipairs(path) do
		if type(tag) ~= "table" then return; end
		tag = tag:child_with_name(name);
	end
	if tag and getText then tag = table.concat(tag); end
	return tag;
end
local function getTag(stanza, path) return getUsingPath(stanza, path); end
local function getText(stanza, path) return getUsingPath(stanza, path, true); end
local function removeElem(sub, name)
	for i, tag in ipairs(sub) do
		if tag.name == name then t_remove(sub, i); end
	end
end
-----------

local room_mt = {};
local admin_toggles = {};
room_mt.__index = room_mt;

function room_mt:get_default_role(affiliation)
	if affiliation == "owner" or affiliation == "admin" then
		return "moderator";
	elseif affiliation == "member" then
		return "participant";
	elseif not affiliation then
		if not self:get_option("members_only") then
			return self:get_option("moderated") and "visitor" or "participant";
		end
	end
end

function room_mt:broadcast_presence(stanza, sid, code, nick)
	stanza = get_filtered_presence(stanza);
	local occupant = self._occupants[stanza.attr.from];
	stanza:tag("x", {xmlns = "http://jabber.org/protocol/muc#user"})
		:tag("item", {affiliation = occupant.affiliation or "none", role = occupant.role or "none", nick=nick}):up();
	if code then
		stanza:tag("status", {code=code}):up();
	end
	self:broadcast_except_nick(stanza, stanza.attr.from);
	local me = self._occupants[stanza.attr.from];
	if me then
		stanza:tag("status", {code = "110"}):up();
		stanza.attr.to = sid;
		self:_route_stanza(stanza);
	end
end
function room_mt:broadcast_message(stanza, historic, from)
	local to = stanza.attr.to;
	for occupant, o_data in pairs(self._occupants) do
		for jid in pairs(o_data.sessions) do
			stanza.attr.to = jid;
			self:_route_stanza(stanza);
		end
	end
	stanza.attr.to = to;
	if historic then -- add to history
		if not stanza:get_child("body") then return; end -- empty state notification?
		local history = self._data["history"];
		if not history then history = {}; self._data["history"] = history; end
		stanza = st.clone(stanza);
		stanza.attr.to = "";
		local replace = stanza:get_child("replace", "urn:xmpp:message-correct:0");
		local stamp = datetime.datetime();
		stanza:tag("delay", {xmlns = "urn:xmpp:delay", from = muc_domain, stamp = stamp}):up(); -- XEP-0203
		stanza:tag("x", {xmlns = "jabber:x:delay", from = muc_domain, stamp = datetime.legacy()}):up(); -- XEP-0091 (deprecated)
		local entry = { stanza = stanza, stamp = stamp, from = from };
		if replace then -- XEP-308, so we wipe from history
			local id = stanza.attr.id;
			local rid = replace.attr.id;
			if rid and id ~= rid then
				for i, entry in ripairs(history) do
					if from == entry.from and rid == entry.stanza.attr.id then t_remove(history, i); break; end
				end
			end
			removeElem(stanza, "replace");
			removeElem(stanza.tags, "replace");
		end
		t_insert(history, entry);
		while #history > self._data.history_length do t_remove(history, 1) end
	end
end
function room_mt:broadcast_except_nick(stanza, nick)
	for rnick, occupant in pairs(self._occupants) do
		if rnick ~= nick then
			for jid in pairs(occupant.sessions) do
				stanza.attr.to = jid;
				self:_route_stanza(stanza);
			end
		end
	end
end

function room_mt:send_occupant_list(to)
	local current_nick = self._jid_nick[to];
	for occupant, o_data in pairs(self._occupants) do
		if occupant ~= current_nick then
			local pres = get_filtered_presence(o_data.sessions[o_data.jid]);
			pres.attr.to, pres.attr.from = to, occupant;
			pres:tag("x", {xmlns = "http://jabber.org/protocol/muc#user"})
				:tag("item", {affiliation = o_data.affiliation or "none", role = o_data.role or "none"}):up();
			self:_route_stanza(pres);
		end
	end
end
function room_mt:send_history(to, stanza)
	local history = self._data["history"]; -- send discussion history
	local history_length = self._data.history_length;
	if history then
		local x_tag = stanza and stanza:get_child("x", "http://jabber.org/protocol/muc");
		local history_tag = x_tag and x_tag:get_child("history", "http://jabber.org/protocol/muc");
		
		local maxchars = history_tag and tonumber(history_tag.attr.maxchars);
		if maxchars then maxchars = math.floor(maxchars); end
		
		local maxstanzas = math.floor(history_tag and tonumber(history_tag.attr.maxstanzas) or #history);
		if not history_tag then maxstanzas = 20; end

		if maxstanzas > history_length then maxstanzas = history_length end

		local seconds = history_tag and tonumber(history_tag.attr.seconds);
		if seconds then seconds = datetime.datetime(os.time() - math.floor(seconds)); end

		local since = history_tag and history_tag.attr.since;
		if since then since = datetime.parse(since); since = since and datetime.datetime(since); end
		if seconds and (not since or since < seconds) then since = seconds; end

		local n = 0;
		local charcount = 0;
		
		for i=#history,1,-1 do
			local entry = history[i];
			if maxchars then
				if not entry.chars then
					entry.stanza.attr.to = "";
					entry.chars = #tostring(entry.stanza);
				end
				charcount = charcount + entry.chars + #to;
				if charcount > maxchars then break; end
			end
			if since and since > entry.stamp then break; end
			if n + 1 > maxstanzas then break; end
			n = n + 1;
		end
		for i=#history-n+1,#history do
			local msg = history[i].stanza;
			msg.attr.to = to;
			self:_route_stanza(msg);
		end
	end
	if self._data["subject"] then
		self:_route_stanza(st.message({type = "groupchat", from = self._data["subject_from"] or self.jid, to = to}):tag("subject"):text(self._data["subject"]));
	end
end

function room_mt:get_disco_info(stanza)
	local count = 0; for _ in pairs(self._occupants) do count = count + 1; end
	return st.reply(stanza):query("http://jabber.org/protocol/disco#info")
		:tag("identity", {category = "conference", type = "text", name = self:get_name()}):up()
		:tag("feature", {var = "http://jabber.org/protocol/muc"}):up()
		:tag("feature", {var = self:get_option("password") and "muc_passwordprotected" or "muc_unsecured"}):up()
		:tag("feature", {var = self:get_option("moderated") and "muc_moderated" or "muc_unmoderated"}):up()
		:tag("feature", {var = self:get_option("members_only") and "muc_membersonly" or "muc_open"}):up()
		:tag("feature", {var = self:get_option("persistent") and "muc_persistent" or "muc_temporary"}):up()
		:tag("feature", {var = not self:get_option("public") and "muc_hidden" or "muc_public"}):up()
		:tag("feature", {var = self._data.whois ~= "anyone" and "muc_semianonymous" or "muc_nonanonymous"}):up()
		:add_child(dataform.new({
			{ name = "FORM_TYPE", type = "hidden", value = "http://jabber.org/protocol/muc#roominfo" },
			{ name = "muc#roominfo_description", label = "Description"},
			{ name = "muc#roominfo_occupants", label = "Number of occupants", value = tostring(count) }
		}):form({["muc#roominfo_description"] = self:get_option("description")}, "result"))
	;
end
function room_mt:get_disco_items(stanza)
	local reply = st.reply(stanza):query("http://jabber.org/protocol/disco#items");
	for room_jid in pairs(self._occupants) do
		reply:tag("item", {jid = room_jid, name = room_jid:match("/(.*)")}):up();
	end
	return reply;
end
function room_mt:set_subject(current_nick, subject)
	if subject == "" then subject = nil; end
	self._data["subject"] = subject;
	self._data["subject_from"] = current_nick;
	if self.save then self:save(); end
	local msg = st.message({type = "groupchat", from = current_nick})
		:tag("subject"):text(subject):up();
	self:broadcast_message(msg, false);
	return true;
end

local function build_unavailable_presence_from_error(stanza)
	local type, condition, text = stanza:get_error();
	local error_message = "Kicked: "..(condition and condition:gsub("%-", " ") or "presence error");
	if text then
		error_message = error_message..": "..text;
	end
	return st.presence({type = "unavailable", from = stanza.attr.from, to = stanza.attr.to})
		:tag("status"):text(error_message);
end

-- config handlers
function room_mt:get_name()
	return self._data.name or jid_section(self.jid, "node");
end

function room_mt:get_option(name)
	return self._data[name];
end

function room_mt:set_option(name, value, changed)
	if type(value) == "string" and value == "" then value = nil; end
	if value == false then value = nil; end

	if value ~= self:get_option(name) then
		self._data[name] = value;
		if changed then 
			changed[name] = true;
		end
		return true;
	end

	return false;
end

local function construct_stanza_id(room, stanza)
	local from_jid, to_nick = stanza.attr.from, stanza.attr.to;
	local from_nick = room._jid_nick[from_jid];
	local occupant = room._occupants[to_nick];
	local to_jid = occupant.jid;
	
	return from_nick, to_jid, base64.encode(to_jid.."\0"..stanza.attr.id.."\0"..md5(from_jid));
end
local function deconstruct_stanza_id(room, stanza)
	local from_jid_possiblybare, to_nick = stanza.attr.from, stanza.attr.to;
	local from_jid, id, to_jid_hash = (base64.decode(stanza.attr.id) or ""):match("^(.+)%z(.*)%z(.+)$");
	local from_nick = room._jid_nick[from_jid];

	if not(from_nick) then return; end
	if not(from_jid_possiblybare == from_jid or from_jid_possiblybare == jid_bare(from_jid)) then return; end

	local occupant = room._occupants[to_nick];
	for to_jid in pairs(occupant and occupant.sessions or {}) do
		if md5(to_jid) == to_jid_hash then
			return from_nick, to_jid, id;
		end
	end
end

function room_mt:handle_to_occupant(origin, stanza) -- PM, vCards, etc
	local from, to = stanza.attr.from, stanza.attr.to;
	local room = jid_bare(to);
	local current_nick = self._jid_nick[from];
	local type = stanza.attr.type;
	if (jid_section(from, "host") == muc_domain) then error("Presence from the MUC itself!!!"); end
	if stanza.name == "presence" then
		local pr = get_filtered_presence(stanza);
		pr.attr.from = current_nick;
		if type == "error" then -- error, kick em out!
			if current_nick then
				log("debug", "kicking %s from %s", current_nick, room);
				self:handle_to_occupant(origin, build_unavailable_presence_from_error(stanza));
			end
		elseif type == "unavailable" then -- unavailable
			if current_nick then
				log("debug", "%s leaving %s", current_nick, room);
				self._jid_nick[from] = nil;
				local occupant = self._occupants[current_nick];
				local sessions = occupant.sessions;
				local new_jid = next(sessions);
				if new_jid == from then new_jid = next(sessions, new_jid); end
				if new_jid then
					local jid = occupant.jid;
					occupant.jid = new_jid;
					sessions[from] = nil;
					pr.attr.to = from;
					pr:tag("x", {xmlns = "http://jabber.org/protocol/muc#user"})
						:tag("item", {affiliation = occupant.affiliation or "none", role = "none"}):up()
						:tag("status", {code = "110"}):up();
					module:fire_event("muc-occupant-part-presence", self, pr, origin);
					self:_route_stanza(pr);
					if jid ~= new_jid then
						pr = st.clone(sessions[new_jid])
							:tag("x", {xmlns = "http://jabber.org/protocol/muc#user"})
							:tag("item", {affiliation = occupant.affiliation or "none", role = occupant.role or "none"});
						pr.attr.from = current_nick;
						self:broadcast_except_nick(pr, current_nick);
					end
				else
					occupant.role = "none";
					module:fire_event("muc-occupant-part-presence", self, pr, origin);
					self:broadcast_presence(pr, from);
					self._occupants[current_nick] = nil;
				end
				module:fire_event("muc-occupant-part", self.jid, from, current_nick, next(sessions, next(sessions)) and true);
			end
		elseif not type then -- available
			if current_nick then
				--if #pr == #stanza or current_nick ~= to then -- commented because google keeps resending directed presence
					if current_nick == to then -- simple presence
						log("debug", "%s broadcasted presence", current_nick);
						self._occupants[current_nick].sessions[from] = pr;
						self:broadcast_presence(pr, from);
					else -- change nick
						local occupant = self._occupants[current_nick];
						local is_multisession = next(occupant.sessions, next(occupant.sessions));
						if self._occupants[to] or is_multisession then
							log("debug", "%s couldn't change nick", current_nick);
							local reply = st.error_reply(stanza, "cancel", "conflict"):up();
							reply.tags[1].attr.code = "409";
							origin.send(reply:tag("x", {xmlns = "http://jabber.org/protocol/muc"}));
						else
							local data = self._occupants[current_nick];
							local to_nick = jid_section(to, "resource");
							if to_nick then
								log("debug", "%s (%s) changing nick to %s", current_nick, data.jid, to);
								local p = st.presence({type = "unavailable", from = current_nick});
								self:broadcast_presence(p, from, "303", to_nick);
								self._occupants[current_nick] = nil;
								self._occupants[to] = data;
								self._jid_nick[from] = to;
								pr.attr.from = to;
								self._occupants[to].sessions[from] = pr;
								self:broadcast_presence(pr, from);
								module:fire_event("muc-occupant-nick-change", self.jid, from, current_nick, to);
							else
								log("debug", "%s sent a malformed nick change request!", current_nick);
								origin.send(st.error_reply(stanza, "cancel", "jid-malformed"));
							end
						end
					end
				--else -- possible rejoin
				--	log("debug", "%s had connection replaced", current_nick);
				--	self:handle_to_occupant(origin, st.presence({type = "unavailable", from = from, to = to})
				--		:tag("status"):text("Replaced by new connection"):up()); -- send unavailable
				--	self:handle_to_occupant(origin, stanza); -- resend available
				--end
			else -- enter room
				local new_nick = to;
				local is_merge;
				if self._occupants[to] then
					if jid_bare(from) ~= jid_bare(self._occupants[to].jid) or origin.is_anonymous then
						new_nick = nil;
					end
					is_merge = true;
				end
				local password = stanza:get_child("x", "http://jabber.org/protocol/muc");
				password = password and password:get_child("password", "http://jabber.org/protocol/muc");
				password = password and password[1] ~= "" and password[1];
				if self:get_option("password") and self:get_option("password") ~= password and not admin_toggles[jid_bare(from)] then
					log("debug", "%s couldn't join due to invalid password: %s", from, to);
					local reply = st.error_reply(stanza, "auth", "not-authorized"):up();
					reply.tags[1].attr.code = "401";
					origin.send(reply:tag("x", {xmlns = "http://jabber.org/protocol/muc"}));
				elseif not new_nick then
					log("debug", "%s couldn't join due to nick conflict: %s", from, to);
					local reply = st.error_reply(stanza, "cancel", "conflict"):up();
					reply.tags[1].attr.code = "409";
					origin.send(reply:tag("x", {xmlns = "http://jabber.org/protocol/muc"}));
				else
					log("debug", "%s joining as %s", from, to);
					if not next(self._affiliations) then -- new room, no owners
						self._affiliations[jid_bare(from)] = "owner";
					end
					local affiliation = self:get_affiliation(from);
					local role = self:get_default_role(affiliation)
					if role then -- new occupant
						if not is_merge then
							self._occupants[to] = {affiliation=affiliation, role=role, jid=from, sessions={[from]=get_filtered_presence(stanza)}};
						else
							self._occupants[to].sessions[from] = get_filtered_presence(stanza);
						end
						self._jid_nick[from] = to;
						self:send_occupant_list(from);
						pr.attr.from = to;
						pr:tag("x", {xmlns = "http://jabber.org/protocol/muc#user"})
							:tag("item", {affiliation = affiliation or "none", role = role or "none"}):up();
						if not is_merge then
							self:broadcast_except_nick(pr, to);
						end
						if self._data.whois == "anyone" then pr:tag("status", {code = "100"}):up(); end
						pr:tag("status", {code = "110"}):up();
						module:fire_event("muc-occupant-join-presence", self, pr, origin);
						pr.attr.to = from;
						self:_route_stanza(pr);
						self:send_history(from, stanza);
						module:fire_event("muc-occupant-join", self.jid, from, to);
					elseif not affiliation then -- registration required for entering members-only room
						local reply = st.error_reply(stanza, "auth", "registration-required"):up();
						reply.tags[1].attr.code = "407";
						origin.send(reply:tag("x", {xmlns = "http://jabber.org/protocol/muc"}));
					else -- banned
						local reply = st.error_reply(stanza, "auth", "forbidden"):up();
						reply.tags[1].attr.code = "403";
						origin.send(reply:tag("x", {xmlns = "http://jabber.org/protocol/muc"}));
					end
				end
			end
		elseif type ~= "result" then -- bad type
			if type ~= "visible" and type ~= "invisible" then -- COMPAT ejabberd can broadcast or forward XEP-0018 presences
				origin.send(st.error_reply(stanza, "modify", "bad-request")); -- FIXME correct error?
			end
		end
	elseif not current_nick then -- not in room
		if (type == "error" or type == "result") and stanza.name == "iq" then
			local id = stanza.attr.id;
			stanza.attr.from, stanza.attr.to, stanza.attr.id = deconstruct_stanza_id(self, stanza);
			if stanza.attr.id then self:_route_stanza(stanza); end
			stanza.attr.from, stanza.attr.to, stanza.attr.id = from, to, id;
		else
			if type ~= "error" then origin.send(st.error_reply(stanza, "cancel", "not-acceptable")); end
		end
	elseif stanza.name == "message" and type == "groupchat" then -- groupchat messages not allowed in PM
		origin.send(st.error_reply(stanza, "modify", "bad-request"));
	elseif current_nick and stanza.name == "message" and type == "error" and is_kickable_error(stanza) then
		log("debug", "%s kicked from %s for sending an error message", current_nick, self.jid);
		self:handle_to_occupant(origin, build_unavailable_presence_from_error(stanza)); -- send unavailable
	else -- private stanza
		local o_data = self._occupants[to];
		if o_data then
			log("debug", "%s sent private stanza to %s (%s)", from, to, o_data.jid);
			if stanza.name == "iq" then
				local id = stanza.attr.id;
				if stanza.attr.type == "get" or stanza.attr.type == "set" then
					stanza.attr.from, stanza.attr.to, stanza.attr.id = construct_stanza_id(self, stanza);
				else
					stanza.attr.from, stanza.attr.to, stanza.attr.id = deconstruct_stanza_id(self, stanza);
				end
				if type == "get" and stanza.tags[1].attr.xmlns == "vcard-temp" then
					stanza.attr.to = jid_bare(stanza.attr.to);
				end
				if stanza.attr.id then self:_route_stanza(stanza); end
				stanza.attr.from, stanza.attr.to, stanza.attr.id = from, to, id;
			else -- message
				stanza.attr.from = current_nick;
				for jid in pairs(o_data.sessions) do
					stanza.attr.to = jid;
					self:_route_stanza(stanza);
				end
				stanza.attr.from, stanza.attr.to = from, to;
			end
		elseif type ~= "error" and type ~= "result" then -- recipient not in room
			origin.send(st.error_reply(stanza, "cancel", "item-not-found", "Recipient not in room"));
		end
	end
end

function room_mt:send_form(origin, stanza)
	origin.send(st.reply(stanza):query("http://jabber.org/protocol/muc#owner")
		:add_child(self:get_form_layout():form())
	);
end

function room_mt:get_form_layout()
	local title = "Configuration for "..self.jid;
	local layout = {
		title = title,
		instructions = title,
		{
			name = "FORM_TYPE",
			type = "hidden",
			value = "http://jabber.org/protocol/muc#roomconfig"
		},
		{
			name = "muc#roomconfig_roomname",
			type = "text-single",
			label = "Name",
			value = self:get_option("name") or "",
		},
		{
			name = "muc#roomconfig_roomdesc",
			type = "text-single",
			label = "Description",
			value = self:get_option("description") or "",
		},
		{
			name = "muc#roomconfig_persistentroom",
			type = "boolean",
			label = "Make Room Persistent?",
			value = self:get_option("persistent")
		},
		{
			name = "muc#roomconfig_publicroom",
			type = "boolean",
			label = "Make Room Publicly Searchable?",
			value = not self:get_option("public")
		},
		{
			name = "muc#roomconfig_changesubject",
			type = "boolean",
			label = "Allow Occupants to Change Subject?",
			value = self:get_option("changesubject")
		},
		{
			name = "muc#roomconfig_whois",
			type = "list-single",
			label = "Who May Discover Real JIDs?",
			value = {
				{ value = "moderators", label = "Moderators Only", default = self._data.whois == "moderators" },
				{ value = "anyone",     label = "Anyone",          default = self._data.whois == "anyone" }
			}
		},
		{
			name = "muc#roomconfig_roomsecret",
			type = "text-private",
			label = "Password",
			value = self:get_option("password") or ""
		},
		{
			name = "muc#roomconfig_moderatedroom",
			type = "boolean",
			label = "Make Room Moderated?",
			value = self:get_option("moderated")
		},
		{
			name = "muc#roomconfig_membersonly",
			type = "boolean",
			label = "Make Room Members-Only?",
			value = self:get_option("members_only")
		},
		{
			name = "muc#roomconfig_historylength",
			type = "text-single",
			label = "Maximum Number of History Messages Returned by Room",
			value = tostring(self:get_option("history_length"))
		}
	};
	module:fire_event("muc-fields", self, layout);

	return dataform.new(layout);
end

local valid_whois = {
	moderators = true,
	anyone = true,
}

function room_mt:process_form(origin, stanza)
	local query = stanza.tags[1];
	local form;
	for _, tag in ipairs(query.tags) do if tag.name == "x" and tag.attr.xmlns == "jabber:x:data" then form = tag; break; end end
	if not form then origin.send(st.error_reply(stanza, "cancel", "service-unavailable")); return; end
	if form.attr.type == "cancel" then origin.send(st.reply(stanza)); return; end
	if form.attr.type ~= "submit" then origin.send(st.error_reply(stanza, "cancel", "bad-request", "Not a submitted form")); return; end

	local fields = self:get_form_layout():data(form);
	if fields.FORM_TYPE ~= "http://jabber.org/protocol/muc#roomconfig" then origin.send(st.error_reply(stanza, "cancel", "bad-request", "Form is not of type room configuration")); return; end

	fields.FORM_TYPE = nil;
	local changed = {};

	-- Process default entries
	local name = fields["muc#roomconfig_roomname"];
	if name == jid_section(self.jid, "node") then name = nil; end

	local history_length = tonumber(fields["muc#roomconfig_historylength"]);
	if history_length and history_length > max_history_length then
		return origin.send(st.error_reply(stanza, "cancel", "bad-request", "History length value cannot exceed "..tostring(max_history_length)));
	end

	local whois = fields["muc#roomconfig_whois"];
	if not valid_whois[whois] then
		return origin.send(st.error_reply(stanza, "cancel", "bad-request", "Invalid value for 'whois'"));
	end
	
	self:set_option("name", name, changed);
	self:set_option("description", fields["muc#roomconfig_roomdesc"], changed);
	self:set_option("persistent", fields["muc#roomconfig_persistentroom"], changed);
	self:set_option("moderated", fields["muc#roomconfig_moderatedroom"], changed);
	self:set_option("members_only", fields["muc#roomconfig_membersonly"], changed);
	self:set_option("hidden", not fields["muc#roomconfig_publicroom"], changed);
	self:set_option("changesubject", fields["muc#roomconfig_changesubject"], changed);
	self:set_option("history_length", history_length or default_history_length, changed);
	local whois_changed = self:set_option("whois", fields["muc#roomconfig_whois"], changed);
	self:set_option("password", fields["muc#roomconfig_roomsecret"], changed);

	-- Process custom entries
	local invalid = module:fire_event("muc-fields-process", self, fields, stanza, changed);
	if invalid then return origin.send(invalid); end
	
	if self.save then self:save(true); end
	origin.send(st.reply(stanza));

	if next(changed) then
		local msg = st.message({type = "groupchat", from = self.jid})
			:tag("x", {xmlns = "http://jabber.org/protocol/muc#user"}):up()

		msg.tags[1]:tag("status", {code = "104"}):up();

		if whois_changed then
			local code = (whois == "moderators") and "173" or "172";
			msg.tags[1]:tag("status", {code = code}):up();
		end

		module:fire_event("muc-fields-submitted", self, msg);
		self:broadcast_message(msg, false);
	end
end

function room_mt:destroy(newjid, reason, password)
	local pr = st.presence({type = "unavailable"})
		:tag("x", {xmlns = "http://jabber.org/protocol/muc#user"})
			:tag("item", { affiliation = "none", role = "none" }):up()
			:tag("destroy", {jid = newjid})
	if reason then pr:tag("reason"):text(reason):up(); end
	if password then pr:tag("password"):text(password):up(); end
	for nick, occupant in pairs(self._occupants) do
		pr.attr.from = nick;
		for jid in pairs(occupant.sessions) do
			pr.attr.to = jid;
			self:_route_stanza(pr);
			self._jid_nick[jid] = nil;
		end
		self._occupants[nick] = nil;
	end
	module:fire_event("muc-room-destroyed",
		{ room = self, data = { newjid = newjid, reason = reason, password = password } }
	);
	if self:set_option("persistent", false) and self.save then self:save(true); end
end

function room_mt:handle_to_room(origin, stanza) -- presence changes and groupchat messages, along with disco/etc
	local type = stanza.attr.type;
	local xmlns = stanza.tags[1] and stanza.tags[1].attr.xmlns;
	if stanza.name == "iq" then
		if xmlns == "http://jabber.org/protocol/disco#info" and type == "get" then
			if stanza.tags[1].attr.node then
				origin.send(st.error_reply(stanza, "cancel", "feature-not-implemented"));
			else
				origin.send(self:get_disco_info(stanza));
			end
		elseif xmlns == "http://jabber.org/protocol/disco#items" and type == "get" then
			origin.send(self:get_disco_items(stanza));
		elseif xmlns == "http://jabber.org/protocol/muc#admin" then
			local actor = stanza.attr.from;
			local affiliation = self:get_affiliation(actor);
			local current_nick = self._jid_nick[actor];
			local role = current_nick and self._occupants[current_nick].role or self:get_default_role(affiliation);
			local item = stanza.tags[1].tags[1];
			if item and item.name == "item" then
				if type == "set" then
					local callback = function() origin.send(st.reply(stanza)); end
					if item.attr.jid then -- Validate provided JID
						item.attr.jid = jid_prep(item.attr.jid);
						if not item.attr.jid then
							origin.send(st.error_reply(stanza, "modify", "jid-malformed"));
							return;
						end
					end
					if not item.attr.jid and item.attr.nick then -- COMPAT Workaround for Miranda sending 'nick' instead of 'jid' when changing affiliation
						local occupant = self._occupants[self.jid.."/"..item.attr.nick];
						if occupant then item.attr.jid = occupant.jid; end
					elseif not item.attr.nick and item.attr.jid then
						local nick = self._jid_nick[item.attr.jid];
						if nick then item.attr.nick = jid_section(nick, "resource"); end
					end
					local reason = item.tags[1] and item.tags[1].name == "reason" and #item.tags[1] == 1 and item.tags[1][1];
					if item.attr.affiliation and item.attr.jid and not item.attr.role then
						local success, errtype, err = self:set_affiliation(actor, item.attr.jid, item.attr.affiliation, callback, reason);
						if not success then origin.send(st.error_reply(stanza, errtype, err)); end
					elseif item.attr.role and item.attr.nick and not item.attr.affiliation then
						local success, errtype, err = self:set_role(actor, self.jid.."/"..item.attr.nick, item.attr.role, callback, reason);
						if not success then origin.send(st.error_reply(stanza, errtype, err)); end
					else
						origin.send(st.error_reply(stanza, "cancel", "bad-request"));
					end
				elseif type == "get" then
					local _aff = item.attr.affiliation;
					local _rol = item.attr.role;
					if _aff and not _rol then
						if affiliation == "owner" or (affiliation == "admin" and _aff ~= "owner" and _aff ~= "admin") then
							local reply = st.reply(stanza):query("http://jabber.org/protocol/muc#admin");
							for jid, affiliation in pairs(self._affiliations) do
								if affiliation == _aff then
									reply:tag("item", {affiliation = _aff, jid = jid}):up();
								end
							end
							origin.send(reply);
						else
							origin.send(st.error_reply(stanza, "auth", "forbidden"));
						end
					elseif _rol and not _aff then
						if role == "moderator" then
							-- TODO allow admins and owners not in room? Provide read-only access to everyone who can see the participants anyway?
							if _rol == "none" then _rol = nil; end
							local reply = st.reply(stanza):query("http://jabber.org/protocol/muc#admin");
							for occupant_jid, occupant in pairs(self._occupants) do
								if occupant.role == _rol then
									reply:tag("item", {
										nick = jid_section(occupant_jid, "resource"),
										role = _rol or "none",
										affiliation = occupant.affiliation or "none",
										jid = occupant.jid
										}):up();
								end
							end
							origin.send(reply);
						else
							origin.send(st.error_reply(stanza, "auth", "forbidden"));
						end
					else
						origin.send(st.error_reply(stanza, "cancel", "bad-request"));
					end
				end
			elseif type == "set" or type == "get" then
				origin.send(st.error_reply(stanza, "cancel", "bad-request"));
			end
		elseif xmlns == "http://jabber.org/protocol/muc#owner" and (type == "get" or type == "set") and stanza.tags[1].name == "query" then
			if self:get_affiliation(stanza.attr.from) ~= "owner" then
				origin.send(st.error_reply(stanza, "auth", "forbidden", "Only owners can configure rooms"));
			elseif stanza.attr.type == "get" then
				self:send_form(origin, stanza);
			elseif stanza.attr.type == "set" then
				local child = stanza.tags[1].tags[1];
				if not child then
					origin.send(st.error_reply(stanza, "modify", "bad-request"));
				elseif child.name == "destroy" then
					local newjid = child.attr.jid;
					local reason, password;
					for _,tag in ipairs(child.tags) do
						if tag.name == "reason" then
							reason = #tag.tags == 0 and tag[1];
						elseif tag.name == "password" then
							password = #tag.tags == 0 and tag[1];
						end
					end
					self:destroy(newjid, reason, password);
					origin.send(st.reply(stanza));
				else
					self:process_form(origin, stanza);
				end
			end
		elseif type == "set" or type == "get" then
			origin.send(st.error_reply(stanza, "cancel", "service-unavailable"));
		end
	elseif stanza.name == "message" and type == "groupchat" then
		local from, to = stanza.attr.from, stanza.attr.to;
		local current_nick = self._jid_nick[from];
		local occupant = self._occupants[current_nick];
		if not occupant then -- not in room
			origin.send(st.error_reply(stanza, "cancel", "not-acceptable"));
		elseif occupant.role == "visitor" then
			origin.send(st.error_reply(stanza, "auth", "forbidden"));
		else
			local from = stanza.attr.from;
			stanza.attr.from = current_nick;
			local subject = getText(stanza, {"subject"});
			if subject then
				if occupant.role == "moderator" or
					( self._data.changesubject and occupant.role == "participant" ) then -- and participant
					self:set_subject(current_nick, subject); -- TODO use broadcast_message_stanza
				else
					stanza.attr.from = from;
					origin.send(st.error_reply(stanza, "auth", "forbidden"));
				end
			else
				self:broadcast_message(stanza, self:get_option("history_length") > 0, from);
			end
			stanza.attr.from = from;
		end
	elseif stanza.name == "message" and type == "error" and is_kickable_error(stanza) then
		local current_nick = self._jid_nick[stanza.attr.from];
		if current_nick then
			log("debug", "%s kicked from %s for sending an error message", current_nick, self.jid);
			self:handle_to_occupant(origin, build_unavailable_presence_from_error(stanza)); -- send unavailable
		end
	elseif stanza.name == "presence" then -- hack - some buggy clients send presence updates to the room rather than their nick
		local to = stanza.attr.to;
		local current_nick = self._jid_nick[stanza.attr.from];
		if current_nick then
			stanza.attr.to = current_nick;
			self:handle_to_occupant(origin, stanza);
			stanza.attr.to = to;
		elseif type ~= "error" and type ~= "result" then
			origin.send(st.error_reply(stanza, "cancel", "service-unavailable"));
		end
	elseif stanza.name == "message" and not stanza.attr.type and #stanza.tags == 1 and 
	       stanza.tags[1].name == "x" and stanza.tags[1].attr.xmlns == "http://jabber.org/protocol/muc#user" then
		local x = stanza.tags[1];
		local payload = (#x.tags == 1 and x.tags[1]);
		if payload and (payload.name == "invite" or payload.name == "decline") and payload.attr.to then
			local _from, _to = stanza.attr.from, stanza.attr.to;
			local _recipient = jid_prep(payload.attr.to);
			if _recipient then
				local _reason = payload:get_child_text("reason");
				local invite, decline;
				local _from_bare, _inviter = jid_bare(_from), self._jid_nick[_from];
				if payload.name == "invite" and _inviter then
					invite = st.message({from = _to, to = _recipient, id = stanza.attr.id})
						:tag("x", {xmlns = "http://jabber.org/protocol/muc#user"})
							:tag("invite", {from = _from})
							if _reason then
								invite:tag("reason"):text(_reason):up();
							end
							invite:up();
							if self:get_option("password") then
								invite:tag("password"):text(self:get_option("password")):up();
							end
						invite:up()
						:tag("x", {xmlns = "jabber:x:conference", jid = _to}) -- COMPAT: Some older clients expect this
							:text(_reason or "")
						:up()
						:tag("body") -- Add a plain message for clients which don't support invites
							:text(_from.." invited you to the room ".._to..(_reason and (" (".._reason..")") or ""))
						:up();
					if self:get_option("members_only") and not self:get_affiliation(_recipient) then
						log("debug", "%s invited %s into members only room %s, granting membership", _from, _recipient, _to);
						self:set_affiliation(_from, _recipient, "member", nil, "Invited by " .. self._jid_nick[_from]);
					end
					if self._occupants[_inviter] then
						if not self._invites then self._invites = {}; end
						self._invites[_recipient] = _from;
						add_timer(60, function()
							if self._invites then
								self._invites[_recipient] = nil;
								if not next(self._invites) then self._invites = nil; end
							end
						end);
					end 
				elseif payload.name == "decline" and self._invites then
					_recipient = self._invites[_from] or self._invites[_from_bare];
					if not self._jid_nick[_recipient] then return; end
					-- Work around buggy clients sending declines to the room jid
					decline = st.message({from = _to, to = _recipient, id = stanza.attr.id})
						:tag("x", {xmlns = "http://jabber.org/protocol/muc#user"})
							:tag("decline", {from = _from});
							if _reason then
								decline:tag("reason"):text(_reason):up();
							end
						decline:up():up()
						:tag("body") -- Add a plain message for clients which don"t support formal declines
							:text(_from.." declined your invite to the room ".._to..(_reason and (" (".._reason..")") or ""))
						:up();
					self._invites[_from] = nil;
				else
					return;
				end
				self:_route_stanza(invite or decline);
			else
				origin.send(st.error_reply(stanza, "cancel", "jid-malformed"));
			end
		else
			origin.send(st.error_reply(stanza, "cancel", "bad-request"));
		end
	elseif stanza.name ~= "iq" and type ~= "error" then
		origin.send(st.error_reply(stanza, "cancel", "service-unavailable"));
	end
end

function room_mt:handle_stanza(origin, stanza)
	local to_node, to_host, to_resource = jid_split(stanza.attr.to);
	local name, type = stanza.name, stanza.attr.type;
	if to_resource then
		self:handle_to_occupant(origin, stanza);
	else
		if name == "iq" and (type ~= "error" and type ~= "result") or name ~= "iq" then
			self:handle_to_room(origin, stanza);
		else
			log("debug", "discarding iq %s sent to %s from %s", type, stanza.attr.to, stanza.attr.from);
		end
	end
end

function room_mt:route_stanza(stanza) end

function room_mt:get_affiliation(jid)
	local node, host = jid_split(jid);
	local bare = node and node.."@"..host or host;
	local result = self._affiliations[bare]; -- Affiliations are granted, revoked, and maintained based on the user's bare JID.
	if not result and self._affiliations[host] == "outcast" then result = "outcast"; end -- host banned
	return result;
end

function room_mt:is_affiliated(jid)
	jid = jid_bare(jid);
	local affiliation = self._affiliations[jid];
	if affiliation then
		return (affiliation ~= "outcast" and true);
	end
	return nil;
end

function room_mt:set_affiliation(actor, jid, affiliation, callback, reason, dummy)
	jid = jid_bare(jid);
	if affiliation == "none" then affiliation = nil; end
	if affiliation and affiliation ~= "outcast" and affiliation ~= "owner" and affiliation ~= "admin" and affiliation ~= "member" then
		return nil, "modify", "not-acceptable";
	end
	if actor ~= true then
		local actor_affiliation = self:get_affiliation(actor);
		local target_affiliation = self:get_affiliation(jid);
		if target_affiliation == affiliation then -- no change, shortcut
			if callback then callback(); end
			return true;
		end
		if actor_affiliation ~= "owner" then
			if actor_affiliation ~= "admin" or target_affiliation == "owner" or target_affiliation == "admin" or
			   (not dummy and (affiliation == "owner" or affiliation == "admin")) then
				return nil, "cancel", "not-allowed";
			end
		elseif target_affiliation == "owner" and jid_bare(actor) == jid then -- self change
			local is_last = true;
			for j, aff in pairs(self._affiliations) do if j ~= jid and aff == "owner" then is_last = false; break; end end
			if is_last then
				return nil, "cancel", "conflict";
			end
		end
	end
	if not dummy then
		self._affiliations[jid] = affiliation; 
	else
		if dummy ~= "none" then affiliation = dummy; end
	end
	local role = self:get_default_role(affiliation);
	local x = st.stanza("x", {xmlns = "http://jabber.org/protocol/muc#user"})
			:tag("item", {affiliation=affiliation or "none", role=role or "none"})
				:tag("reason"):text(reason or ""):up()
			:up();
	local presence_type = nil;
	if not role then -- getting kicked
		presence_type = "unavailable";
		if affiliation == "outcast" then
			x:tag("status", {code="301"}):up(); -- banned
		else
			x:tag("status", {code="321"}):up(); -- affiliation change
		end
	end
	local modified_nicks = {};
	for nick, occupant in pairs(self._occupants) do
		if jid_bare(occupant.jid) == jid then
			if not role then -- getting kicked
				self._occupants[nick] = nil;
			else
				occupant.affiliation, occupant.role = affiliation, role;
			end
			for jid,pres in pairs(occupant.sessions) do -- remove for all sessions of the nick
				if not role then self._jid_nick[jid] = nil; end
				local p = st.clone(pres);
				p.attr.from = nick;
				p.attr.type = presence_type;
				p.attr.to = jid;
				p:add_child(x);
				self:_route_stanza(p);
				if occupant.jid == jid then
					modified_nicks[nick] = p;
				end
			end
		end
	end
	if self.save then self:save(); end
	if callback then callback(); end
	for nick,p in pairs(modified_nicks) do
		p.attr.from = nick;
		self:broadcast_except_nick(p, nick);
	end
	return true;
end

function room_mt:get_role(nick)
	local session = self._occupants[nick];
	return session and session.role or nil;
end
function room_mt:can_set_role(actor_jid, occupant_jid, role)
	if actor_jid == true then return true; end

	local actor = self._occupants[self._jid_nick[actor_jid]];
	local occupant = self._occupants[occupant_jid];
	
	if not occupant or not actor then return nil, "modify", "not-acceptable"; end

	if actor.role == "moderator" then
		if occupant.affiliation ~= "owner" and occupant.affiliation ~= "admin" then
			if actor.affiliation == "owner" or actor.affiliation == "admin" then
				return true;
			elseif occupant.role ~= "moderator" and role ~= "moderator" then
				return true;
			end
		end
	end
	return nil, "cancel", "not-allowed";
end
function room_mt:set_role(actor, occupant_jid, role, callback, reason)
	if role == "none" then role = nil; end
	if role and role ~= "moderator" and role ~= "participant" and role ~= "visitor" then return nil, "modify", "not-acceptable"; end
	local allowed, err_type, err_condition = self:can_set_role(actor, occupant_jid, role);
	if not allowed then return allowed, err_type, err_condition; end
	local occupant = self._occupants[occupant_jid];
	local x = st.stanza("x", {xmlns = "http://jabber.org/protocol/muc#user"})
			:tag("item", {affiliation=occupant.affiliation or "none", nick=jid_section(occupant_jid, "resource"), role=role or "none"})
				:tag("reason"):text(reason or ""):up()
			:up();
	local presence_type = nil;
	if not role then -- kick
		presence_type = "unavailable";
		self._occupants[occupant_jid] = nil;
		for jid in pairs(occupant.sessions) do -- remove for all sessions of the nick
			self._jid_nick[jid] = nil;
		end
		x:tag("status", {code = "307"}):up();
	else
		occupant.role = role;
	end
	local bp;
	for jid,pres in pairs(occupant.sessions) do -- send to all sessions of the nick
		local p = st.clone(pres);
		p.attr.from = occupant_jid;
		p.attr.type = presence_type;
		p.attr.to = jid;
		p:add_child(x);
		self:_route_stanza(p);
		if occupant.jid == jid then
			bp = p;
		end
	end
	if callback then callback(); end
	if bp then
		self:broadcast_except_nick(bp, occupant_jid);
	end
	return true;
end

function room_mt:_route_stanza(stanza)
	local muc_child;
	local to_occupant = self._occupants[self._jid_nick[stanza.attr.to]];
	local from_occupant = self._occupants[stanza.attr.from];
	if stanza.name == "presence" then
		if to_occupant and from_occupant then
			if self._data.whois == "anyone" then
			    muc_child = stanza:get_child("x", "http://jabber.org/protocol/muc#user");
			else
				if to_occupant.role == "moderator" or jid_bare(to_occupant.jid) == jid_bare(from_occupant.jid) then
					muc_child = stanza:get_child("x", "http://jabber.org/protocol/muc#user");
				end
			end
		end
	end
	if muc_child then
		for _, item in pairs(muc_child.tags) do
			if item.name == "item" then
				if from_occupant == to_occupant then
					item.attr.jid = stanza.attr.to;
				else
					item.attr.jid = from_occupant.jid;
				end
			end
		end
	end
	self:route_stanza(stanza);
	if muc_child then
		for _, item in pairs(muc_child.tags) do
			if item.name == "item" then
				item.attr.jid = nil;
			end
		end
	end
end

local _M = {}; -- module "muc"

function _M.new_room(jid)
	return setmetatable({
		jid = jid;
		_jid_nick = {};
		_occupants = {};
		_data = {
		    whois = "moderators";
		    history_length = default_history_length;
		};
		_affiliations = {};
	}, room_mt);
end

function _M.set_max_history(limit)
	max_history_length = limit;
end

_M.admin_toggles = admin_toggles;
_M.room_mt = room_mt;

return _M;
