-- * Metronome IM *
--
-- This file is part of the Metronome XMPP server and is released under the
-- ISC License, please see the LICENSE file in this source package for more
-- information about copyright and licensing.

local st = require "util.stanza";
local s2s_make_authenticated = require "util.s2smanager".make_authenticated;
local base64 = require "util.encodings".base64;
local cert_verify_identity = require "util.x509".verify_identity;

local xmlns_sasl = "urn:ietf:params:xml:ns:xmpp-sasl";

local function build_error(err)
	local reply = st.stanza("failure", {xmlns = xmlns_sasl});
	reply:tag(err):up();
	return reply;
end

local success = st.stanza("success", {xmlns = xmlns_sasl});
local function s2s_auth(session, stanza)
	local mechanism = stanza.attr.mechanism;

	if not session.secure then
		if mechanism == "EXTERNAL" then
			session.sends2s(build_error("encryption-required"));
		else
			session.sends2s(build_error("invalid-mechanism"));
		end
		return true;
	end

	if mechanism ~= "EXTERNAL" or session.cert_chain_status ~= "valid" then
		session.sends2s(build_error("invalid-mechanism"));
		return true;
	end

	local text = stanza[1];
	if not text then
		session.sends2s(build_error("malformed-request"));
		return true;
	end

	-- Either the value is "=" and we've already verified the external
	-- cert identity, or the value is a string and either matches the
	-- from_host

	text = base64.decode(text);
	if not text then
		session.sends2s(build_error("incorrect-encoding"));
		return true;
	end

	if session.cert_identity_status == "valid" then
		if text ~= "" and text ~= session.from_host then
			session.sends2s(build_error("invalid-authzid"));
			return true;
		end
	else
		if text == "" then
			session.sends2s(build_error("invalid-authzid"));
			return true;
		end

		local cert = session.conn:socket():getpeercertificate();
		if (cert_verify_identity(text, "xmpp-server", cert)) then
			session.cert_identity_status = "valid";
		else
			session.cert_identity_status = "invalid";
			session.sends2s(build_error("invalid-authzid"));
			return true;
		end
	end

	session.external_auth = "succeeded";

	if not session.from_host then session.from_host = text; end
	session.sends2s(success);

	local domain = text ~= "" and text or session.from_host;
	module:log("info", "Accepting SASL EXTERNAL identity from %s", domain);
	s2s_make_authenticated(session, domain);
	session:reset_stream();
	return true
end

module:hook_stanza(xmlns_sasl, "success", function (session, stanza)
	if session.type ~= "s2sout_unauthed" or session.external_auth ~= "attempting" then return; end
	module:log("debug", "SASL EXTERNAL with %s succeeded", session.to_host);
	session.external_auth = "succeeded"
	session:reset_stream();
	session:open_stream();
	s2s_make_authenticated(session, session.to_host);
	return true;
end)

module:hook_stanza(xmlns_sasl, "failure", function (session, stanza)
	if session.type ~= "s2sout_unauthed" or session.external_auth ~= "attempting" then return; end

	module:log("info", "SASL EXTERNAL with %s failed", session.to_host)
	session.external_auth = "failed"
end, 500)

module:hook_stanza(xmlns_sasl, "failure", function (session, stanza)
	session:close();
end, 90)

module:hook_stanza("http://etherx.jabber.org/streams", "features", function (session, stanza)
	if session.type ~= "s2sout_unauthed" or not session.secure then
		return; 
	end

	local mechanisms = stanza:get_child("mechanisms", xmlns_sasl);
	if mechanisms then
		for mech in mechanisms:childtags() do
			if mech[1] == "EXTERNAL" then
				module:log("debug", "Initiating SASL EXTERNAL with %s", session.to_host);
				local reply = st.stanza("auth", {xmlns = xmlns_sasl, mechanism = "EXTERNAL"});
				reply:text(base64.encode(session.from_host));
				session.sends2s(reply);
				session.external_auth = "attempting";
				return true;
			end
		end
	end
end, 150);

module:hook("stanza/urn:ietf:params:xml:ns:xmpp-sasl:auth", function(event)
	local session, stanza = event.origin, event.stanza;
	if session.type == "s2sin_unauthed" then
		return s2s_auth(session, stanza);
	end
end, 10);

module:hook("s2s-stream-features", function(event)
	local origin, features = event.origin, event.features;
	if origin.secure and origin.type == "s2sin_unauthed" then
		-- Offer EXTERNAL if chain is valid and either we didn't validate
		-- the identity or it passed.
		if origin.cert_chain_status == "valid" and origin.cert_identity_status ~= "invalid" then
			module:log("debug", "Offering SASL EXTERNAL")
			features:tag("mechanisms", { xmlns = xmlns_sasl })
				:tag("mechanism"):text("EXTERNAL")
			:up():up();
		end
	end
end, 99);
