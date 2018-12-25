-- * Metronome IM *
--
-- This file is part of the Metronome XMPP server and is released under the
-- ISC License, please see the LICENSE file in this source package for more
-- information about copyright and licensing.
--
-- As per the sublicensing clause, this file is also MIT/X11 Licensed.
-- ** Copyright (c) 2015-2016, Kim Alvefur

if not module:host_is_component() then
	error("HTTP Upload External should be loaded as a component", 0);
end

-- imports
local datamanager = require "util.datamanager";
local dataforms = require "util.dataforms";
local st = require "util.stanza";
local http = require "net.http";
local dataform = require "util.dataforms".new;
local HMAC = require "util.hmac".sha256;
local seed = require "util.auxiliary".generate_secret;
local jid = require "util.jid";
local user_exists = require "core.usermanager".user_exists;
local generate_directory = require "util.auxiliary".generate_shortid;
local ipairs, pairs, os_time, unpack, t_insert, t_remove =
	ipairs, pairs, os.time, unpack or table.unpack, table.insert, table.remove;

-- config
local file_size_limit = module:get_option_number("http_file_size_limit", 100 * 1024 * 1024); -- 100 MB
local file_auto_cleanup = module:get_option_number("http_file_expire_after", 172800);
local file_cleanup_whitelist = module:get_option_set("http_file_no_expire_whitelist", {});
local base_url = assert(module:get_option_string("http_file_external_url"), "http_file_external_url is a required option");
local delete_base_url = module:get_option_string("http_file_external_delete_url");
local secret = assert(module:get_option_string("http_file_secret"), "http_file_secret is a required option");
local delete_secret = delete_base_url and assert(
	module:get_option_string("http_file_delete_secret"), "http_file_delete_secret is a required option if deletion is enabled");

-- namespace
local legacy_namespace = "urn:xmpp:http:upload";
local namespace = "urn:xmpp:http:upload:0";

-- identity and feature advertising
local disco_name = module:get_option_string("name", "HTTP File Upload");
module:hook("iq/host/http://jabber.org/protocol/disco#info:query", function(event)
	local origin, stanza = event.origin, event.stanza;
	local reply = st.iq({ type = "result", id = stanza.attr.id, from = module.host, to = stanza.attr.from })
		:query("http://jabber.org/protocol/disco#info")
			:tag("identity", { category = "store", type = "file", name = disco_name }):up();

	local query = reply.tags[1];
	if delete_base_url then query:tag("feature", { var = "http://jabber.org/protocol/commands" }):up(); end
	query:tag("feature", { var = "http://jabber.org/protocol/disco#info" }):up();
	query:tag("feature", { var = namespace }):up();
	query:tag("feature", { var = legacy_namespace }):up();

	query:add_child(dataform {
		{ name = "FORM_TYPE", type = "hidden", value = namespace },
		{ name = "max-file-size", type = "text-single" }
	}:form({ ["max-file-size"] = tostring(file_size_limit) })):up();
	query:add_child(dataform {
		{ name = "FORM_TYPE", type = "hidden", value = legacy_namespace },
		{ name = "max-file-size", type = "text-single" }
	}:form({ ["max-file-size"] = tostring(file_size_limit) })):up();
			
	origin.send(reply);
	return true;
end);

local function delete_file(user, host, delete_url, get_url, no_notify)
	http.request(delete_url, { method = "DELETE" },
		function(data, code, req)
			local url_list = datamanager.load(user, host, "http_upload_external") or {};
			if code == 204 then
				module:log("debug", "Successfully deleted uploaded file for %s [%s]", user .."@".. host, get_url);
			else
				module:log("error", "Failed to delete uploaded file for %s [%s]", user .."@".. host, get_url);
				if not no_notify then
					module:send(st.message({ from = module.host, to = user.."@"..host, type = "chat" },
						"The upstream HTTP file service reported it couldn't remove your file located at " .. get_url
						.. ", it's possible the file was removed already or the upload failed."
					));
				end
			end
			for i, url_data in ipairs(url_list) do
				if url_data[2] == get_url then t_remove(url_list, i); break; end
			end
			if #url_list == 0 then
				datamanager.store(user, host, "http_upload_external");
			else
				datamanager.store(user, host, "http_upload_external", url_list);
			end
		end
	);
