
local st = require "util.stanza";
module:depends("http");
local uuid_new = require "util.uuid".generate;
local os_time = os.time;
local t_insert, t_remove = table.insert, table.remove;
local add_task = require "util.timer".add_task;

local utf8_pattern = "[\194-\244][\128-\191]*$";
local function drop_invalid_utf8(seq)
	local start = seq:byte();
	module:log("utf8: %d, %d", start, #seq);
	if (start <= 223 and #seq < 2)
	or (start >= 224 and start <= 239 and #seq < 3)
	or (start >= 240 and start <= 244 and #seq < 4)
	or (start > 244) then
		return "";
	end
	return seq;
end

local function utf8_length(str)
	local _, count = string.gsub(str, "[^\128-\193]", "");
	return count;
end

local pastebin_private_messages = module:get_option_boolean("pastebin_private_messages", hosts[module.host].type ~= "component");
local length_threshold = module:get_option_number("pastebin_threshold", 500);
local line_threshold = module:get_option_number("pastebin_line_threshold", 4);
local max_summary_length = module:get_option_number("pastebin_summary_length", 150);
local html_preview = module:get_option_boolean("pastebin_html_preview", true);

local base_url = module:get_option_string("pastebin_url");

-- Seconds a paste should live for in seconds (config is in hours), default 24 hours
local expire_after = math.floor(module:get_option_number("pastebin_expire_after", 24) * 3600);

local trigger_string = module:get_option_string("pastebin_trigger");
trigger_string = (trigger_string and trigger_string .. " ");

local pastes = {};
local default_headers = { ["Content-Type"] = "text/plain; charset=utf-8" };

local xmlns_xhtmlim = "http://jabber.org/protocol/xhtml-im";
local xmlns_xhtml = "http://www.w3.org/1999/xhtml";

function pastebin_text(text)
	local uuid = uuid_new();
	pastes[uuid] = { body = text, time = os_time(), headers = default_headers };
	pastes[#pastes+1] = uuid;
	if not pastes[2] then -- No other pastes, give the timer a kick
		add_task(expire_after, expire_pastes);
	end
	return base_url..uuid;
end

function handle_request(event, pasteid)
	if not pasteid or not pastes[pasteid] then
		return "Invalid paste id, perhaps it expired?";
	end
	
	--module:log("debug", "Received request, replying: %s", pastes[pasteid].text);
	
	return pastes[pasteid];
end

function check_message(data)
	local origin, stanza = data.origin, data.stanza;
	
	local body, bodyindex, htmlindex;
	for k,v in ipairs(stanza) do
		if v.name == "body" then
			body, bodyindex = v, k;
		elseif v.name == "html" and v.attr.xmlns == xmlns_xhtmlim then
			htmlindex = k;
		end
	end
	
	if not body then return; end
	body = body:get_text();
	
	--module:log("debug", "Body(%s) length: %d", type(body), #(body or ""));
	
	if body and (
		((#body > length_threshold)
		 and (utf8_length(body) > length_threshold)) or
		(trigger_string and body:find(trigger_string, 1, true) == 1) or
		(select(2, body:gsub("\n", "%0")) >= line_threshold)
	) then
		if trigger_string then
			body = body:gsub("^" .. trigger_string, "", 1);
		end
		local url = pastebin_text(body);
		module:log("debug", "Pasted message as %s", url);		
		--module:log("debug", " stanza[bodyindex] = %q", tostring( stanza[bodyindex]));
		local summary = (body:sub(1, max_summary_length):gsub(utf8_pattern, drop_invalid_utf8) or ""):match("[^\n]+") or "";
		summary = summary:match("^%s*(.-)%s*$");
		local summary_prefixed = summary:match("[,:]$");
		stanza[bodyindex][1] = (summary_prefixed and (summary.." ") or "")..url;
		
		if html_preview then
			local line_count = select(2, body:gsub("\n", "%0")) + 1;
			local link_text = ("[view %spaste (%d line%s)]"):format(summary_prefixed and "" or "rest of ", line_count, line_count == 1 and "" or "s");
			local html = st.stanza("html", { xmlns = xmlns_xhtmlim }):tag("body", { xmlns = xmlns_xhtml });
			html:tag("p"):text(summary.." "):up();
			html:tag("a", { href = url }):text(link_text):up();
			stanza[htmlindex or #stanza+1] = html;
		end
	end
end

module:hook("message/bare", check_message);
if pastebin_private_messages then
	module:hook("message/full", check_message);
end

function expire_pastes(time)
	time = time or os_time(); -- COMPAT with 0.5
	if pastes[1] then
		pastes[pastes[1]] = nil;
		t_remove(pastes, 1);
		if pastes[1] then
			return (expire_after - (time - pastes[pastes[1]].time)) + 1;
		end
	end
end


module:provides("http", {
	route = {
		["GET /*"] = handle_request;
	};
});

local function set_pastes_metatable()
	if expire_after == 0 then
		local dm = require "util.datamanager";
		setmetatable(pastes, {
			__index = function (pastes, id)
				if type(id) == "string" then
					return dm.load(id, module.host, "pastebin");
				end
			end;
			__newindex = function (pastes, id, data)
				if type(id) == "string" then
					dm.store(id, module.host, "pastebin", data);
				end
			end;
		});
	else
		setmetatable(pastes, nil);
	end
end

module.load = set_pastes_metatable;

function module.save()
	return { pastes = pastes };
end

function module.restore(data)
	pastes = data.pastes or pastes;
	set_pastes_metatable();
end
