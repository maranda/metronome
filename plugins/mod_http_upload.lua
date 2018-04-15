-- * Metronome IM *
--
-- This file is part of the Metronome XMPP server and is released under the
-- ISC License, please see the LICENSE file in this source package for more
-- information about copyright and licensing.
--
-- As per the sublicensing clause, this file is also MIT/X11 Licensed.
-- ** Copyright (c) 2015-2017, Kim Alvefur

-- This module has been back ported from Prosody Modules

-- imports
local st = require "util.stanza";
local lfs = require "lfs";
local url = require "socket.url";
local dataform = require "util.dataforms".new;
local datamanager = require "util.datamanager";
local array = require "util.array";
local t_concat = table.concat;
local t_insert = table.insert;
local s_upper = string.upper;
local uuid = require "util.uuid".generate;

local function join_path(...)
	return table.concat({ ... }, package.config:sub(1,1));
end

local default_mime_types = {
	bmp = "image/bmp",
	gif = "image/gif",
	jpeg = "image/jpeg",
	jpg = "image/jpeg",
	png = "image/png",
	svg = "image/svg+xml",
	txt = "text/plain",
	tiff = "image/tiff",
	xml = "application/xml"
};

local cache = setmetatable({}, { __mode = "v" });

-- config
local mime_types = module:get_option_table("http_file_allowed_mime_types", default_mime_types);
local file_size_limit = module:get_option_number("http_file_size_limit", 2*1024*1024); -- 2 MB
local quota = module:get_option_number("http_file_quota", 20*1024*1024);
local max_age = module:get_option_number("http_file_expire_after", 172800);
local cacheable_size = module:get_option_number("http_file_cacheable_size", 100*1024);
local default_base_path = module:get_option_string("http_file_base_path", "share");

--- sanity
if file_size_limit > 5*1024*1024 then
	module:log("warn", "http_file_size_limit exceeds HTTP parser limit on body size, capping file size to %d B", parser_body_limit);
	file_size_limit = 5*1024*1024;
end

-- depends
module:depends("http");
module:depends("disco");

-- namespaces
local namespace = "urn:xmpp:http:upload:0";
local legacy_namespace = "urn:xmpp:http:upload";

-- identity and feature advertising
module:add_identity("store", "file", module:get_option_string("name", "HTTP File Upload"));
module:add_feature(namespace);
module:add_feature(legacy_namespace);

module:add_extension(dataform {
	{ name = "FORM_TYPE", type = "hidden", value = namespace },
	{ name = "max-file-size", type = "text-single" },
}:form({ ["max-file-size"] = tostring(file_size_limit) }, "result"));

module:add_extension(dataform {
	{ name = "FORM_TYPE", type = "hidden", value = legacy_namespace },
	{ name = "max-file-size", type = "text-single" },
}:form({ ["max-file-size"] = tostring(file_size_limit) }, "result"));

-- state
local pending_slots = module:shared("upload_slots");

local storage_path = module:get_option_string("http_file_path", join_path(metronome.paths.data, "http_file_upload"));
lfs.mkdir(storage_path);

local function expire(username, host)
	if not max_age then return true; end
	local uploads, err = datamanager.list_load(username, host, module.name);
	if not uploads then return true; end
	uploads = array(uploads);
	local expiry = os.time() - max_age;
	local upload_window = os.time() - 900;
	uploads:filter(function (item)
		local filename = item.filename;
		if item.dir then
			filename = join_path(storage_path, item.dir, item.filename);
		end
		if item.time < expiry then
			local deleted, whynot = os.remove(filename);
			if not deleted then
				module:log("warn", "Could not delete expired upload %s: %s", filename, whynot or "delete failed");
			end
			os.remove(filename:match("^(.*)[/\\]"));
			return false;
		elseif item.time < upload_window and not lfs.attributes(filename) then
			return false; -- File was not uploaded or has been deleted since
		end
		return true;
	end);
	return datamanager.list_store(username, host, module.name, uploads);
end

