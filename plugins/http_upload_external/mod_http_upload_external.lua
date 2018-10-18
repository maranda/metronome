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
local st = require "util.stanza";
local http = require "net.http";
local dataform = require "util.dataforms".new;
local HMAC = require "util.hmac".sha256;
local seed = require "util.auxiliary".generate_secret;
local jid = require "util.jid";
local os_time, t_insert, t_remove = os.time, table.insert, table.remove;

-- config
local file_size_limit = module:get_option_number("http_file_size_limit", 100 * 1024 * 1024); -- 100 MB
local base_url = assert(module:get_option_string("http_file_external_url"), "http_file_external_url is a required option");
local secret = assert(module:get_option_string("http_file_secret"), "http_file_secret is a required option");
local delete_secret = assert(module:get_option_string("http_file_delete_secret"), "http_file_delete_secret is a required option");

-- namespace
local legacy_namespace = "urn:xmpp:http:upload";
local namespace = "urn:xmpp:http:upload:0";

-- identity and feature advertising
local disco_name = module:get_option_string("name", "HTTP File Upload");
module:hook("iq/host/http://jabber.org/protocol/disco#info:query", function(event)
	local origin, stanza = event.origin, event.stanza;
	local reply = st.iq({ type = "result", id = stanza.attr.id, from = module.host, to = stanza.attr.from })
		:query("http://jabber.org/protocol/disco#info")
			:tag("identity", { category = "store", type = "file", name = disco_name }):up()
			:tag("feature", { var = "http://jabber.org/protocol/commands" }):up()
			:tag("feature", { var = "http://jabber.org/protocol/disco#info" }):up()
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

local function purge_files(user, host)
	local url_list = datamanager.load(user, host, "http_upload_external");
	if url_list then
		local last = url_list[#url_list];
		for i, url in ipairs(url_list) do
			http.request(url, { method = "DELETE" },
				function(data, code, req)
					if code == 204 then
						module:log("debug", "Successfully deleted uploaded file for %s [%s]", user .."@".. host, url);
						t_remove(url_list, i);
					else
						module:log("error", "Failed to delete uploaded file for %s [%s]", user .."@".. host, url);
						module:send(st.message({ from = module.host, to = user.."@"..host, type = "chat" },
							"The upstream HTTP file service reported to have failed to remove your file located at ".. url
							.. ", if the problem persists please contact an administrator, thank you."
						));
					end
					if url == last then
						if not next(url_list) then
							datamanager.store(user, host, "http_upload_external");
						else
							datamanager.store(user, host, "http_upload_external", url_list);
						end
					end
				end
			);
		end
	end
end

local function generate_directory()
	local bits = seed(9);
	return bits and bits:gsub("/", ""):gsub("%+", "") .. tostring(os_time()):match("%d%d%d%d$");
end

local function magic_crypto_dust(random, filename, filesize, filetype)
	local message = string.format("%s/%s\0%d\0%s", random, filename, filesize, filetype);
	local digest = HMAC(secret, message, true);
	random, filename = http.urlencode(random), http.urlencode(filename);
	return base_url .. random .. "/" .. filename, "?token=" .. digest;
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
	local _, delete_verify = magic_crypto_dust(random, filename, delete_secret, filetype);
	local put_url = get_url .. verify;

	local url_list = datamanager.load(origin.username, origin.host, "http_upload_external") or {};
	t_insert(url_list, get_url .. delete_verify);
	datamanager.store(origin.username, origin.host, "http_upload_external", url_list);

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

-- adhoc handler
local adhoc_new = module:require "adhoc".new;

local function purge_uploads(self, data, state)
	local user, host = jid.split(data.from);
	purge_files(user, host);
	return { status = "completed", info = "Sent purge request to the upstream file server" };
end

local purge_uploads_descriptor = adhoc_new("Purge HTTP Upload Files", "http_upload_purge", purge_uploads, "server_user");
module:provides("adhoc", purge_uploads_descriptor);

-- hooks
module:hook("iq/host/"..legacy_namespace..":request", handle_iq);
module:hook("iq/host/"..namespace..":request", handle_iq);
