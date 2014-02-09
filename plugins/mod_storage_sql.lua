-- * Metronome IM *
--
-- This file is part of the Metronome XMPP server and is released under the
-- ISC License, please see the LICENSE file in this source package for more
-- information about copyright and licensing.
--
-- Additional Contributors: John Regan
--
-- As per the sublicensing clause, this file is also MIT/X11 Licensed.
-- ** Copyright (c) 2010-2013, Kim Alvefur, Matthew Wild, Waqas Hussain

--[[

DB Tables:
	Metronome - key-value, map
		| host | user | store | key | type | value |

Mapping:
	Roster - Metronome
		| host | user | "roster" | "contactjid" | type | value |
		| host | user | "roster" | NULL | "json" | roster[false] data |
	Account - Metronome
		| host | user | "accounts" | "username" | type | value |

]]

local type = type;
local tostring = tostring;
local tonumber = tonumber;
local pairs = pairs;
local next = next;
local setmetatable = setmetatable;
local xpcall = xpcall;
local json = require "util.json";
local build_url = require"socket.url".build;

local DBI;
local connection;
local host,user,store = module.host;
local params = module:get_option_table("sql");

local dburi;
local connections = module:shared "/*/sql/connection-cache";

local function db2uri(params)
	return build_url{
		scheme = params.driver,
		user = params.username,
		password = params.password,
		host = params.host,
		port = params.port,
		path = params.database,
	};
end

local resolve_relative_path = require "core.configmanager".resolve_relative_path;

local function test_connection()
	if not connection then return nil; end
	if connection:ping() then
		return true;
	else
		module:log("debug", "Database connection closed");
		connection = nil;
		connections[dburi] = nil;
	end
end
local function connect()
	if not test_connection() then
		metronome.unlock_globals();
		local dbh, err = DBI.Connect(
			params.driver, params.database,
			params.username, params.password,
			params.host, params.port
		);
		metronome.lock_globals();
		if not dbh then
			module:log("debug", "Database connection failed: %s", tostring(err));
			return nil, err;
		end
		module:log("debug", "Successfully connected to database");
		dbh:autocommit(false); -- don't commit automatically
		connection = dbh;
		if params.driver == "MySQL" then
			local stmt;
			stmt = connection:prepare("SET collation_connection = utf8_general_ci;"); stmt:execute();
			stmt = connection:prepare("SET collation_server = utf8_general_ci;"); stmt:execute();
			stmt = connection:prepare("SET NAMES utf8;"); stmt:execute(); 
			connection:commit();
		end

		connections[dburi] = dbh;
	end
	return connection;
end

local function create_table()
	if not module:get_option("sql_manage_tables", true) then
		return;
	end
	local create_sql = "CREATE TABLE `metronome` (`host` TEXT, `user` TEXT, `store` TEXT, `key` TEXT, `type` TEXT, `value` TEXT);";
	if params.driver == "PostgreSQL" then
		create_sql = create_sql:gsub("`", "\"");
	elseif params.driver == "MySQL" then
		create_sql = create_sql:gsub("`value` TEXT", "`value` LONGTEXT");
	end
	
	local stmt, err = connection:prepare(create_sql);
	if stmt then
		local ok = stmt:execute();
		local commit_ok = connection:commit();
		if ok and commit_ok then
			module:log("info", "Initialized new %s database with metronome table", params.driver);
			local index_sql = "CREATE INDEX `metronome_index` ON `metronome` (`host`, `user`, `store`, `key`)";
			if params.driver == "PostgreSQL" then
				index_sql = index_sql:gsub("`", "\"");
			elseif params.driver == "MySQL" then
				index_sql = index_sql:gsub("`([,)])", "`(20)%1");
			end
			local stmt, err = connection:prepare(index_sql);
			local ok, commit_ok, commit_err;
			if stmt then
				ok, err = stmt:execute();
				commit_ok, commit_err = connection:commit();
			end
			if not(ok and commit_ok) then
				module:log("warn", "Failed to create index (%s), lookups may not be optimised", err or commit_err);
			end
		end
	elseif params.driver ~= "SQLite3" then -- SQLite normally fails to prepare for existing table
		module:log("warn", "Metronome was not able to automatically check/create the database table (%s)",
			err or "unknown error");
	end
end

do -- process options to get a db connection
	local ok;
	metronome.unlock_globals();
	ok, DBI = pcall(require, "DBI");
	if not ok then
		package.loaded["DBI"] = {};
		module:log("error", "Failed to load the LuaDBI library for accessing SQL databases: %s", DBI);
	end
	metronome.lock_globals();
	if not ok or not DBI.Connect then
		return; -- Halt loading of this module
	end

	params = params or { driver = "SQLite3" };
	
	if params.driver == "SQLite3" then
		params.database = resolve_relative_path(metronome.paths.data or ".", params.database or "metronome.sqlite");
	end
	
	assert(params.driver and params.database, "Both the SQL driver and the database need to be specified");

	dburi = db2uri(params);
	connection = connections[dburi];
	
	assert(connect());
	
	-- Automatically create table, ignore failure (table probably already exists)
	create_table();
end

local function serialize(value)
	local t = type(value);
	if t == "string" or t == "boolean" or t == "number" then
		return t, tostring(value);
	elseif t == "table" then
		local value,err = json.encode(value);
		if value then return "json", value; end
		return nil, err;
	end
	return nil, "Unhandled value type: "..t;