local function check_quota(username, host, does_it_fit)
	if not quota then return true; end
	local uploads, err = datamanager.list_load(username, host, module.name);
	if not uploads then return true; end
	local sum = does_it_fit or 0;
	for _, item in ipairs(uploads) do
		sum = sum + item.size;
	end
	return sum < quota;
end

local function handle_request(origin, stanza, xmlns, filename, filesize)
	local username, host = origin.username, origin.host;
	-- local clients only
	if origin.type ~= "c2s" then
		module:log("debug", "Request for upload slot from a %s", origin.type);
		return nil, st.error_reply(stanza, "cancel", "not-authorized");
	end
	-- validate
	if not filename or filename:find("/") or not mime_types[filename:match("%.([^%.]*)$")] then
		module:log("debug", "Filename %q not allowed", filename or "");
		return nil, st.error_reply(stanza, "modify", "bad-request", "Invalid filename or unallowed type");
	end
	expire(username, host);
	if not filesize then
		module:log("debug", "Missing file size");
		return nil, st.error_reply(stanza, "modify", "bad-request", "Missing or invalid file size");
	elseif filesize > file_size_limit then
		module:log("debug", "File too large (%d > %d)", filesize, file_size_limit);
		return nil, st.error_reply(stanza, "modify", "not-acceptable", "File too large")
			:tag("file-too-large", {xmlns=xmlns})
				:tag("max-file-size"):text(tostring(file_size_limit));
	elseif not check_quota(username, host, filesize) then
		module:log("debug", "Upload of %dB by %s would exceed quota", filesize, origin.full_jid);
		return nil, st.error_reply(stanza, "wait", "resource-constraint", "Quota reached");
	end

	local random_dir = uuid();
	local created, err = lfs.mkdir(join_path(storage_path, random_dir));

	if not created then
		module:log("error", "Could not create directory for slot: %s", err);
		return nil, st.error_reply(stanza, "wait", "internal-server-failure");
	end

	local ok = datamanager.list_append(username, host, module.name, {
		filename = filename, dir = random_dir, size = filesize, time = os.time() });

	if not ok then
		return nil, st.error_reply(stanza, "wait", "internal-server-failure");
	end

	local slot = random_dir.."/"..filename;
	pending_slots[slot] = origin.full_jid;

	module:add_timer(900, function()
		pending_slots[slot] = nil;
	end);

	origin.log("debug", "Given upload slot %q", slot);

	local base_url = module:http_url(nil, default_base_path);
	local slot_url = url.parse(base_url);
	slot_url.path = url.parse_path(slot_url.path or "/");
	t_insert(slot_url.path, random_dir);
	t_insert(slot_url.path, filename);
	slot_url.path.is_directory = false;
	slot_url.path = url.build_path(slot_url.path);
	slot_url = url.build(slot_url);
	return slot_url;
end

-- hooks
module:hook("iq/host/"..namespace..":request", function (event)
	local stanza, origin = event.stanza, event.origin;
	local request = stanza.tags[1];
	local filename = request.attr.filename;
	local filesize = tonumber(request.attr.size);

	local slot_url, err = handle_request(origin, stanza, namespace, filename, filesize);
	if not slot_url then
		origin.send(err);
		return true;
	end

	local reply = st.reply(stanza)
		:tag("slot", { xmlns = namespace })
			:tag("get", { url = slot_url }):up()
			:tag("put", { url = slot_url }):up()
		:up();
	origin.send(reply);
	return true;
end);

module:hook("iq/host/"..legacy_namespace..":request", function (event)
	local stanza, origin = event.stanza, event.origin;
	local request = stanza.tags[1];
	local filename = request:get_child_text("filename");
	local filesize = tonumber(request:get_child_text("size"));

	local slot_url, err = handle_request(origin, stanza, legacy_namespace, filename, filesize);
	if not slot_url then
		origin.send(err);
		return true;
	end

	local reply = st.reply(stanza)
		:tag("slot", { xmlns = legacy_namespace })
			:tag("get"):text(slot_url):up()
			:tag("put"):text(slot_url):up()
		:up();
	origin.send(reply);
	return true;
end);

