-- * Metronome IM *
--
-- This file is part of the Metronome XMPP server and is released under the
-- ISC License, please see the LICENSE file in this source package for more
-- information about copyright and licensing.
--
-- Additional Contributors: John Regan
--
-- As per the sublicensing clause, this file is also MIT/X11 Licensed.
-- ** Copyright (c) 2008-2013, Kim Alvefur, Marco Cirillo, Matthew Wild, Waqas Hussain

local format = string.format;
local setmetatable = setmetatable;
local ipairs = ipairs;
local char = string.char;
local pcall = pcall;
local log = require "util.logger".init("datamanager");
local io_open = io.open;
local os_remove = os.remove;
local os_rename = os.rename;
local tonumber = tonumber;
local type = type;
local next = next;
local t_insert = table.insert;
local t_concat = table.concat;
local _load_file = require "util.envload".envloadfile;
local _serialize = require "util.serialization".serialize;
local path_separator = assert ( package.config:match ( "^([^\n]+)" ) , "package.config not in standard form" ) -- Extract directory seperator from package.config (an undocumented string that comes with lua)
local lfs = require "lfs";
local metronome = metronome;

local load_file = _load_file;
local serialize = function(data)
	return "return " .. _serialize(data) .. ";";
end
if metronome.serialization == "json" then
	local json = require "util.jsonload";
	if json then
		load_file = json.loadfile;
		serialize = json.serialize;
	end
end

local raw_mkdir = lfs.mkdir;
local fallocate;
local function _fallocate(f, offset, len)
	-- This assumes that current position == offset
	local fake_data = (" "):rep(len);
	local ok, msg = f:write(fake_data);
	if not ok then
		return ok, msg;
	end
	f:seek("set", offset);
	return true;
end;
pcall(function()
	local pposix = require "util.pposix";
	raw_mkdir = pposix.mkdir or raw_mkdir; -- Doesn't trample on umask
	fallocate = pposix.fallocate or _fallocate;
end);

local _ENV = nil;
local datamanager = {};

---- utils -----
local encode, decode;
do
	local urlcodes = setmetatable({}, { __index = function (t, k) t[k] = char(tonumber("0x"..k)); return t[k]; end });

	decode = function (s)
		return s and (s:gsub("+", " "):gsub("%%([a-fA-F0-9][a-fA-F0-9])", urlcodes));
	end

	encode = function (s)
		return s and (s:gsub("%W", function (c) return format("%%%02x", c:byte()); end));
	end
end

local _mkdir = {};
local function mkdir(path)
	path = path:gsub("/", path_separator); -- TODO as an optimization, do this during path creation rather than here
	if not _mkdir[path] then
		raw_mkdir(path);
		_mkdir[path] = true;
	end
	return path;
end

local data_path = (metronome and metronome.paths and metronome.paths.data) or ".";
local callbacks = {};

------- API -------------

function datamanager.set_data_path(path)
	log("debug", "Setting data path to: %s", path);
	data_path = path;
end

local function callback(username, host, datastore, data)
	for _, f in ipairs(callbacks) do
		username, host, datastore, data = f(username, host, datastore, data);
		if username == false then break; end
	end

	return username, host, datastore, data;
