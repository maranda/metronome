-- * Metronome IM *
--
-- This file is part of the Metronome XMPP server and is released under the
-- ISC License, please see the LICENSE file in this source package for more
-- information about copyright and licensing.

module:set_global()

local server = require "net.http.server"

local favicon_file_path = (metronome.paths.plugins or "./").."favicon/favicon."
local load = require "util.auxiliary".load_file

local function get_icon(event, type)
	local response = event.response
    local icon = load(favicon_file_path .. type, "rb")

	if not icon then
		return 404
	else
		if type == "ico" then type = "x-icon" end
		response.headers["Content-Type"] = "image/" .. type
		response:send(icon)
	end

	return true
end

local function serve(event)
	local type = event.request.path:match("%.([^%.]*)$")
	return get_icon(event, type)
end

function module.add_host(module)
	module:hook_object_event(server, "GET "..module.host.."/favicon.ico", serve, -1)
	module:hook_object_event(server, "GET "..module.host.."/assets/favicon.png", serve, -1)
end
