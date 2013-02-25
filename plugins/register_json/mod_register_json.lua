local jid_prep = require "util.jid".prep
local jid_split = require "util.jid".split
local usermanager = usermanager
local b64_decode = require "util.encodings".base64.decode
local json_decode = require "util.json".decode
local os_time = os.time
local nodeprep = require "util.encodings".stringprep.nodeprep
local uuid_gen = require "util.uuid".generate
local timer = require "util.timer";
local open = io.open;

module:depends("http")

-- Pick up configuration.

local auth_token = module:get_option_string("reg_servlet_auth_token")
local secure = module:get_option_boolean("reg_servlet_secure", true)
local set_realm_name = module:get_option_string("reg_servlet_realm", "Restricted")
local base_path = module:get_option_string("reg_servlet_base", "/register_account/")
local throttle_time = module:get_option_number("reg_servlet_ttime", nil)
local whitelist = module:get_option_set("reg_servlet_wl", {})
local blacklist = module:get_option_set("reg_servlet_bl", {})
local http_event = require "net.http.server".fire_server_event
local urldecode = http.urldecode

local recent_ips = {}
local pending = {}
local pending_node = {}

local files_base = module.path:gsub("/[^/]+$","") .. "/template/";

-- Begin
local function handle(code, message) return http_event("http-error", { code = code, message = message }) end
local function http_response(event, code, message, headers)
	local response = event.response

	if headers then
		for header, data in pairs(headers) do response.headers[header] = data end
	end

	response:send(handle(code, message))
end

local function handle_req(event)
	local response = event.response
	local request = event.request
	local body = request.body
	if secure and not request.secure then return nil end

	if request.method ~= "POST" then
		return http_response(event, 405, "Bad method.", {["Allow"] = "POST"})
	end
	
	local req_body
	-- We check that what we have is valid JSON wise else we throw an error...
	if not pcall(function() req_body = json_decode(b64_decode(body)) end) then
		module:log("debug", "Data submitted for user registration by %s failed to Decode.", user)
		return http_response(event, 400, "Decoding failed.")
	else
		-- Decode JSON data and check that all bits are there else throw an error
		if req_body["username"] == nil or req_body["password"] == nil or req_body["host"] == nil or req_body["ip"] == nil or
		   req_body["auth_token"] == nil then
			module:log("debug", "%s supplied an insufficent number of elements or wrong elements for the JSON registration", user)
			return http_response(event, 400, "Invalid syntax.")
		end
		-- Check if user is an admin of said host
		if req_body["auth_token"] ~= auth_token then
			module:log("warn", "%s tried to retrieve a registration token for %s@%s", request.ip, req_body["username"], req_body["host"])
			return http_response(event, 401, "Auth token is invalid! The attempt has been logged.")
		else	
			-- Blacklist can be checked here.
			if blacklist:contains(req_body["ip"]) then module:log("warn", "Attempt of reg. submission to the JSON servlet from blacklisted address: %s", req_body["ip"]) ; return http_response(403, "The specified address is blacklisted, sorry.") end

			-- We first check if the supplied username for registration is already there.
			-- And nodeprep the username
			local username = nodeprep(req_body["username"])
			if not username then
				module:log("debug", "%s supplied an username containing invalid characters: %s", user, username)
				return http_response(event, 406, "Supplied username contains invalid characters, see RFC 6122.")
			else
				if pending_node[username] then
					module:log("warn", "%s attempted to submit a registration request but another request for that user is pending")
					return http_response(event, 401, "Another user registration by that username is pending.")
				end

				if not usermanager.user_exists(username, req_body["host"]) then
					-- if username fails to register successive requests shouldn't be throttled until one is successful.
					if throttle_time and not whitelist:contains(req_body["ip"]) then
						if not recent_ips[req_body["ip"]] then
							recent_ips[req_body["ip"]] = os_time()
						else 
							if os_time() - recent_ips[req_body["ip"]] < throttle_time then
								recent_ips[req_body["ip"]] = os_time()
								module:log("warn", "JSON Registration request from %s has been throttled.", req_body["ip"])
								return http_response(event, 503, "Request throttled, wait a bit and try again.")
							end
							recent_ips[req_body["ip"]] = os_time()
						end
					end

					local uuid = uuid_gen()
					pending[uuid] = { node = username, host = req_body["host"], password = req_body["password"], ip = req_body["ip"] }
					pending_node[username] = uuid

					timer.add_task(300, function() pending[uuid] = nil ; pending_node[username] = nil end)
					return uuid
				else
					module:log("debug", "%s registration data submission for %s failed (user already exists)", user, username)
					return http_response(event, 409, "User already exists.")
				end
			end
		end
	end
end

local function open_file(file)
	local f, err = open(file, "rb");
	if not f then return nil end

	local data = f:read("*a") ; f:close()
	return data
end

local function r_template(event, type)
	local response = event.response

	local data = open_file(files_base..type.."_t.html")
	if data then
		data = data:gsub("%%REG%-URL", base_path.."verify/")
		return data
	else return http_response(event, 500, "Failed to obtain template.") end
end

local function handle_verify(event, path)
	local response = event.response
	local request = event.request
	local body = request.body
	if secure and not request.secure then return nil end

	local valid_files = {
		["css/style.css"] = files_base.."css/style.css",
		["images/haze_orange.png"] = files_base.."images/haze_orange.png",
		["images/metronome.png"] = files_base.."images/metronome.png"
	}

	if request.method == "GET" then
		if path == "" then
			return r_template(event, "form")
		end		

		if valid_files[path] then
			local data = open_file(valid_files[path])
			if data then return data
			else return http_response(event, 404, "Not found.") end
		end
	elseif request.method == "POST" then
		if path == "" then
			if not request.body then return http_response(event, 400, "Bad Request.") end
			local uuid = urldecode(request.body):match("^uuid=(.*)$")

			if not pending[uuid] then
				return r_template(event, "fail")
			else
				local username, host, password, ip = 
				      pending[uuid].node, pending[uuid].host, pending[uuid].password, pending[uuid].ip

				local ok, error = usermanager.create_user(username, password, host)
				if ok then 
					hosts[host].events.fire_event(
						"user-registered", 
						{ username = username, host = host, source = "mod_register_json", session = { ip = ip } }
					)
					module:log("debug", "Registration for %s@%s is successfully verified and registered", username, host)
					-- we shall not clean the user from the pending lists as long as registration doesn't succeed.
					pending[uuid] = nil ; pending_node[username] = nil
					return r_template(event, "success")				
				else
					module:log("error", "User creation failed: "..error)
					return http_response(event, 500, "Encountered server error while creating the user: "..error)
				end
			end
		end	
	else
		return http_response(event, 405, "Invalid method.")
	end
end

-- Set it up!

module:provides("http", {
	default_path = base_path,
        route = {
                ["GET /"] = handle_req,
		["POST /"] = handle_req,
		["GET /verify/*"] = handle_verify,
		["POST /verify/*"] = handle_verify
        }
})
