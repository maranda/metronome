-- * Metronome IM *
--
-- This file is part of the Metronome XMPP server and is released under the
-- ISC License, please see the LICENSE file in this source package for more
-- information about copyright and licensing.
--
-- As per the sublicensing clause, this file is also MIT/X11 Licensed.
-- ** Copyright (c) 2008-2012, Kim Alvefur, Matthew Wild, Tobias Markmann, Waqas Hussain

if hosts[module.host].anonymous_host then
	module:log("error", "Rosters won't be available on anonymous hosts as storage is explicitly disabled");
	modulemanager.unload(module.host, "roster");
	return;
end

local st = require "util.stanza"

local jid_split = require "util.jid".split;
local jid_prep = require "util.jid".prep;
local jid_bare = require "util.jid".bare;
local t_concat = table.concat;
local tonumber = tonumber;
local pairs, ipairs = pairs, ipairs;

local hosts = hosts;

local rm_remove_from_roster = require "util.rostermanager".remove_from_roster;
local rm_add_to_roster = require "util.rostermanager".add_to_roster;
local rm_roster_push = require "util.rostermanager".roster_push;
local rm_load_roster = require "util.rostermanager".load_roster;
local rm_get_readonly_rosters = require "util.rostermanager".get_readonly_rosters;
local rm_get_readonly_item = require "util.rostermanager".get_readonly_item;

module:add_feature("jabber:iq:roster");

local rosterver_stream_feature = st.stanza("ver", {xmlns = "urn:xmpp:features:rosterver"});
module:hook("stream-features", function(event)
	local origin, features = event.origin, event.features;
	if origin.username then
		features:add_child(rosterver_stream_feature);
	end
end, -1);

local function roster_stanza_builder(stanza, roster, owner)
	for jid, item in pairs(roster) do
		if jid ~= "pending" and 
		   jid ~= "__readonly" and
		   jid ~= owner and jid then
			stanza:tag("item", {
				jid = jid,
				subscription = item.subscription,
				ask = item.ask,
				name = item.name,
			});
			for group in pairs(item.groups) do
				stanza:tag("group"):text(group):up();
			end
			stanza:up(); -- move out from item
		end
	end
end

module:hook("initialize-roster", function(event)
	local session = event.session;
	session.roster, err = rm_load_roster(session.username, session.host);
	return;
end, 100);

