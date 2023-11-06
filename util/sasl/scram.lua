-- Please see sasl.lua.license for licensing information.

local s_match = string.match;
local type = type;
local base64 = require "util.encodings".base64;
local hmac_sha1 = require "util.hmac".sha1;
local hmac_sha256 = require "util.hmac".sha256;
local hmac_sha384 = require "util.hmac".sha384;
local hmac_sha512 = require "util.hmac".sha512;
local sha1 = require "util.hashes".sha1;
local sha256 = require "util.hashes".sha256;
local sha384 = require "util.hashes".sha384;
local sha512 = require "util.hashes".sha512;
local generate_uuid = require "util.uuid".generate;
local nodeprep = require "util.encodings".stringprep.nodeprep;
local saslprep = require "util.encodings".stringprep.saslprep;
local log = require "util.logger".init("sasl");
local t_concat = table.concat;
local char = string.char;
local byte = string.byte;

local _ENV = nil;

--[[
SASL SCRAM according to RFCs 5802 and 7677

Supported Authentication Backends

scram_{MECH}:
	-- MECH being a standard hash name (like those at IANA's hash registry) with '-' replaced with '_'
	function(username, realm)
		return stored_key, server_key, iteration_count, salt, state;
	end
]]

local default_i = 4096

local function bp( b )
	local result = ""
	for i=1, b:len() do
		result = result.."\\"..b:byte(i)
	end
	return result;
end

local xor_map = {0;1;2;3;4;5;6;7;8;9;10;11;12;13;14;15;1;0;3;2;5;4;7;6;9;8;11;10;13;12;15;14;2;3;0;1;6;7;4;5;10;11;8;9;14;15;12;13;3;2;1;0;7;6;5;4;11;10;9;8;15;14;13;12;4;5;6;7;0;1;2;3;12;13;14;15;8;9;10;11;5;4;7;6;1;0;3;2;13;12;15;14;9;8;11;10;6;7;4;5;2;3;0;1;14;15;12;13;10;11;8;9;7;6;5;4;3;2;1;0;15;14;13;12;11;10;9;8;8;9;10;11;12;13;14;15;0;1;2;3;4;5;6;7;9;8;11;10;13;12;15;14;1;0;3;2;5;4;7;6;10;11;8;9;14;15;12;13;2;3;0;1;6;7;4;5;11;10;9;8;15;14;13;12;3;2;1;0;7;6;5;4;12;13;14;15;8;9;10;11;4;5;6;7;0;1;2;3;13;12;15;14;9;8;11;10;5;4;7;6;1;0;3;2;14;15;12;13;10;11;8;9;6;7;4;5;2;3;0;1;15;14;13;12;11;10;9;8;7;6;5;4;3;2;1;0;};

local function binaryXOR( a, b )
	local result = {};
	for i=1, #a do
		local x, y = byte(a, i), byte(b, i);
		if not x or not y then return; end
		local lowx, lowy = x % 16, y % 16;
		local hix, hiy = (x - lowx) / 16, (y - lowy) / 16;
		local lowr, hir = xor_map[lowx * 16 + lowy + 1], xor_map[hix * 16 + hiy + 1];
		local r = hir * 16 + lowr;
		result[i] = char(r);
	end
	return t_concat(result);
end

-- hash algorithm independent Hi(PBKDF2) implementation
local function Hi(hmac, str, salt, i)
	local Ust = hmac(str, salt.."\0\0\0\1");
	local res = Ust;
	for n=1,i-1 do
		local Und = hmac(str, Ust);
		res = binaryXOR(res, Und);
		Ust = Und;
	end
	return res;
end

local function validate_username(username, _nodeprep)
	-- check for forbidden char sequences
	for eq in username:gmatch("=(.?.?)") do
		if eq ~= "2C" and eq ~= "3D" then
			return false;
		end
	end
	
	-- replace =2C with , and =3D with =
	username = username:gsub("=2C", ",");
	username = username:gsub("=3D", "=");
	
	-- apply SASLprep
	username = saslprep(username);

	-- apply NODEprep
	if username and _nodeprep ~= false then username = (_nodeprep or nodeprep)(username); end

	return username and #username>0 and username;
end

local function hashprep(hashname)
	return hashname:lower():gsub("-", "_");
end

local function getAuthenticationDatabase(hash_name, password, salt, iteration_count)
	if type(password) ~= "string" or type(salt) ~= "string" or type(iteration_count) ~= "number" then
		return false, "inappropriate argument types";
	end
	if iteration_count < 4096 then
		log("warn", "Iteration count < 4096 which is the suggested minimum according to RFCs.");
	end
	local salted_password, stored_key, server_key;
	if hash_name == "sha_256" then
		salted_password = Hi(hmac_sha256, password, salt, iteration_count);
		stored_key = sha256(hmac_sha256(salted_password, "Client Key"));
		server_key = hmac_sha256(salted_password, "Server Key");
	elseif hash_name == "sha_384" then
		salted_password = Hi(hmac_sha384, password, salt, iteration_count);
		stored_key = sha384(hmac_sha384(salted_password, "Client Key"));
		server_key = hmac_sha384(salted_password, "Server Key");
	elseif hash_name == "sha_512" then
		salted_password = Hi(hmac_sha512, password, salt, iteration_count);
		stored_key = sha512(hmac_sha512(salted_password, "Client Key"));
		server_key = hmac_sha512(salted_password, "Server Key");
	else
		salted_password = Hi(hmac_sha1, password, salt, iteration_count);
		stored_key = sha1(hmac_sha1(salted_password, "Client Key"));
		server_key = hmac_sha1(salted_password, "Server Key");
	end
	return true, stored_key, server_key;
end

local function scram_gen(hash_name, H_f, HMAC_f)
	local function scram_hash(self, message)
		if not self.state then self.state = {}; end
		local supports_channel_binding = self.profile.channel_bind_cb and true;
		local _state = self.state;
	
		if type(message) ~= "string" or #message == 0 then return "failure", "malformed-request"; end
		if not _state.name then
			-- we are processing client_first_message
			local client_first_message = message;
			
			-- TODO: fail if authzid is provided, since we don't support them yet
			local gs2_header, gs2_cbind_flag, gs2_cbind_name, authzid, client_first_message_bare, name, clientnonce =
				client_first_message:match("^(([pny])=?([^,]*),([^,]*),)(m?=?[^,]*,?n=([^,]*),r=([^,]*),?.*)$");

			if not gs2_cbind_flag then return "failure", "malformed-request"; end
			if supports_channel_binding and gs2_cbind_flag == "y" then return "failure", "malformed-request"; end
			if gs2_cbind_flag == "n" then supports_channel_binding = nil; end
			if supports_channel_binding and gs2_cbind_flag == "p" and (gs2_cbind_name ~= self.profile.channel_bind_type)  then
				return "failure", "malformed-request", "Unsupported channel binding type";
			elseif not supports_channel_binding then
				self.profile.channel_bind_cb = nil;
			end
			_state.gs2_header = gs2_header;
		
			_state.name = validate_username(name, self.profile.nodeprep);
			if not _state.name then
				log("debug", "Username violates either SASLprep or contains forbidden character sequences")
				return "failure", "malformed-request", "Invalid username";
			end
		
			_state.clientnonce, _state.servernonce = clientnonce, generate_uuid();
			
			-- retreive credentials
			if self.profile.plain then
				local password, state = self.profile.plain(self, _state.name, self.realm)
				if state == nil then return "failure", "not-authorized";
				elseif state == false then return "failure", "account-disabled"; end
				
				password = saslprep(password);
				if not password then
					log("debug", "Password violates SASLprep.");
					return "failure", "not-authorized", "Invalid password";
				end

				_state.salt = generate_uuid();
				_state.iteration_count = default_i;

				local succ = false;
				succ, _state.stored_key, _state.server_key = 
					getAuthenticationDatabase(hashprep(hash_name), password, _state.salt, default_i, _state.iteration_count);
				if not succ then
					log("error", "Generating authentication database failed. Reason: %s", _state.stored_key);
					return "failure", "temporary-auth-failure";
				end
			elseif self.profile["scram_"..hashprep(hash_name)] then
				local stored_key, server_key, iteration_count, salt, state = self.profile["scram_"..hashprep(hash_name)](self, _state.name, self.realm);
				if state == nil then return "failure", "not-authorized"; elseif state == false then return "failure", "account-disabled"; end
				if not stored_key or not server_key then
					return "failure", "temporary-auth-failure", "Missing "..hash_name.." keys, please reset your password";
				end
				
				_state.stored_key = stored_key;
				_state.server_key = server_key;
				_state.iteration_count = iteration_count;
				_state.salt = salt;
			end
		
			local server_first_message = "r="..clientnonce.._state.servernonce..",s="..base64.encode(_state.salt)..",i=".._state.iteration_count;
			_state.client_first_message_bare = client_first_message_bare;
			_state.server_first_message = server_first_message;
			return "challenge", server_first_message;
		else
			-- we are processing client_final_message
			local client_final_message = message;
			
			local client_final_message_wp, channelbinding, nonce, proof =
				client_final_message:match("(c=([^,]*),r=([^,]*),?.-),p=(.*)$");
	
			if not proof or not nonce or not channelbinding then
				return "failure", "malformed-request", "Missing an attribute(p, r or c) in SASL message";
			end

			local client_header = base64.decode(channelbinding);
			local our_client_header = _state.gs2_header;
			if supports_channel_binding then our_client_header = our_client_header .. self.profile.channel_bind_cb(); end
			if client_header ~= our_client_header then return "failure", "malformed-request", "Channel binding value is invalid"; end

			if nonce ~= _state.clientnonce.._state.servernonce then
				return "failure", "malformed-request", "Wrong nonce in client-final-message";
			end
			
			local ServerKey = _state.server_key;
			local StoredKey = _state.stored_key;
			
			local AuthMessage = _state.client_first_message_bare .. "," .. _state.server_first_message .. "," .. client_final_message_wp;

			local ClientSignature = HMAC_f(StoredKey, AuthMessage);
			local ClientKey = binaryXOR(ClientSignature, base64.decode(proof));
			if not ClientKey then
				return "failure", "malformed-request", "XOR failed with provided signature and proof";
			end
			local ServerSignature = HMAC_f(ServerKey, AuthMessage);

			if StoredKey == H_f(ClientKey) then
				local server_final_message = "v="..base64.encode(ServerSignature);
				self.username = _state.name;
				self.state = nil;
				return "success", server_final_message;
			else
				self.state = nil;
				return "failure", "not-authorized", "The response provided by the client doesn't match the one we calculated";
			end
		end
	end
	return scram_hash;
end

local function init(registerMechanism)
	local function registerSCRAMMechanism(hash_name, hash, hmac_hash)
		registerMechanism("SCRAM-"..hash_name, {"plain", "scram_"..(hashprep(hash_name))}, scram_gen(hash_name:lower(), hash, hmac_hash));
		registerMechanism("SCRAM-"..hash_name.."-PLUS", {"plain", "scram_"..(hashprep(hash_name))}, scram_gen(hash_name:lower(), hash, hmac_hash), true);
	end

	registerSCRAMMechanism("SHA-1", sha1, hmac_sha1);
	registerSCRAMMechanism("SHA-256", sha256, hmac_sha256);
	registerSCRAMMechanism("SHA-384", sha384, hmac_sha384);
	registerSCRAMMechanism("SHA-512", sha512, hmac_sha512);
end

return {
	Hi = Hi,
	getAuthenticationDatabase = getAuthenticationDatabase,
	init = init
};