end
local function deserialize(t, value)
	if t == "string" then return value;
	elseif t == "boolean" then
		if value == "true" then return true;
		elseif value == "false" then return false; end
	elseif t == "number" then return tonumber(value);
	elseif t == "json" then
		return json.decode(value);
	end
end

local function dosql(sql, ...)
	if params.driver == "PostgreSQL" then
		sql = sql:gsub("`", "\"");
	end
	-- do prepared statement stuff
	if not connection and not connect() then return nil, "Unable to connect to database"; end
	local stmt, err = connection:prepare(sql);
	if err and err:match(".*MySQL server has gone away$") then
		stmt, err = connect() and connection:prepare(sql); -- reconnect
	end
	if not stmt then module:log("error", "QUERY FAILED: %s -- %s", err or "Connection to database failed", debug.traceback()); return nil, err; end
	-- run query
	local ok, err = stmt:execute(...);
	if not ok then return nil, err; end
	
	return stmt;
end
local function getsql(sql, ...)
	return dosql(sql, host or "", user or "", store or "", ...);
end
local function setsql(sql, ...)
	local stmt, err = getsql(sql, ...);
	if not stmt then return stmt, err; end
	return stmt:affected();
end
local function rollback(...)
	if connection then connection:rollback(); end -- FIXME check for rollback error?
	return ...;
end
local function commit(...)
	if not connection:commit() then return nil, "SQL commit failed"; end
	return ...;
end

local function keyval_store_get()
	local stmt, err = getsql("SELECT * FROM `metronome` WHERE `host`=? AND `user`=? AND `store`=?");
	if not stmt then return rollback(nil, err); end
	
	local haveany;
	local result = {};
	for row in stmt:rows(true) do
		haveany = true;
		local k = row.key;
		local v = deserialize(row.type, row.value);
		if k and v then
			if k ~= "" then result[k] = v; elseif type(v) == "table" then
				for a,b in pairs(v) do
					result[a] = b;
				end
			end
		end
	end
	return commit(haveany and result or nil);
end
local function keyval_store_set(data)
	local affected, err = setsql("DELETE FROM `metronome` WHERE `host`=? AND `user`=? AND `store`=?");
	if not affected then return rollback(affected, err); end
	
	if data and next(data) ~= nil then
		local extradata = {};
		for key, value in pairs(data) do
			if type(key) == "string" and key ~= "" then
				local t, value = serialize(value);
				if not t then return rollback(t, value); end
				local ok, err = setsql("INSERT INTO `metronome` (`host`,`user`,`store`,`key`,`type`,`value`) VALUES (?,?,?,?,?,?)", key, t, value);
				if not ok then return rollback(ok, err); end
			else
				extradata[key] = value;
			end
		end
		if next(extradata) ~= nil then
			local t, extradata = serialize(extradata);
			if not t then return rollback(t, extradata); end
			local ok, err = setsql("INSERT INTO `metronome` (`host`,`user`,`store`,`key`,`type`,`value`) VALUES (?,?,?,?,?,?)", "", t, extradata);
			if not ok then return rollback(ok, err); end
		end
	end
	return commit(true);
end

local keyval_store = {};
keyval_store.__index = keyval_store;
function keyval_store:get(username)
	user, store = username, self.store;
	local success, ret, err = xpcall(keyval_store_get, debug.traceback);
	if success then return ret, err; else return rollback(nil, ret); end
end
function keyval_store:set(username, data)
	user, store = username, self.store;
	local success, ret, err = xpcall(function() return keyval_store_set(data); end, debug.traceback);
	if success then return ret, err; else return rollback(nil, ret); end
end

-- Store defs.

cache = {};

local driver = { name = "sql" };

function driver:open(store, typ)
	if not typ then -- default key-value store
		if not cache[store] then cache[store] = setmetatable({ store = store }, keyval_store); end
		return cache[store];
	end
	return nil, "unsupported-store";
end

function driver:stores(username, type, pattern)
	local sql = "SELECT DISTINCT `store` FROM `metronome` WHERE `host`=? AND `user`"..(username == true and "!=?" or "=?").." AND `store` LIKE ?";

	if username == true or not username then
		username = "";
	end

	if pattern then
		pattern = pattern.."/%";
	else
		pattern = "%";
	end

	local stmt, err = dosql(sql, host, username, pattern);
	if not stmt then
		return rollback(nil, err);
	end
	local next = stmt:rows();
	return commit(function()
		local row = next();
		return row and row[1];
	end);
end

function driver:store_exists(username, datastore, type)
	local sql = "SELECT DISTINCT `store` FROM `metronome` WHERE `host`=? and `user`"..(username == true and "!=?" or "=?").." AND `store`=?";

	if username == true or not username then username = ""; end

	local stmt, err = dosql(sql, host, username, datastore);
	if not stmt then
		return rollback(nil, err);
	end
	local count = 0;
	for row in stmt:rows() do
		count = count + 1;
	end
	if count > 0 then 
		return true;
	end
	return false;
end

function driver:purge(username)
	local stmt, err = dosql("DELETE FROM `metronome` WHERE `host`=? AND `user`=?", host, username);
	if not stmt then return rollback(stmt, err); end
	local changed, err = stmt:affected();
	if not changed then return rollback(changed, err); end
	return commit(true, changed);
end

function driver:users()
	local stmt, err = dosql("SELECT DISTINCT `user` FROM `metronome` WHERE `store`=? AND `host`=?", "accounts", host);
	if not stmt then return rollback(nil, err); end
	local next = stmt:rows();
	return commit(function()
		local row = next();
		return row and row[1];
	end);
end

module:add_item("data-driver", driver);
