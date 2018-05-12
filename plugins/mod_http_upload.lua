-- * Metronome IM *
--
-- This file is part of the Metronome XMPP server and is released under the
-- ISC License, please see the LICENSE file in this source package for more
-- information about copyright and licensing.
--
-- As per the sublicensing clause, this file is also MIT/X11 Licensed.
-- ** Copyright (c) 2015-2017, Kim Alvefur

-- This module has been back ported from Prosody Modules

if module:get_host_type() ~= "component" then
	error("HTTP Upload should be loaded as a component", 0);
end

-- imports
local st = require "util.stanza";
local lfs = require "lfs";
local url = require "socket.url";
local dataform = require "util.dataforms".new;
local datamanager = require "util.datamanager";
local array = require "util.array";
local seed = require "util.auxiliary".generate_secret;
local join, split = require "util.jid".join, require "util.jid".split;
local gc, ipairs, pairs, open, os_remove, os_time, s_upper, t_concat, t_insert, tostring =
	collectgarbage, ipairs, pairs, io.open, os.remove, os.time, string.upper, table.concat, table.insert, tostring;

local function join_path(...)
	return table.concat({ ... }, package.config:sub(1,1));
end

local function generate_directory()
	local bits = seed(9);
	return bits and bits:gsub("/", ""):gsub("%+", "") .. tostring(os_time()):match("%d%d%d%d$");
end

local default_mime_types = {
	["3gp"] = "video/3gpp",
	["aac"] = "audio/aac",
	["bmp"] = "image/bmp",
	["gif"] = "image/gif",
	["jpeg"] = "image/jpeg",
	["jpg"] = "image/jpeg",
	["m4a"] = "audio/mp4",
	["mov"] = "video/quicktime",
	["mp3"] = "audio/mpeg",
	["mp4"] = "video/mp4",
	["ogg"] = "application/ogg",
	["png"] = "image/png",
	["qt"] = "video/quicktime",
	["tiff"] = "image/tiff",
	["txt"] = "text/plain",
	["xml"] = "text/xml",
	["wav"] = "audio/wav",
	["webm"] = "video/webm"
};

local cache = {};
local throttle = {};

local bare_sessions = bare_sessions;

-- config
local mime_types = module:get_option_table("http_file_allowed_mime_types", default_mime_types);
local file_size_limit = module:get_option_number("http_file_size_limit", 3*1024*1024); -- 3 MiB
local quota = module:get_option_number("http_file_quota", 40*1024*1024);
local max_age = module:get_option_number("http_file_expire_after", 172800);
local expire_any = module:get_option_number("http_file_perfom_expire_any", 1800);
local expire_slot = module:get_option_number("http_file_expire_upload_slots", 900);
local expire_cache = module:get_option_number("http_file_expire_file_caches", 450);
local throttle_time = module:get_option_number("http_file_throttle_time", 180);
local cacheable_size = module:get_option_number("http_file_cacheable_size", file_size_limit);
local default_base_path = module:get_option_string("http_file_base_path", "share");
local storage_path = module:get_option_string("http_file_path", join_path(metronome.paths.data, "http_file_upload"));
lfs.mkdir(storage_path);

--- sanity
if file_size_limit > 12*1024*1024 then
	module:log("warn", "http_file_size_limit exceeds max allowed size, capping file size to 12 MiB");
	file_size_limit = 12*1024*1024;
end

-- utility
local function purge_files(event)
	local user, host = event.username, event.host;
	local uploads = datamanager.list_load(user, host, module.name);
	if not uploads then return; end
	module:log("info", "Removing uploaded files for %s@%s account", user, host);
	for _, item in ipairs(uploads) do
		local filename = join_path(storage_path, item.dir, item.filename);
		local ok, err = os_remove(filename);
		if not ok then module:log("debug", "Failed to remove %s@%s %s file: %s", user, host, filename, err); end
		os_remove(filename:match("^(.*)[/\\]"));
	end
	datamanager.list_store(user, host, module.name, nil);
	local has_downloads = datamanager.load(nil, host, module.name);
	if has_downloads then
		has_downloads[user] = nil;
		if not next(has_downloads) then has_downloads = nil; end
		datamanager.store(nil, host, module.name, has_downloads);
	end
end

