-- * Metronome IM *
--
-- This file is part of the Metronome XMPP server and is released under the
-- ISC License, please see the LICENSE file in this source package for more
-- information about copyright and licensing.

local st = require "util.stanza";
local base64 = require "util.encodings".base64.encode;
local hmac_sha1 = require "util.hmac".sha1;
local datetime = require "util.datetime".datetime;
local ipairs, pairs, now, tostring = ipairs, pairs, os.time, tostring;

local relay_host = module:get_option_string("jingle_nodes_host", module.host);
local relay_stun = module:get_option_boolean("jingle_nodes_stun", true);
local relay_turn = module:get_option_boolean("jingle_nodes_turn", true);
local relay_tcp = module:get_option_boolean("jingle_nodes_tcp", true);
local relay_udp = module:get_option_boolean("jingle_nodes_udp", true);
local relay_port = module:get_option_number("jingle_nodes_port", 3478);
local turn_credentials = module:get_option_boolean("jingle_nodes_turn_credentials", false);
local turn_credentials_secret = module:get_options_string("jingle_nodes_turn_secret");
local turn_credentials_ttl = module:get_option_number("jingle_nodes_turn_credentials_ttl", 6200);

local xmlns = "http://jabber.org/protocol/jinglenodes";
local xmlns_credentials = "http://jabber.org/protocol/jinglenodes#turncredentials";

module:add_feature(xmlns);
if turn_credentials and turn_credentials_secret then module:add_feature(xmlns_credentials); end

local function generate_nonce()
	local user = now() + turn_credentials_ttl;
	local pass = base64(hmac_sha1(turn_credentials_secret, user, false));
	return tostring(user), pass;
end

module:hook("iq-get/host/"..xmlns..":services", function (event)
	local origin, stanza = event.origin, event.stanza;
	local reply = st.reply(stanza);
	reply:tag("services", { xmlns = xmlns });

	if relay_tcp then
		reply:tag("relay", { policy = "public", address = relay_host, protocol = "tcp" }):up()
		reply:tag("tracker", { policy = "public", address = relay_host, protocol = "tcp" }):up()
		reply:tag("turn", { policy = "public", address = relay_host, protocol = "tcp" }):up()
		reply:tag("stun", { policy = "public", address = relay_host, port = tostring(relay_port), protocol = "tcp" }):up()
	end
	if relay_udp then
		reply:tag("relay", { policy = "public", address = relay_host, protocol = "udp" }):up()
		reply:tag("tracker", { policy = "public", address = relay_host, protocol = "udp" }):up()
		reply:tag("turn", { policy = "public", address = relay_host, protocol = "udp" }):up()
		reply:tag("stun", { policy = "public", address = relay_host, port = tostring(relay_port), protocol = "udp" }):up()
	end

	module:log("debug", "%s queried for jingle relay nodes...", stanza.attr.from or origin.username.."@"..origin.host);
	origin.send(reply);
	return true;
end);

if turn_credentials and turn_credentials_secret then
	module:hook("iq-get/host/"..xmlns_credentials..":turn", function (event)
		local origin, stanza = event.origin, event.stanza;
		local turn = stanza:get_child("turn", xmlns_credentials);
		local protocol = turn and turn.attr.protocol;

		if not protocol then
			origin.send(st.error_reply(stanza, "modify", "bad-request", "Please specify the transport in the request"));
			return true;
		end

		if protocol == "tcp" and not relay_tcp then
			origin.send(st.error_reply(stanza, "cancel", "item-not-found", "TCP not supported"));
			return true;
		elseif protocol == "udp" and not relay_udp then
			origin.send(st.error_reply(stanza, "cancel", "item-not-found", "UDP not supported"));
			return true;
		end

		local user, pass = generate_nonce();

		local reply = st.reply(stanza);
		reply:tag("turn", {
			ttl = tostring(turn_credentials_ttl),
			uri = "turn:"..relay_host..":"..tostring(relay_port).."?transport="..protocol,
			username = user,
			password = pass,
		});
		
		module:log("debug", "%s queried %s turn credentials...", stanza.attr.from or origin.username.."@"..origin.host, protocol);
		origin.send(reply);
		return true;
	end);
end