end
function datamanager.add_callback(func)
	if not callbacks[func] then -- Would you really want to set the same callback more than once?
		callbacks[func] = true;
		callbacks[#callbacks+1] = func;
		return true;
	end
end
function datamanager.remove_callback(func)
	if callbacks[func] then
		for i, f in ipairs(callbacks) do
			if f == func then
				callbacks[i] = nil;
				callbacks[f] = nil;
				return true;
			end
		end
	end
end

local function recursive_ds_create(host, datastore)
	local last_done;
	local host_data_path = data_path.."/"..host;
	for dir in datastore:gmatch("[^/]+") do
		if not last_done then		
			mkdir(host_data_path.."/"..dir);
			last_done = dir;
		else
			last_done = last_done.."/"..dir;
			mkdir(host_data_path.."/"..last_done);
		end
	end
end

local function getpath(username, host, datastore, ext, create)
	ext = ext or "dat";
	host = (host and encode(host)) or "_global";
	username = username and encode(username);
	if username then
		if create then
			mkdir(mkdir(data_path).."/"..host);
			recursive_ds_create(host, datastore);
		end
		return format("%s/%s/%s/%s.%s", data_path, host, datastore, username, ext);
	else
		if create then 
			mkdir(mkdir(data_path).."/"..host);
			if datastore:find("/") then recursive_ds_create(host, datastore); end
		end
		return format("%s/%s/%s.%s", data_path, host, datastore, ext);
	end
end

function datamanager.load(username, host, datastore)
	local data, ret = load_file(getpath(username, host, datastore), {});
	if not data then
		local mode = lfs.attributes(getpath(username, host, datastore), "mode");
		if not mode then
			return nil;
		else -- file exists, but can't be read
			log("error", "Failed to load %s storage ('%s') for user: %s@%s", datastore, ret or "File can't be read", username or "nil", host or "nil");
			return nil, "Error reading storage";
		end
	end

	if type(data) ~= "function" then return data; end
	
	local success, ret = pcall(data);
	if not success then
		log("error", "Unable to load %s storage ('%s') for user: %s@%s", datastore, ret, username or "nil", host or "nil");
		return nil, "Error reading storage";
	end
	return ret;
end

local function atomic_store(filename, data)
	local scratch = filename.."~";
	local f, ok, msg;
	repeat
		f, msg = io_open(scratch, "w");
		if not f then break end

		ok, msg = f:write(data);
		if not ok then break end

		ok, msg = f:close();
		if not ok then break end

		return os_rename(scratch, filename);
	until false;

	-- Cleanup
	if f then f:close(); end
	os_remove(scratch);
	return nil, msg;
end

if metronome.platform ~= "posix" then
	function atomic_store(filename, data)
		local f, err = io_open(filename, "w");
		if not f then return f, err; end
		local ok, msg = f:write(data);
		if not ok then f:close(); return ok, msg; end
		return f:close();
	end
end

function datamanager.store(username, host, datastore, data)
	if not data then
		data = {};
	end

	username, host, datastore, data = callback(username, host, datastore, data);
	if username == false then
		return true; -- Don't save this data at all
	elseif username == true then
		return nil, "Storage is disabled"; -- Output error
	end

	-- save the datastore
	local d = serialize(data) .. "\n";
	local mkdir_cache_cleared;
	repeat
		local ok, msg = atomic_store(getpath(username, host, datastore, nil, true), d);
		if not ok then
			if not mkdir_cache_cleared then -- We may need to recreate a removed directory
				_mkdir = {};
				mkdir_cache_cleared = true;
			else
				log("error", "Unable to write to %s storage ('%s') for user: %s@%s", datastore, msg, username or "nil", host or "nil");
				return nil, "Error saving to storage";
			end
		end
		if next(data) == nil then -- try to delete empty datastore
			log("debug", "Removing empty %s datastore for user %s@%s", datastore, username or "nil", host or "nil");
			os_remove(getpath(username, host, datastore));
		end
		-- we write data even when we are deleting because lua doesn't have a
		-- platform independent way of checking for non-exisitng files
	until ok;
	return true;
end

function datamanager.list_append(username, host, datastore, data)
	if not data then return; end
	if callback(username, host, datastore) == false then return true; end
	-- save the datastore
	local f, msg = io_open(getpath(username, host, datastore, "list", true), "r+");
	if not f then
		f, msg = io_open(getpath(username, host, datastore, "list", true), "w");
	end
	if not f then
		log("error", "Unable to write to %s storage ('%s') for user: %s@%s", datastore, msg, username or "nil", host or "nil");
		return;
	end
	local data = "item(" ..  _serialize(data) .. ");\n";
	local pos = f:seek("end");
	local ok, msg = fallocate(f, pos, #data);
	if not ok and msg == "Not supported" then -- workaround for NFS storage
		ok, msg = _fallocate(f, pos, #data);
	end
	f:seek("set", pos);
	if ok then
		f:write(data);
	else
		log("error", "Unable to write to %s storage ('%s') for user: %s@%s", datastore, msg, username or "nil", host or "nil");
		return ok, msg;
	end
	f:close();
	return true;
end

function datamanager.list_store(username, host, datastore, data)
	if not data then
		data = {};
	end
	if callback(username, host, datastore) == false then return true; end
	-- save the datastore
	local d = {};
	for _, item in ipairs(data) do
		d[#d+1] = "item(" .. _serialize(item) .. ");\n";
	end
	local ok, msg = atomic_store(getpath(username, host, datastore, "list", true), t_concat(d));
	if not ok then
		log("error", "Unable to write to %s storage ('%s') for user: %s@%s", datastore, msg, username or "nil", host or "nil");
		return;
	end
	if next(data) == nil then -- try to delete empty datastore
		log("debug", "Removing empty %s datastore for user %s@%s", datastore, username or "nil", host or "nil");
		os_remove(getpath(username, host, datastore, "list"));
	end
	-- we write data even when we are deleting because lua doesn't have a
	-- platform independent way of checking for non-exisitng files
	return true;
end

function datamanager.list_load(username, host, datastore)
	local items = {};
	local data, ret = _load_file(getpath(username, host, datastore, "list"), {item = function(i) t_insert(items, i); end});
	if not data then
		local mode = lfs.attributes(getpath(username, host, datastore, "list"), "mode");
		if not mode then
			return nil;
		else -- file exists, but can't be read
			log("error", "Failed to load %s storage ('%s') for user: %s@%s", datastore, ret, username or "nil", host or "nil");
			return nil, "Error reading storage";
		end
	end

	local success, ret = pcall(data);
	if not success then
		log("error", "Unable to load %s storage ('%s') for user: %s@%s", datastore, ret, username or "nil", host or "nil");
		return nil, "Error reading storage";
	end
	return items;
end

local type_map = { keyval = "dat", list = "list" }
function datamanager.stores(username, host, type, pattern)
	if not host then
		return nil, "bad argument #2 to 'stores' (string expected, got nothing)";
	end

	type = type_map[type or "keyval"];
	local store_dir;
	if pattern then
		store_dir = format("%s/%s/%s", data_path, encode(host), pattern);
	else
		store_dir = format("%s/%s/", data_path, encode(host));
	end

	local mode, err = lfs.attributes(store_dir, "mode");
	if not mode then
		return function() log("debug", err or (store_dir .. " does not exist")); end
	end
	local next, state = lfs.dir(store_dir);
	return function(state)
		for node in next, state do
			if not node:match("^%.") then
				if username == true then
					if lfs.attributes(store_dir..node, "mode") == "directory" then
						return (pattern and pattern .. "/" .. decode(node)) or decode(node);
					end
				elseif username then
					local store = (pattern and pattern .. "/" .. decode(node)) or decode(node);
					if lfs.attributes(getpath(username, host, store, type), "mode") then
						return store;
					end
				elseif lfs.attributes(node, "mode") == "file" then
					local file, ext = node:match("^(.*)%.([dalist]+)$");
					if ext == type then
						return (pattern and pattern .. "/" .. decode(file)) or decode(file);
					end
				end
			end
		end
	end, state;
end

function datamanager.store_exists(username, host, datastore, type)
	if not username or not host or not datastore then
		return nil, "syntax error store_exists requires to supply at least 3 arguments (username, host, datastore)";
	end

	type = type_map[type or "keyval"];

	if username == true then
		if lfs.attributes(format("%s/%s/%s", data_path, encode(host), datastore), "mode") == "directory" then
			return true;
		end
		return false;
	elseif username then
		if lfs.attributes(getpath(username, host, datastore, type), "mode") then
			return true;
		end
		return false;
	end
end

function datamanager.nodes(host, datastore, type)
	type = type_map[type or "keyval"];
	local store_dir = format("%s/%s/%s", data_path, encode(host), datastore);

	local mode, err = lfs.attributes(store_dir, "mode");
	if not mode then
		return function() log("debug", "%s", err or (store_dir .. " does not exist")); end
	end

	local next, state = lfs.dir(store_dir);
	return function(state)
		for node in next, state do
			local file, ext = node:match("^(.*)%.([dalist]+)$");
			if file and ext == type then return decode(file); end
		end
	end, state;
end

local function do_remove(path)
	local ok, err = os_remove(path);
	if not ok and lfs.attributes(path, "mode") then
		return ok, err;
	end
	return true;
end

function datamanager.purge(username, host)
	local host_dir = format("%s/%s/", data_path, encode(host));
	local errs = {};
	local mode = lfs.attributes(host_dir, "mode");
	if mode then
		for file in lfs.dir(host_dir) do
			if lfs.attributes(host_dir..file, "mode") == "directory" then
				local store = decode(file);
				local ok, err = do_remove(getpath(username, host, store));
				if not ok then errs[#errs+1] = err; end

				local ok, err = do_remove(getpath(username, host, store, "list"));
				if not ok then errs[#errs+1] = err; end
			end
		end
		return #errs == 0, t_concat(errs, ", ");
	else
		return false, "Host datastore root not present";
	end
end

datamanager.atomic_store = atomic_store;
datamanager.getpath = getpath;
datamanager.path_decode = decode;
datamanager.path_encode = encode;
return datamanager;
