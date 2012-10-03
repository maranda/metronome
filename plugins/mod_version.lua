local st = require "util.stanza";

module:add_feature("jabber:iq:version");

local version;

local query = st.stanza("query", {xmlns = "jabber:iq:version"})
	:tag("name"):text("Metronome"):up()
	:tag("version"):text(metronome.version):up();

local random_osv_cmd = module:get_option_string("refresh_random_osv_cmd");

if not module:get_option_boolean("hide_os_type") and not random_osv_cmd then
	if os.getenv("WINDIR") then
		version = "Windows";
	else
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
		event.origin.send(st.reply(stanza):add_child(_query or query));
		return true;
	end
end);
