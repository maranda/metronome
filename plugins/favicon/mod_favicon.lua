-- * Metronome IM *
--
-- This file is part of the Metronome XMPP server and is released under the
-- ISC License, please see the LICENSE file in this source package for more
-- information about copyright and licensing.

module:depends("http")

local favicon = module:get_option_string("favicon_path", (metronome.paths.plugins or "./").."favicon/favicon.ico")
local open = io.open

local function reload()
	favicon = module:get_option_string("favicon_path", (metronome.paths.plugins or "./").."favicon/favicon.ico")
end

local function serve_icon(event)
	local response = event.response
        local file = open(favicon, "rb") ; local icon
	if file then icon = file:read("*a") ; file:close() else module:log("error","Meow, where's the one and only <<piccie>>!") end

        if not icon then 
		response.status_code = 500
		response.headers.content_type = "text/html"
		response:send("<html><head><title>I can't read it.</title></head><body>:(</body></html>")
	else
		response.headers.content_type = "image/x-icon"
        	response:send(icon)
	end	
end

module:provides("http", {
	default_path = "/favicon.ico",
        route = {
                ["GET"] = serve_icon
        }
})