-- depends
module:depends("http");
module:depends("adhoc");

-- namespaces
local namespace = "urn:xmpp:http:upload:0";
local legacy_namespace = "urn:xmpp:http:upload";

-- identity and feature advertising
local disco_name = module:get_option_string("name", "HTTP File Upload");
module:hook("iq/host/http://jabber.org/protocol/disco#info:query", function(event)
	local origin, stanza = event.origin, event.stanza;
	local reply = st.iq({ type = "result", id = stanza.attr.id, from = module.host, to = stanza.attr.from })
		:query("http://jabber.org/protocol/disco#info")
			:tag("identity", { category = "store", type = "file", name = disco_name }):up()
			:tag("feature", { var = "http://jabber.org/protocol/commands" }):up()
			:tag("feature", { var = namespace }):up()
			:tag("feature", { var = legacy_namespace }):up();

	reply.tags[1]:add_child(dataform {
		{ name = "FORM_TYPE", type = "hidden", value = namespace },
		{ name = "max-file-size", type = "text-single" }
	}:form({ ["max-file-size"] = tostring(file_size_limit) })):up();
	reply.tags[1]:add_child(dataform {
		{ name = "FORM_TYPE", type = "hidden", value = legacy_namespace },
		{ name = "max-file-size", type = "text-single" }
	}:form({ ["max-file-size"] = tostring(file_size_limit) })):up();
			
	origin.send(reply);
	return true;
end);

-- state
local pending_slots = module:shared("upload_slots");

local function expire(username, host, has_downloads)
	if not max_age then return true; end
	local uploads, err = datamanager.list_load(username, host, module.name);
	if not uploads then return; end
	local now = os_time();
	if has_downloads then has_downloads[username] = now; end
	uploads = array(uploads);
	local expiry = now - max_age;
	local upload_window = now - expire_slot;
	uploads:filter(function (item)
		local filename = item.filename;
		if item.dir then
			filename = join_path(storage_path, item.dir, item.filename);
		end
		if item.time < expiry then
			local deleted, whynot = os_remove(filename);
			if not deleted then
				module:log("warn", "Could not delete expired upload %s: %s", filename, whynot or "delete failed");
			end
			os_remove(filename:match("^(.*)[/\\]"));
			return false;
		elseif item.time < upload_window and not lfs.attributes(filename) then
			return false; -- File was not uploaded or has been deleted since
		end
		return true;
	end);
	return datamanager.list_store(username, host, module.name, uploads);
end