-- http service
local function upload_data(event, path)
	local uploader = pending_slots[path];
	if not uploader then
		module:log("warn", "Attempt to upload to unknown slot %q", path);
		return; -- 404
	end
	local random_dir, filename = path:match("^([^/]+)/([^/]+)$");
	if not random_dir then
		module:log("warn", "Invalid file path %q", path);
		return 400;
	end
	if #event.request.body > file_size_limit then
		module:log("warn", "Uploaded file too large %d bytes", #event.request.body);
		return 400;
	end
	pending_slots[path] = nil;
	local full_filename = join_path(storage_path, random_dir, filename);
	if lfs.attributes(full_filename) then
		module:log("warn", "File %s exists already, not replacing it", full_filename);
		return 409;
	end
	local fh, ferr = io.open(full_filename, "w");
	if not fh then
		module:log("error", "Could not open file %s for upload: %s", full_filename, ferr);
		return 500;
	end
	local ok, err = fh:write(event.request.body);
	if not ok then
		module:log("error", "Could not write to file %s for upload: %s", full_filename, err);
		os.remove(full_filename);
		return 500;
	end
	ok, err = fh:close();
	if not ok then
		module:log("error", "Could not write to file %s for upload: %s", full_filename, err);
		os.remove(full_filename);
		return 500;
	end
	module:log("info", "File uploaded by %s to slot %s", uploader, random_dir);
	return 201;
end

-- FIXME Duplicated from net.http.server

local codes = require "net.http.codes";
local headerfix = setmetatable({}, {
	__index = function(t, k)
		local v = "\r\n"..k:gsub("_", "-"):gsub("%f[%w].", s_upper)..": ";
		t[k] = v;
		return v;
	end
});

local function send_response_sans_body(response, body)
	if response.finished then return; end
	response.finished = true;
	response.conn._http_open_response = nil;

	local status_line = "HTTP/"..response.request.httpversion.." "..(response.status or codes[response.status_code]);
	local headers = response.headers;

	local output = { status_line };
	for k,v in pairs(headers) do
		t_insert(output, headerfix[k]..v);
	end
	t_insert(output, "\r\n\r\n");
	-- Here we *don't* add the body to the output

	response.conn:write(t_concat(output));
	if response.on_destroy then
		response:on_destroy();
		response.on_destroy = nil;
	end
	if response.persistent then
		response:finish_cb();
	else
		response.conn:close();
	end
end

local function serve_uploaded_files(event, path, head)
	local response = event.response;
	local request = event.request;

	local full_path = join_path(storage_path, path);
	local cached = cache[full_path];

	if not cached then 
		cached = {}; 
		cached.attrs = lfs.attributes(full_path);
		if not cached.attrs then return 404; end
	end

	local headers, attrs, data = cached.headers, cached.attrs;
	if not headers then
		headers = response.headers;
		headers["Content-Type"] = mime_types[full_path:match("%.([^%.]*)$")];
		headers["Content-Length"] = attrs.size;
		headers["Last-Modified"] = os.date("!%a, %d %b %Y %X GMT", attrs.modification);
		cached.headers = headers;
	end

	if attrs.size <= cacheable_size then
		local f = io.open(full_path, "rb");
		if f then data = f:read("*a"); f:close(); end

		cached.data = data;
	end
	cache[full_path] = cached;

	if head then
		response:send();		
	else
		data = cached.data;
		if not data then
			local f = io.open(full_path, "rb");
			if f then data = f:read("*a"); f:close(); end
		end

		response:send(data);
	end
end

local function serve_head(event, path)
	event.response.send = send_response_sans_body;
	return serve_uploaded_files(event, path, true);
end

local function serve_hello(event)
	event.response.headers.content_type = "text/html;charset=utf-8"
	return "<!DOCTYPE html>\n<h1>Hello from mod_"..module.name.." on "..module.host.."!</h1>\n";
end

module:provides("http", {
	default_path = default_base_path,
	route = {
		["GET"] = serve_hello;
		["GET /"] = serve_hello;
		["GET /*"] = serve_uploaded_files;
		["HEAD /*"] = serve_head;
		["PUT /*"] = upload_data;
	};
});

module:log("info", "URL: <%s>; Storage path: %s", module:http_url(nil, default_base_path), storage_path);
