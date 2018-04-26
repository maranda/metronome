-- * Metronome IM *
--
-- This file is part of the Metronome XMPP server and is released under the
-- ISC License, please see the LICENSE file in this source package for more
-- information about copyright and licensing.
--
-- As per the sublicensing clause, this file is also MIT/X11 Licensed.
-- ** Copyright (c) 2009-2013, Kim Alvefur, Matthew Wild, Tobias Markmann, Waqas Hussain

module:set_component_inheritable();

local st = require "util.stanza";
local zlib = require "zlib";
local add_task = require "util.timer".add_task;
local pcall = pcall;
local tostring = tostring;
local config_get, module_unload = require "core.configmanager".get, require "core.modulemanager".unload;

local xmlns_compression_feature = "http://jabber.org/features/compress";
local xmlns_compression_protocol = "http://jabber.org/protocol/compress";
local xmlns_stream = "http://etherx.jabber.org/streams";
local compression_stream_feature = st.stanza("compression", {xmlns = xmlns_compression_feature}):tag("method"):text("zlib"):up();
local add_filter = require "util.filters".add_filter;

local compression_level = module:get_option_number("compression_level", 7);
local size_limit = module:get_option_number("compressed_data_max_size", 131072);
local ssl_compression = config_get("*", "ssl_compression");

local host_session = hosts[module.host];

if ssl_compression then
	module:log("error", "TLS compression is enabled, mod_compression won't work with this setting on");
	module_unload(module.host, "compression");
	return;
end

if compression_level < 1 or compression_level > 9 then
	module:log("warn", "Valid compression level range is 1-9, found in config: %s", tostring(compression_level));
	module:log("warn", "Using standard level (7) instead");
	compression_level = 7;
end

module:hook("config-reloaded", function()
	compression_level = module:get_option_number("compression_level", 7);
	size_limit = module:get_option_number("compressed_data_max_size", 131072);
	ssl_compression = config_get("*", "ssl_compression");
	if ssl_compression then
		module:log("error", "mod_compression won't work with TLS compression enabled, unloading module");
		module_unload(module.host, "compression");
		return;
	end
	if compression_level < 1 or compression_level > 9 then
		module:log("warn", "mod_compression valid compression value range is 1-9");
		module:log("warn", "value in config is: %s, replacing with standard", tostring(compression_level));
		compression_level = 7;
	end
end);

module:hook("stream-features", function(event)
	local origin, features = event.origin, event.features;
	if not origin.compressed and origin.type == "c2s" then
		features:add_child(compression_stream_feature);
	end
end, 100);

module:hook("s2s-stream-features", function(event)
	local origin, features = event.origin, event.features;
	if not origin.compressed and (origin.type == "s2sin_unauthed" or origin.type == "s2sin") then
		features:add_child(compression_stream_feature);
	end
end, 100);

-- Hook to activate compression if remote server supports it.
module:hook_stanza(xmlns_stream, "features", function(session, stanza)
	if not session.compressed and not session.compressing and (session.type == "s2sout_unauthed" or session.type == "s2sout") then
		local comp_st = stanza:child_with_name("compression");
		if comp_st then
			for a in comp_st:children() do
				local algorithm = a[1]
				if algorithm == "zlib" then
					session.log("debug", "Preparing to enable compression...");
					session.compressing = true;
					return;
				end
			end
			session.log("debug", "Remote server supports no compression algorithm we support");
		end
	end
end, 250);

module:hook("s2sout-established", function(event)
	local session = event.session;
	if session.compressing then
		add_task(3, function()
			if not session.destroyed then
				session.compressing = nil;
				(session.sends2s or session.send)(
					st.stanza("compress", {xmlns = xmlns_compression_protocol}):tag("method"):text("zlib")
				);
			end
		end);
	end
end);

-- returns either nil or a fully functional ready to use inflate stream
local function get_deflate_stream(session)
	local status, deflate_stream = pcall(zlib.deflate, compression_level);
	if status == false then
		local error_st = st.stanza("failure", {xmlns = xmlns_compression_protocol}):tag("setup-failed");
		(session.sends2s or session.send)(error_st);
		session.log("error", "Failed to create zlib.deflate filter");
		module:log("error", "%s", tostring(deflate_stream));
		return;
	end
	return deflate_stream;
end

-- returns either nil or a fully functional ready to use inflate stream
local function get_inflate_stream(session)
	local status, inflate_stream = pcall(zlib.inflate);
	if status == false then
		local error_st = st.stanza("failure", {xmlns = xmlns_compression_protocol}):tag("setup-failed");
		(session.sends2s or session.send)(error_st);
		session.log("error", "Failed to create zlib.inflate filter");
		module:log("error", "%s", tostring(inflate_stream));
		return;
	end
	return inflate_stream;
