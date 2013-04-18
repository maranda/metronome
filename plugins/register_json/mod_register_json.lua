local datamanager = datamanager
local b64_decode = require "util.encodings".base64.decode
local b64_encode = require "util.encodings".base64.encode
local http_event = require "net.http.server".fire_server_event
local jid_prep = require "util.jid".prep
local jid_split = require "util.jid".split
local json_decode = require "util.json".decode
local nodeprep = require "util.encodings".stringprep.nodeprep
local open = io.open
local os_time = os.time
local setmt = setmetatable
local sha1 = require "util.hashes".sha1
local urldecode = http.urldecode
local usermanager = usermanager
local uuid_gen = require "util.uuid".generate
local timer = require "util.timer"

module:depends("http")

-- Pick up configuration and setup stores/variables.

local auth_token = module:get_option_string("reg_servlet_auth_token")
local secure = module:get_option_boolean("reg_servlet_secure", true)
local set_realm_name = module:get_option_string("reg_servlet_realm", "Restricted")
local base_path = module:get_option_string("reg_servlet_base", "/register_account/")
local throttle_time = module:get_option_number("reg_servlet_ttime", nil)
local whitelist = module:get_option_set("reg_servlet_wl", {})
local blacklist = module:get_option_set("reg_servlet_bl", {})

local files_base = module.path:gsub("/[^/]+$","") .. "/template/"

local recent_ips = {}
local pending = {}
local pending_node = {}

-- Setup hashes data structure

hashes = { _index = {} }
local hashes_mt = {} ; hashes_mt.__index = hashes_mt
function hashes_mt:add(node, mail)
	local _hash = b64_encode(sha1(mail))
	if not self:exists(_hash) then
		self[_hash] = node ; self._index[node] = _hash ; self:save()
		return true
	else
		return false
	end
end
function hashes_mt:exists(hash)
	if hashes[hash] then return true else return false end
end
function hashes_mt:remove(node)
	local _hash = self._index[node]
	if _hash then
		self[_hash] = nil ; self._index[node] = nil ; self:save()
	end
end
function hashes_mt:save()
	if not datamanager.store("register_json", module.host, "hashes", hashes) then
		module:log("error", "Failed to save the mail addresses' hashes store.")
	end
end

-- Begin

local function handle(code, message) return http_event("http-error", { code = code, message = message }) end
local function http_response(event, code, message, headers)
	local response = event.response

	if headers then
		for header, data in pairs(headers) do response.headers[header] = data end
	end

	response.status_code = code
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
		if req_body["username"] == nil or req_body["password"] == nil or req_body["ip"] == nil or req_body["mail"] == nil or
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
				module:log("debug", "An username containing invalid characters was supplied: %s", req_body["username"])
				return http_response(event, 406, "Supplied username contains invalid characters, see RFC 6122.")
			else
				if pending_node[username] then
					module:log("warn", "%s attempted to submit a registration request but another request for that user is pending")
					return http_response(event, 401, "Another user registration by that username is pending.")
				end

				if not usermanager.user_exists(username, module.host) then
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
					if not hashes:add(username, req_body["mail"]) then
						module:log("warn", "%s (%s) attempted to register to the server with an E-Mail address we already possess the hash of.", username, req_body["ip"])
						return http_response(event, 409, "The E-Mail Address provided matches the hash associated to an existing account.")
					end
					pending[uuid] = { node = username, password = req_body["password"], ip = req_body["ip"] }
					pending_node[username] = uuid

					timer.add_task(300, function()
						if pending[uuid] then
							pending[uuid] = nil
							pending_node[username] = nil
							hashes:remove(username)
						end
					end)
					module:log("info", "%s (%s) submitted a registration request and is awaiting final verification", username, uuid)
					return uuid
				else
					module:log("debug", "%s registration data submission failed (user already exists)", username)
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
				local username, password, ip = 
				      pending[uuid].node, pending[uuid].password, pending[uuid].ip

				local ok, error = usermanager.create_user(username, password, module.host)
				if ok then 
					module:fire_event(
						"user-registered", 
						{ username = username, host = module.host, source = "mod_register_json", session = { ip = ip } }
					)
					module:log("info", "Account %s@%s is successfully verified and activated", username, module.host)
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

local function handle_user_deletion(event)
	local user, hostname = event.username, event.host
	if hostname == module.host then hashes:remove(user) end
end

-- Set it up!

hashes = datamanager.load("register_json", module.host, "hashes") or hashes ; setmt(hashes, hashes_mt)

module:provides("http", {
	default_path = base_path,
        route = {
                ["GET /"] = handle_req,
		["POST /"] = handle_req,
		["GET /verify/*"] = handle_verify,
		["POST /verify/*"] = handle_verify
        }
})

module:hook_global("user-deleted", handle_user_deletion, 10);

-- Reloadability

module.save = function() return { hashes = hashes } end
module.restore = function(data) hashes = data.hashes or { _index = {} } ; setmt(hashes, hashes_mt) end