end

local function auto_cleanup(user, host, url_list)
	for _, url_data in ipairs(url_list) do
		local delete_url, get_url, created_time = unpack(url_data);
		if created_time and os_time() - created_time > file_auto_cleanup then
			module:log("debug", "Expiring file %s", get_url);
			delete_file(user, host, delete_url, get_url, true);
		end
	end	
end

local function purge_files(user, host, no_notify)
	local url_list = datamanager.load(user, host, "http_upload_external");
	if url_list then
		for _, url_data in ipairs(url_list) do
			local delete_url, get_url = unpack(url_data);
			delete_file(user, host, delete_url, get_url, no_notify);
		end
	end
end

local function magic_crypto_dust(random, filename, value, filetype)
	local message, url;
	if type(value) == "string" then
		url = delete_base_url;
		message = string.format("%s/%s\0%s", random, filename, value);
	else
		url = base_url;
		message = string.format("%s/%s\0%d\0%s", random, filename, value, filetype);
	end
	local digest = HMAC(secret, message, true);
	random, filename = http.urlencode(random), http.urlencode(filename);
	return url .. random .. "/" .. filename, "?token=" .. digest;
end

local function handle_request(origin, stanza, xmlns, filename, filesize, filetype)
	-- local clients only
	if origin.type ~= "c2s" then
		module:log("debug", "Request for upload slot from a %s", origin.type);
		origin.send(st.error_reply(stanza, "cancel", "not-authorized"));
		return;
	end
	-- validate
	if not filename or filename:find("/") then
		module:log("debug", "Filename %q not allowed", filename or "");
		origin.send(st.error_reply(stanza, "modify", "bad-request", "Invalid filename"));
		return;
	end
	if not filesize then
		module:log("debug", "Missing file size");
		origin.send(st.error_reply(stanza, "modify", "bad-request", "Missing or invalid file size"));
		return;
	elseif filesize > file_size_limit then
		module:log("debug", "File too large (%d > %d)", filesize, file_size_limit);
		origin.send(st.error_reply(stanza, "modify", "not-acceptable", "File too large",
			st.stanza("file-too-large", { xmlns = xmlns })
				:tag("max-size"):text(tostring(file_size_limit))));
		return;
	end
	local random = generate_directory();
	local get_url, verify = magic_crypto_dust(random, filename, filesize, filetype);
	local put_url = get_url .. verify;

	if delete_base_url then
		local delete_url, delete_verify = magic_crypto_dust(random, filename, delete_secret);
		local url_list = datamanager.load(origin.username, origin.host, "http_upload_external") or {};
		t_insert(url_list, { delete_url .. delete_verify, get_url,
			not file_cleanup_whitelist:contains(jid.bare(origin.full_jid)) and os_time() or nil });
		datamanager.store(origin.username, origin.host, "http_upload_external", url_list);
		auto_cleanup(origin.username, origin.host, url_list);
	end

	module:log("debug", "Handing out upload slot %s to %s@%s [%d %s]", get_url, origin.username, origin.host, filesize, filetype);

	return get_url, put_url;
end

local function handle_iq(event)
	local stanza, origin = event.stanza, event.origin;
	local request = stanza.tags[1];
	local legacy = request.attr.xmlns == legacy_namespace;
	local filename = legacy and request:get_child_text("filename") or request.attr.filename;
	local filesize = legacy and tonumber(request:get_child_text("size")) or tonumber(request.attr.size);
	local filetype = (legacy and request:get_child_text("content-type") or request.attr["content-type"]) or "application/octet-stream";

	local get_url, put_url = handle_request(origin, stanza, legacy and legacy_namespace or namespace, filename, filesize, filetype);

	if not get_url then return true; end

	local reply;
	if legacy then
		reply = st.reply(stanza)
			:tag("slot", { xmlns = legacy_namespace })
				:tag("get"):text(get_url):up()
				:tag("put"):text(put_url):up():up();
	else
		reply = st.reply(stanza)
			:tag("slot", { xmlns = namespace })
				:tag("get", { url = get_url }):up()
				:tag("put", { url = put_url }):up():up();
	end
	origin.send(reply);
	return true;
