local host = module:get_host();
local welcome_text = module:get_option("welcome_message") or "Hello $username, welcome to the $host IM server!";

local st = require "util.stanza";

module:hook("user-registered",
	function (user)
		local welcome_stanza =
			st.message({ to = user.username.."@"..user.host, from = host })
				:tag("body"):text(welcome_text:gsub("$(%w+)", user));
		module:send(welcome_stanza);
		module:log("debug", "Welcomed user %s@%s", user.username, user.host);
	end);
