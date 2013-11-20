-- * Metronome IM *
--
-- This file is part of the Metronome XMPP server and is released under the
-- ISC License, please see the LICENSE file in this source package for more
-- information about copyright and licensing.

module:depends("http")

local favicon = module:get_option_string("favicon_path", (metronome.paths.plugins or "./").."favicon/favicon.ico")
local open = io.open

local function serve_icon(event)
	local response = event.response
        local file = open(favicon, "rb") ; local icon
	if file then icon = file:read("*a") ; file:close() else module:log("error","Couldn't find favicon in %s", favicon) end

        if not icon then 
		return 404
	else
		response.headers.content_type = "image/x-icon"
        	return response:send(icon)
	end	
end

module:provides("http", {
	default_path = "/favicon.ico",
        route = {
                ["GET"] = serve_icon
        }
})
