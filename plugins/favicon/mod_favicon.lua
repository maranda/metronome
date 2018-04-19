-- * Metronome IM *
--
-- This file is part of the Metronome XMPP server and is released under the
-- ISC License, please see the LICENSE file in this source package for more
-- information about copyright and licensing.

module:set_global()

local server = require "net.http.server"

local favicon_file_path = metronome.paths.plugins or "./").."favicon/favicon.png"
local favicon_url = "/favicon.png"
local favicon_mime = "image/png"
local load = require "util.auxiliary".load_file

local function serve_icon(event)
	local response = event.response
    local icon = load(favicon_file_path, "rb")

	if not icon then
		module:log("error","Couldn't find favicon in %s", favicon_file_path)
		return 404
	else
		response.headers.content_type = favicon_mime
		return response:send(icon)
	end
end

function module.add_host(module)
	module:hook_object_event(server, "GET "..module.host..favicon_url, serve_icon, -1)
end