end

-- setup compression for a stream
local function setup_compression(session, deflate_stream)
	add_filter(session, "bytes/out", function(t)
		local status, compressed, eof = pcall(deflate_stream, tostring(t), "sync");
		if status == false then
			module:log("warn", "Decompressed data processing failed: %s", tostring(compressed));
			session:close({
				condition = "undefined-condition";
				text = compressed;
				extra = st.stanza("failure", {xmlns = "http://jabber.org/protocol/compress"}):tag("processing-failed");
			});
			return;
		end
		return compressed;
	end);	
end

-- setup decompression for a stream
local function setup_decompression(session, inflate_stream)
	add_filter(session, "bytes/in", function(data)
		local status, decompressed, eof;
		if data and #data > size_limit then
			status, decompressed = false, "Received compressed data exceeded the max allowed size!";
		else
			status, decompressed, eof = pcall(inflate_stream, data);
		end

		if status == false then
			module:log("warn", "Compressed data processing failed: %s", tostring(decompressed));
			session:close({
				condition = "undefined-condition";
				text = decompressed;
				extra = st.stanza("failure", {xmlns = "http://jabber.org/protocol/compress"}):tag("processing-failed");
			});
			return;
		end
		return decompressed;
	end);
end

module:hook("stanza/http://jabber.org/protocol/compress:compressed", function(event)
	local session = event.origin;
	
	if session.type == "s2sout" then
		session.log("debug", "Activating compression...")
		local deflate_stream = get_deflate_stream(session);
		if not deflate_stream then return true; end
		
		local inflate_stream = get_inflate_stream(session);
		if not inflate_stream then return true; end
		
		setup_compression(session, deflate_stream);
		setup_decompression(session, inflate_stream);
		session:reset_stream();
		session:open_stream();
		session.compressed = true;
		module:fire_event("s2sout-compressed", session);
		return true;
	end
end);

module:hook("stanza/http://jabber.org/protocol/compress:compress", function(event)
	local session, stanza = event.origin, event.stanza;

	if session.type == "c2s" or (session.type == "s2sin_unauthed" or session.type == "s2sin") then
		if session.type == "s2sin_unauthed" then
			-- This is mainly a compat for M-Link
			module:log("warn", "%s is enabling compression before authenticating!", session.from_host);
		end

		if session.compressed then
			local error_st = st.stanza("failure", {xmlns = xmlns_compression_protocol}):tag("setup-failed");
			(session.sends2s or session.send)(error_st);
			session.log("debug", "Client tried to establish another compression layer");
			return true;
		end
		
		local method = stanza:child_with_name("method");
		method = method and (method[1] or "");
		if method == "zlib" then
			session.log("debug", "zlib compression enabled");
			
			-- create deflate and inflate streams
			local deflate_stream = get_deflate_stream(session);
			if not deflate_stream then return true; end
			
			local inflate_stream = get_inflate_stream(session);
			if not inflate_stream then return true; end

			(session.sends2s or session.send)(st.stanza("compressed", {xmlns = xmlns_compression_protocol}));
			
			setup_compression(session, deflate_stream);
			setup_decompression(session, inflate_stream);
			session:reset_stream();
			session.compressed = true;
			module:fire_event(session.type .. "-compressed", session);
		elseif method then
			session.log("debug", "%s compression selected, but we don't support it", tostring(method));
			local error_st = st.stanza("failure", {xmlns = xmlns_compression_protocol}):tag("unsupported-method");
			(session.sends2s or session.send)(error_st);
		else
			(session.sends2s or session.send)(st.stanza("failure", {xmlns = xmlns_compression_protocol}):tag("setup-failed"));
		end
		return true;
	else
		return (session.sends2s or session.send)(
			st.stanza("failure", { xmlns = xmlns_compression_protocol })
				:tag("error", { type = "auth" })
					:tag("not-authorized", { xmlns = "urn:ietf:params:xml:ns:xmpp-stanzas" }):up()
					:tag("text", { xmlns = "urn:ietf:params:xml:ns:xmpp-stanzas" }):text(
						"Authentication is required, before compressing a stream"
					):up():up()
		);
	end
end);

module:hook("stanza/http://jabber.org/protocol/compress:failure", function(event)
	local session, stanza = event.origin, event.stanza;
	session.log("warn", "Remote entity refused to enable compression, failure stanza dump: %s", tostring(stanza));
	return true;
end);

