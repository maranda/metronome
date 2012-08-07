-- (C) 2010-2011 Marco Cirillo (LW.Org)
-- (C) 2011 Kim Alvefur
--
-- Registration Redirect module for Prosody
-- 
-- Redirects IP addresses not in the whitelist to a web page or another method to complete the registration.

local st = require "util.stanza"
local cman = configmanager

function reg_redirect(event)
	local stanza, origin = event.stanza, event.origin
	local ip_wl = module:get_option("registration_whitelist") or { "127.0.0.1" }
	local url = module:get_option_string("registration_url", nil)
	local inst_text = module:get_option_string("registration_text", nil)
	local oob = module:get_option_boolean("registration_oob", true)
	local admins_g = cman.get("*", "core", "admins")
	local admins_l = cman.get(module:get_host(), "core", "admins")
	local no_wl = module:get_option_boolean("no_registration_whitelist", false)
	local test_ip = false

	if type(admins_g) ~= "table" then admins_g = nil end
	if type(admins_l) ~= "table" then admins_l = nil end

	-- perform checks to set default responses and sanity checks.
	if not inst_text then
		if url and oob then
			if url:match("^%w+[:].*$") then
				if url:match("^(%w+)[:].*$") == "http" or url:match("^(%w+)[:].*$") == "https" then
					inst_text = "Please visit "..url.." to register an account on this server."
				elseif url:match("^(%w+)[:].*$") == "mailto" then
					inst_text = "Please send an e-mail at "..url:match("^%w+[:](.*)$").." to register an account on this server."
				elseif url:match("^(%w+)[:].*$") == "xmpp" then
					inst_text = "Please contact "..module:get_host().."'s server administrator via xmpp to register an account on this server at: "..url:match("^%w+[:](.*)$")
				else
					module:log("error", "This module supports only http/https, mailto or xmpp as URL formats.")
					module:log("error", "If you want to use personalized instructions without an Out-Of-Band method,")
					module:log("error", "specify: register_oob = false; -- in your configuration along your banner string (register_text).")
					return origin.send(st.error_reply(stanza, "wait", "internal-server-error")) -- bouncing request.
				end
			else
				module:log("error", "Please check your configuration, the URL you specified is invalid")
				return origin.send(st.error_reply(stanza, "wait", "internal-server-error")) -- bouncing request.
			end
		else
			if admins_l then
				local ajid; for _,v in ipairs(admins_l) do ajid = v ; break end
				inst_text = "Please contact "..module:get_host().."'s server administrator via xmpp to register an account on this server at: "..ajid
			else
				if admins_g then
					local ajid; for _,v in ipairs(admins_g) do ajid = v ; break end
					inst_text = "Please contact "..module:get_host().."'s server administrator via xmpp to register an account on this server at: "..ajid
				else
					module:log("error", "Please be sure to, _at the very least_, configure one server administrator either global or hostwise...")
					module:log("error", "if you want to use this module, or read it's configuration wiki at: http://code.google.com/p/prosody-modules/wiki/mod_register_redirect")
					return origin.send(st.error_reply(stanza, "wait", "internal-server-error")) -- bouncing request.
				end
			end
		end
	elseif inst_text and url and oob then
		if not url:match("^%w+[:].*$") then
			module:log("error", "Please check your configuration, the URL specified is not valid.")
			return origin.send(st.error_reply(stanza, "wait", "internal-server-error")) -- bouncing request.
		end
	end

	if not no_wl then
		for i,ip in ipairs(ip_wl) do
			if origin.ip == ip then test_ip = true end
			break
		end
	end

	-- Prepare replies.
	local reply = st.reply(event.stanza)
	if oob then
		reply:query("jabber:iq:register")
			:tag("instructions"):text(inst_text):up()
			:tag("x", {xmlns = "jabber:x:oob"})
				:tag("url"):text(url);
	else
		reply:query("jabber:iq:register")
			:tag("instructions"):text(inst_text):up()
	end
	
	if stanza.attr.type == "get" then
		return origin.send(reply)
	else
		return origin.send(st.error_reply(stanza, "cancel", "not-authorized"))
	end
end

module:hook("stanza/iq/jabber:iq:register:query", reg_redirect, 10)