module:hook("iq/self/jabber:iq:roster:query", function(event)
	local session, stanza = event.origin, event.stanza;
	local session_roster = session.roster;
	local session_username, session_host = session.username, session.host;

	if stanza.attr.type == "get" then
		local bare_jid = session_username .. "@" .. session_host;
		local roster = st.reply(stanza);
		
		local client_ver = tonumber(stanza.tags[1].attr.ver);
		local server_ver = tonumber(session.roster[false].version or 1);
		
		if not (client_ver and server_ver) or client_ver ~= server_ver then
			-- Client does not support versioning, or has stale roster
			roster:query("jabber:iq:roster");

			-- Append read-only rosters, if there.
			for ro_roster in rm_get_readonly_rosters(session_username, session_host) do
				roster_stanza_builder(roster, ro_roster, bare_jid);
			end

			-- Now append the real one.
			roster_stanza_builder(roster, session_roster, bare_jid);		

			roster.tags[1].attr.ver = server_ver;
		end
		session.send(roster);
		session.interested = true; -- resource is interested in roster updates
	else -- stanza.attr.type == "set"
		local query = stanza.tags[1];
		if #query.tags == 1 and query.tags[1].name == "item"
				and query.tags[1].attr.xmlns == "jabber:iq:roster" and query.tags[1].attr.jid
				-- Protection against overwriting roster.pending, until we move it
				and query.tags[1].attr.jid ~= "pending" then
			local item = query.tags[1];
			local from_node, from_host = jid_split(stanza.attr.from);
			local from_bare = from_node and (from_node.."@"..from_host) or from_host; -- bare JID
			local jid = jid_prep(item.attr.jid);
			if rm_get_readonly_item(session_username, session_host, jid_bare(jid)) then
				module:log("debug", "%s attempted to remove a readonly roster entry (%s)", session.full_jid, jid);
				return session.send(st.error_reply(stanza, "cancel", "forbidden",
					"Modifying read-only roster entries is forbidden."));
			end
			local node, host, resource = jid_split(jid);
			if not resource and host then
				if jid ~= from_node.."@"..from_host then
					if item.attr.subscription == "remove" then
						local r_item = session_roster[jid];
						if r_item then
							local to_bare = node and (node.."@"..host) or host; -- bare JID
							if r_item.subscription == "both" or r_item.subscription == "from" or (session_roster.pending and session_roster.pending[jid]) then
								module:fire_global_event("route/post", session, st.presence({type="unsubscribed", from=session.full_jid, to=to_bare}));
							end
							if r_item.subscription == "both" or r_item.subscription == "to" or r_item.ask then
								module:fire_global_event("route/post", session, st.presence({type="unsubscribe", from=session.full_jid, to=to_bare}));
							end
							local success, err_type, err_cond, err_msg = rm_remove_from_roster(session, jid);
							if success then
								session.send(st.reply(stanza));
								rm_roster_push(from_node, from_host, jid);
							else
								session.send(st.error_reply(stanza, err_type, err_cond, err_msg));
							end
						else
							session.send(st.error_reply(stanza, "modify", "item-not-found"));
						end
					else
						local r_item = {name = item.attr.name, groups = {}};
						if r_item.name == "" then r_item.name = nil; end
						if session_roster[jid] then
							r_item.subscription = session_roster[jid].subscription;
							r_item.ask = session_roster[jid].ask;
						else
							r_item.subscription = "none";
						end
						for _, child in ipairs(item) do
							if child.name == "group" then
								local text = t_concat(child);
								if text and text ~= "" then
									r_item.groups[text] = true;
								end
							end
						end
						local success, err_type, err_cond, err_msg = rm_add_to_roster(session, jid, r_item);
						if success then
							-- Ok, send success
							session.send(st.reply(stanza));
							-- and push change to all resources
							rm_roster_push(from_node, from_host, jid);
						else
							-- Adding to roster failed
							session.send(st.error_reply(stanza, err_type, err_cond, err_msg));
						end
					end
				else
					-- Trying to add self to roster
					session.send(st.error_reply(stanza, "cancel", "not-allowed"));
				end
			else
				-- Invalid JID added to roster
				session.send(st.error_reply(stanza, "modify", "bad-request")); -- FIXME what's the correct error?
			end
		else
			-- Roster set didn't include a single item, or its name wasn't  'item'
			session.send(st.error_reply(stanza, "modify", "bad-request"));
		end
	end
	return true;
end);

function module.load() hosts[module.host].supports_rosters = true; end
function module.unload() hosts[module.host].supports_rosters = nil; end

module:hook("user-pre-delete", function(event)
	local username, host, _roster = event.username, event.host, event.session and event.session.roster;
	local bare = username.."@"..host;
	local roster = {};

	for key, value in pairs(_roster or rm_load_roster(username, host) or roster) do
		roster[key] = value;
	end

	module:log("info", "Broadcasting unsubscription stanzas to %s contacts as the account is getting deleted", bare);
	for jid, item in pairs(roster) do
		if jid and jid ~= "pending" then
			if item.subscription == "both" or item.subscription == "from" or (roster.pending and roster.pending[jid]) then
				module:send(st.presence({type="unsubscribed", from=bare, to=jid}));
			end
			if item.subscription == "both" or item.subscription == "to" or item.ask then
				module:send(st.presence({type="unsubscribe", from=bare, to=jid}));
			end
		end
	end
end);