local function expire_host(host)
	local has_downloads = datamanager.load(nil, host, module.name);
	if has_downloads then
		for user, last_use in pairs(has_downloads) do
			if os_time() - last_use >= expire_any and expire(user, host, has_downloads) == nil then
				has_downloads[user] = nil;
			end
		end

		if not next(has_downloads) then has_downloads = nil; end

		local ok, err = datamanager.store(nil, host, module.name, has_downloads);
		if err then module:log("warn", "Couldn't save %s's list of users using HTTP Uploads: %s", host, err); end
		return true;
	end
	return false;
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
	local last_uploaded_sum = throttle[join(username, host)];
	-- local clients only
	if origin.type ~= "c2s" then
		module:log("debug", "Request for upload slot from a %s", origin.type);
		return nil, st.error_reply(stanza, "cancel", "not-authorized");
	end
	-- validate
	local ext = filename:match("%.([^%.]*)$");
	if not filename or filename:find("/") or not mime_types[ext and ext:lower()] then
		module:log("debug", "Filename %q not allowed", filename or "");
		return nil, st.error_reply(stanza, "modify", "bad-request", "Invalid filename or unallowed type");
	end
	if not expire_host(host) then expire(username, host); end
	if not filesize then
		module:log("debug", "Missing file size");
		return nil, st.error_reply(stanza, "modify", "bad-request", "Missing or invalid file size");
	elseif last_uploaded_sum and (last_uploaded_sum + filesize > file_size_limit) then
		module:log("debug", "%s's upload throttled", username);
		return nil, st.error_reply(stanza, "wait", "resource-constraint", 
			"You're allowed to send upto "..tostring(file_size_limit).." bytes any "..tostring(throttle_time).." seconds");
	elseif filesize > file_size_limit then
		module:log("debug", "File too large (%d > %d)", filesize, file_size_limit);
		return nil, st.error_reply(stanza, "modify", "not-acceptable", "File too large")
			:tag("file-too-large", {xmlns=xmlns})
				:tag("max-file-size"):text(tostring(file_size_limit));
	elseif not check_quota(username, host, filesize) then
		module:log("debug", "Upload of %dB by %s would exceed quota", filesize, origin.full_jid);
		return nil, st.error_reply(stanza, "wait", "resource-constraint", "Quota reached");
	end

	local random_dir = generate_directory();
	if not random_dir then
		module:log("error", "Failed to generate random directory name for %s upload", origin.full_jid);
		return nil, st.error_reply(stanza, "wait", "internal-server-failure");
	end
		
	local created, err = lfs.mkdir(join_path(storage_path, random_dir));

	if not created then
		module:log("error", "Could not create directory for slot: %s", err);
		return nil, st.error_reply(stanza, "wait", "internal-server-failure");
	end

	local ok = datamanager.list_append(username, host, module.name, {
		filename = filename, dir = random_dir, size = filesize, time = os_time() });

	if not ok then
		return nil, st.error_reply(stanza, "wait", "internal-server-failure");
	end

	local slot = random_dir.."/"..filename;
	pending_slots[slot] = origin.full_jid;

	module:add_timer(expire_slot, function()
		pending_slots[slot] = nil;
		if not lfs.attributes(join_path(storage_path, random_dir, filename)) then
			os_remove(join_path(storage_path, random_dir));
		end
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

-- adhoc handler
local adhoc_new = module:require "adhoc".new;

local function purge_uploads(self, data, state)
	local user, host = split(data.from);
	purge_files({ username = user, host = host });
	return { status = "completed", info = "All uploaded files have been removed" };
end

local purge_uploads_descriptor = adhoc_new("Purge HTTP Upload Files", "http_upload_purge", purge_uploads);
module:provides("adhoc", purge_uploads_descriptor);

-- hooks
local function iq_handler(event)
	local stanza, origin = event.stanza, event.origin;
	local request = stanza.tags[1];
	local legacy = request.attr.xmlns == legacy_namespace;
	local filename = legacy and request:get_child_text("filename") or request.attr.filename;
	local filesize = legacy and tonumber(request:get_child_text("size")) or tonumber(request.attr.size);

	local slot_url, err = handle_request(origin, stanza, legacy and legacy_namespace or namespace, filename, filesize);
	if not slot_url then
		origin.send(err);
		return true;
	end

	local reply;
	if legacy then
		reply = st.reply(stanza)
			:tag("slot", { xmlns = legacy_namespace })
				:tag("get"):text(slot_url):up()
				:tag("put"):text(slot_url):up():up();
	else
		reply = st.reply(stanza)
			:tag("slot", { xmlns = namespace })
				:tag("get", { url = slot_url }):up()
				:tag("put", { url = slot_url }):up():up();
	end
	origin.send(reply);
	return true;
end

module:hook("iq/host/"..namespace..":request", iq_handler);
module:hook("iq/host/"..legacy_namespace..":request", iq_handler);

-- http service
local function upload_data(event, path)
	local uploader = pending_slots[path];
	if not uploader then
		module:log("warn", "Attempt to upload to unknown slot %q", path);
		return; -- 404
	end
	local user, host = split(uploader);
	local random_dir, filename = path:match("^([^/]+)/([^/]+)$");
	if not random_dir then
		module:log("warn", "Invalid file path %q", path);
		return 400;
	end
	local size = #event.request.body;
	if size > file_size_limit then
		module:log("warn", "Uploaded file too large %d bytes", size);
		return 400;
	end
	pending_slots[path] = nil;
	local full_filename = join_path(storage_path, random_dir, filename);
	if lfs.attributes(full_filename) then
		module:log("warn", "File %s exists already, not replacing it", full_filename);
		return 409;
	end
	local fh, ferr = open(full_filename, "w");
	if not fh then
		module:log("error", "Could not open file %s for upload: %s", full_filename, ferr);
		return 500;
	end
	local ok, err = fh:write(event.request.body);
	if not ok then
		module:log("error", "Could not write to file %s for upload: %s", full_filename, err);
		os_remove(full_filename);
		os_remove(full_filename:match("^(.*)[/\\]"));
		return 500;
	end
	ok, err = fh:close();
	if not ok then
		module:log("error", "Could not write to file %s for upload: %s", full_filename, err);
		os_remove(full_filename);
		os_remove(full_filename:match("^(.*)[/\\]"));
		return 500;
	end
	if size > 500*1024 then gc(); end

	local bare_user = join(user, host);
	throttle[bare_user] = (throttle[bare_user] and throttle[bare_user] + size) or size;
	local bare_session = bare_sessions[bare_user];
	if not bare_session.upload_timer then
		bare_session.upload_timer = true;
		module:add_timer(throttle_time, function()
			throttle[bare_user] = nil;
			if bare_sessions[bare_user] then bare_sessions[bare_user].upload_timer = nil; end
		end);
	end

	local has_downloads = datamanager.load(nil, host, module.name) or {};
	has_downloads[user] = os_time();
	local ok, err = datamanager.store(nil, host, module.name, has_downloads);
	if err then module:log("warn", "Couldn't save %s's list of users using HTTP Uploads: %s", host, err); end
	module:log("info", "File uploaded by %s to slot %s", uploader, random_dir);
	return 201;
end

local codes = require "net.http.codes";
local headerfix = require "net.http.server".generate_header_fix();

local function send_response_sans_body(response)
	if response.finished then return; end
	response.finished = true;
	response.conn._http_open_response = nil;

	local status_line = "HTTP/"..response.request.httpversion.." "..(response.status or codes[response.status_code]);
	local headers = response.headers;
	if not headers.connection then
		headers.connection = response.keep_alive and "Keep-Alive" or "close";
	end

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
		cached = {}; cache[full_path] = cached;
		cached.attrs = lfs.attributes(full_path);
		if not cached.attrs then return 404; end
		module:add_timer(expire_cache, function()
			cache[full_path] = nil;
			gc();
		end);
	end

	local headers, attrs, data = cached.headers, cached.attrs;
	if not headers then
		headers = response.headers;
		local ext = full_path:match("%.([^%.]*)$");
		headers["Content-Type"] = mime_types[ext and ext:lower()];
		headers["Last-Modified"] = os.date("!%a, %d %b %Y %X GMT", attrs.modification);
		cached.headers = headers;
	else
		headers.date = response.headers.date;
		response.headers = headers;
	end

	if not cached.data and attrs.size <= cacheable_size then
		local f = open(full_path, "rb");
		if f then data = f:read("*a"); f:close(); end

		cached.data = data;
	end

	module:log("debug", "%s sent %s request for uploaded file at: %s (%d bytes)", 
		request.conn:ip(), head and "HEAD" or "GET", path, attrs.size);

	if head then
		if not headers["Content-Length"] then headers["Content-Length"] = attrs.size; end
		response:send();		
	else
		data = cached.data;
		if not data then
			local f = open(full_path, "rb");
			if f then data = f:read("*a"); f:close(); end
		end

		response:send(data);
	end
	if attrs.size > 500*1024 then gc(); end
	return true;
end

local function serve_head(event, path)
	event.response.send = send_response_sans_body;
	return serve_uploaded_files(event, path, true);
end

local function serve_hello(event)
	event.response.headers["Content-Type"] = "text/html";
	return [[<!DOCTYPE html><html><head><title>Metronome's HTTP Upload</title></head><body>
		<p>Welcome! This components implements <a href="https://xmpp.org/extensions/xep-0363.html">XEP-0363</a> and 
		allows you to upload files out-of-band using the HTTP Protocol.</p>
		</body></html>]];
end

module:provides("http", {
	default_path = default_base_path,
	route = {
		["GET"] = serve_hello,
		["GET /"] = serve_hello,
		["GET /*"] = serve_uploaded_files,
		["HEAD /*"] = serve_head,
		["PUT /*"] = upload_data
	}
});

module:hook_global("user-deleted", purge_files, 20);

module:log("info", "URL: <%s>; Storage path: %s", module:http_url(nil, default_base_path), storage_path);

local function clean_timers() -- clean timers
	for jid, bare_session in pairs(bare_sessions) do
		bare_session.upload_timer = nil;
	end
end

module.load = clean_timers();
module.unload = clean_timers();
