-- * Metronome IM *
--
-- This file is part of the Metronome XMPP server and is released under the
-- ISC License, please see the LICENSE file in this source package for more
-- information about copyright and licensing.

local st = require "util.stanza";
local os_getenv = os.getenv;

module:add_feature("jabber:iq:version");

local version;

local query = st.stanza("query", {xmlns = "jabber:iq:version"})
	:tag("name"):text("Metronome"):up()
	:tag("version"):text(metronome.version):up();

local random_osv_cmd = module:get_option_string("refresh_random_osv_cmd");
local log_requests = module:get_option_boolean("log_version_requests", true);

if not module:get_option_boolean("hide_os_type") and not random_osv_cmd then
	local os_version_command = module:get_option_string("os_version_command");
	local ok, pposix = pcall(require, "util.pposix");
	if not os_version_command and (ok and pposix and pposix.uname) then
		version = pposix.uname().sysname;
	end
	if not version then
		local uname = io.popen(os_version_command or "uname");
		if uname then
			version = uname:read("*a");
		end
		uname:close();
	end
	if version then
		version = version:match("^%s*(.-)%s*$") or version;
		query:tag("os"):text(version):up();
	end
end

module:hook("iq/host/jabber:iq:version:query", function(event)
	local stanza = event.stanza;
	if stanza.attr.type == "get" and stanza.attr.to == module.host then
		local _query;
		if random_osv_cmd then
			random_string = io.popen(random_osv_cmd);
			version = random_string and random_string:read("*a"); version = version and version:match("^%s*(.-)%s*$") or version;
			random_string:close();
			_query = st.clone(query):tag("os"):text(version):up();
		end
		if log_requests then module:log("info", "%s requested the version of the server software, sending response...", stanza.attr.from); end
		event.origin.send(st.reply(stanza):add_child(_query or query));
		return true;
	end
end);
