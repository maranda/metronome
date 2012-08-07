-- Expose a simple servlet to handle user registrations from web pages
-- via JSON.
--
-- A Good chunk of the code is from mod_data_access.lua by Kim Alvefur
-- aka Zash.

local jid_prep = require "util.jid".prep
local jid_split = require "util.jid".split
local usermanager = usermanager
local b64_decode = require "util.encodings".base64.decode
local json_decode = require "util.json".decode
local os_time = os.time
local nodeprep = require "util.encodings".stringprep.nodeprep

module:depends("http")

-- Pick up configuration.

local secure = module:get_option_boolean("reg_servlet_secure", true)
local set_realm_name = module:get_option_string("reg_servlet_realm", "Restricted")
local base_path = module:get_option_string("reg_servlet_base", "/register_account/")
local throttle_time = module:get_option_number("reg_servlet_ttime", nil)
local whitelist = module:get_option_set("reg_servlet_wl", {})
local blacklist = module:get_option_set("reg_servlet_bl", {})
local recent_ips = {}

-- Begin

local function http_response(event, code, message, headers)
	local response = event.response

	if headers then
		for header, data in pairs(headers) do response.headers[header] = data end
	end

	response.headers.content_type = "application/json"
	response.status_code = code
	response:send(message)
end

local function handle_req(event)
	local request = event.request
	local body = request.body

	if request.method ~= "POST" then
		return http_response(event, 405, "Bad method...", {["Allow"] = "POST"})
	end
	if not request.headers["authorization"] then
		return http_response(event, 401, "No... No...", {["WWW-Authenticate"]='Basic realm="'.. set_realm_name ..'"'})
	end
	
	local user, password = b64_decode(request.headers.authorization:match("[^ ]*$") or ""):match("([^:]*):(.*)")
	user = jid_prep(user)
	if not user or not password then return http_response(event, 400, "What's this..?") end
	local user_node, user_host = jid_split(user)
	if not hosts[user_host] then return http_response(event, 401, "Negative.") end
	
	module:log("warn", "%s is authing to submit a new user registration data", user)
	if not usermanager.test_password(user_node, user_host, password) then
		module:log("warn", "%s failed authentication", user)
		return http_response(event, 401, "Who the hell are you?! Guards!")
	end
	
	local req_body
	-- We check that what we have is valid JSON wise else we throw an error...
	if not pcall(function() req_body = json_decode(body) end) then
		module:log("debug", "JSON data submitted for user registration by %s failed to Decode.", user)
		return http_response(event, 400, "JSON Decoding failed.")
	else
		-- Decode JSON data and check that all bits are there else throw an error
		req_body = json_decode(body)
		if req_body["username"] == nil or req_body["password"] == nil or req_body["host"] == nil or req_body["ip"] == nil then
			module:log("debug", "%s supplied an insufficent number of elements or wrong elements for the JSON registration", user)
			return http_response(event, 400, "Invalid syntax.")
		end
		-- Check if user is an admin of said host
		if not usermanager.is_admin(user, req_body["host"]) then
			module:log("warn", "%s tried to submit registration data for %s but he's not an admin", user, req_body["host"])
			return http_response(event, 401, "I obey only to my masters... Have a nice day.")
		else	
			-- Blacklist can be checked here.
			if blacklist:contains(req_body["ip"]) then module:log("warn", "Attempt of reg. submission to the JSON servlet from blacklisted address: %s", req_body["ip"]) ; return http_response(403, "The specified address is blacklisted, sorry sorry.") end

			-- We first check if the supplied username for registration is already there.
			-- And nodeprep the username
			local username = nodeprep(req_body["username"])
			if not username then
				module:log("debug", "%s supplied an username containing invalid characters: %s", user, username)
				return http_response(event, 406, "Supplied username contains invalid characters, see RFC 6122.")
			else
				if not usermanager.user_exists(username, req_body["host"]) then
					-- if username fails to register successive requests shouldn't be throttled until one is successful.
					if throttle_time and not whitelist:contains(req_body["ip"]) then
						if not recent_ips[req_body["ip"]] then
							recent_ips[req_body["ip"]] = os_time()
						else
							if os_time() - recent_ips[req_body["ip"]] < throttle_time then
								recent_ips[req_body["ip"]] = os_time()
								module:log("warn", "JSON Registration request from %s has been throttled.", req_body["ip"])
								return http_response(event, 503, "Woah... How many users you want to register..? Request throttled, wait a bit and try again.")
							end
							recent_ips[req_body["ip"]] = os_time()
						end
					end

					local ok, error = usermanager.create_user(username, req_body["password"], req_body["host"])
					if ok then 
						hosts[req_body["host"]].events.fire_event("user-registered", { username = username, host = req_body["host"], source = "mod_register_json", session = { ip = req_body["ip"] } })
						module:log("debug", "%s registration data submission for %s@%s is successful", user, username, req_body["host"])
						return http_response(event, 200, "Done.")
					else
						module:log("error", "user creation failed: "..error)
						return http_response(event, 500, "Encountered server error while creating the user: "..error)
					end
				else
					module:log("debug", "%s registration data submission for %s failed (user already exists)", user, username)
					return http_response(event, 409, "User already exists.")
				end
			end
		end
	end
end

-- Set it up!

module:provides("http", {
	default_path = base_path,
        route = {
                ["GET /"] = handle_req,
		["POST /"] = handle_req
        }
})