end

-- adhoc functions
local function list_layout(data)
	local layout = {
		title = "List requested upload slots";
		instructions = "Select which uploads to attempt to delete from the upstream sharing service.";
		{ name = "FORM_TYPE", type = "hidden", value = "http://jabber.org/protocol/commands" };
	}

	for i, url_data in ipairs(data) do
		t_insert(layout, {
			name = url_data[2],
			type = "list-single",
			label = url_data[2],
			value = {
				{ value = "none", default = true },
				{ value = "remove" }
			}
		});
	end
	
	return dataforms.new(layout);
end

local function delete_uploads(self, data, state)
	local user, host = jid.split(data.from);

	if state then
		if data.action == "cancel" then return { status = "canceled" }; end
		local layout, url_list = state.layout, state.url_list;
		local fields = layout:data(data.form);
		fields["FORM_TYPE"] = nil;
	
		local to_remove = {};
		for name, action in pairs(fields) do
			if action == "remove" then to_remove[name] = true; end
		end
		for i, url_data in ipairs(url_list) do
			local delete_url, get_url = unpack(url_data);
			if to_remove[get_url] then
				delete_file(user, host, delete_url, get_url);
			end
		end

		return { status = "completed", info = "Done" };
	else
		local url_list = datamanager.load(user, host, "http_upload_external")
		if not url_list then
			return { status = "complete", error = { message = "You have no uploads" } };
		else
			local layout = list_layout(url_list);
			return { status = "executing", form = layout }, { url_list = url_list, layout = layout };
		end
	end
end

local purge_others_layout = dataforms.new{
	title = "Purge uploads for a given user";
	instructions = "This command allows global admins to signal the upstream server to purge downloads for a given user.";
	{ name = "FORM_TYPE", type = "hidden", value = command_xmlns };
	{ name = "jid", type = "text-single", label = "User Jid" };
};

local function purge_uploads(self, data, state)
	local user, host = jid.split(data.from);
	purge_files(user, host);
	return { status = "completed", info = "Purge request sent to the upstream file server" };
end

local function purge_others_uploads(self, data, state)
	if state then
		if data.action == "cancel" then return { status = "canceled" }; end
		local fields = purge_others_layout:data(data.form);

		if fields.jid then
			local user, host = jid.split(jid.prep(fields.jid));

			if not user or not host then
				return { status = "completed", error = { message = "Supplied JID is not valid" } };
			end

			if user_exists(user, host) then
				purge_files(user, host, true);
				return { status = "completed", info = "Purge request sent to the upstream file server" };
			else
				return { status = "completed", error = { message = "User doesn't exist" } };
			end
		else
			return { status = "completed", error = { message = "You need to supply the User JID" } };
		end
	else
		return { status = "executing", form = purge_others_layout }, "executing";
	end
end

-- handlers and hooks
if delete_base_url then
	local adhoc_new = module:require "adhoc".new;
	local delete_uploads_descriptor = adhoc_new("Delete Single Files", "http_upload_delete", delete_uploads, "server_user");
	local purge_uploads_descriptor = adhoc_new("Purge All Uploaded Files", "http_upload_purge", purge_uploads, "server_user");
	local purge_others_uploads_descriptor = adhoc_new("Issue Purge for Another User's Uploaded Files", "http_upload_purge_others", 
		purge_others_uploads, "global_admin");
	module:provides("adhoc", delete_uploads_descriptor);
	module:provides("adhoc", purge_uploads_descriptor);
	module:provides("adhoc", purge_others_uploads_descriptor);
	module:hook_global("user-deleted", function(event) purge_files(event.username, event.host, true); end, 20);
end

module:hook("iq/host/"..legacy_namespace..":request", handle_iq);
module:hook("iq/host/"..namespace..":request", handle_iq);
