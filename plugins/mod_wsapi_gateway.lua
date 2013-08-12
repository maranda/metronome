-- * Metronome IM *
--
-- This file is part of the Metronome XMPP server and is released under the
-- ISC License, please see the LICENSE file in this source package for more
-- information.

local pairs, pcall, setmetatable, string = pairs, pcall, setmetatable, string
local wsapi_run = require "wsapi.common".run
local loadfile = require "util.envload".envloadfile

wrapper = false;
local simple = module:get_option_string("wsapi_wrapper")

if simple then
	wrapper = loadfile(simple);
end

if not wrapper then error("You need to specify the wrapper") end

local base_path = module:get_option_string("wsapi_path", "wsapi")

module:depends("http")

-- Module Definitions

local function build_cgi_request(request)
	-- this builds the environment for WSAPI
	local headers = request.headers

	local env = {
		HTTPS = request.secure and "on" or nil,
		QUERY_STRING = request.url.query,
		PATH_INFO = request.path,
		METHOD = request.method,
		REQUEST_METHOD = request.method
	}

	for header, data in pairs(request.headers) do
		env["HTTP_"..header:upper()] = data
	end
	
	setmetatable(env, {
		__index = function(t, k) return rawget(t, string.upper(k)) end
	})
	return env
end

local function io_object(content) -- private method from wsapi mockups
	local rec = { buffer = content or "", bytes_read = 0 }

	function rec:write(content)
		if content then
			self.buffer = self.buffer .. content
		end
	end

	function rec:read(len)
		len = len or (#self.buffer - self.bytes_read)
		if self.bytes_read >= #self.buffer then return nil end
		local s = self.buffer:sub(self.bytes_read + 1, len)
		self.bytes_read = self.bytes_read + len
		if self.bytes_read > #self.buffer then self.bytes_read = #self.buffer end
		return s
	end

	function rec:clear()
		self.buffer = ""
		self.bytes_read = 0
	end

	function rec:reset()
		self.bytes_read = 0
	end

	return rec
end

local function wsapi_request(app, event)
	local request_body = event.request.body ~= "" and event.request.body
	local env = build_cgi_request(event.request)
	local ret = {}

	local wsapi_env = { env = env, input = request_body and io_object(request_body) or io_object(), output = io_object(), error = io_object() }

	ret.code, ret.headers = wsapi_run(app, wsapi_env)
	ret.body = wsapi_env.output:read()
	ret.errors = wsapi_env.error:read()
	return ret, wsapi_env.env
end

local function handler(event)
	local response, request = event.response, event.request
	local wsapi_ret = wsapi_request(wrapper, event)

	response.code = wsapi_ret.code
	if wsapi_ret.errors then
		response.body = wsapi_ret.errors
		return response:send()
	end
	
	response.body = wsapi_ret.body
	return response:send()
end

module:provides("http", {
	default_path = base_path,
        route = {
                ["GET /*"] = handler
        }
})
