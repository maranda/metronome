local st = require "util.stanza";
local jid = require "util.jid";

local patterns = config.get(module:get_host(), "core", "messagefilter_patterns") or {};
local hosts = config.get(module:get_host(), "core", "messagefilter_chosts") or {};

local bounce_message = config.get(module:get_host(), "core", "messagefilter_bmsg") or "Message rejected by server filter";

local function message_filter(data)
	local origin, stanza = data.origin, data.stanza;
	local body = stanza:child_with_name("body");
	local fromnode, fromhost = jid.split(stanza.attr.from);

	local error_reply = st.message{ type = "error", from = stanza.attr.to.."/ServerFilter" }
					:tag("error", {type = "modify"})
						:tag("not-acceptable", {xmlns = "urn:ietf:params:xml:ns:xmpp-stanzas"})
							:tag("text", {xmlns = "urn:ietf:params:xml:ns:xmpp-stanzas"}):text(bounce_message):up();

	if body then
		if #body.tags ~= 0 then
			origin.send(st.error_reply(stanza, "modify", "not-acceptable", "Your client sent an invalid message"));
			return true;
		end

		local test_host = false;
		for _, host in ipairs(hosts) do
			if fromhost == host then test_host = true; break; end
		end
		
		for _, pattern in ipairs(patterns) do
			if test_host then
				if body[1]:match(pattern) then
					error_reply.attr.to = stanza.attr.from;
					origin.send(error_reply);
					module:log("info", "Bounced message from anon user %s because it contained profanity", stanza.attr.from);
					return true; -- Drop the stanza now
				end
			end
		end
	end
end


function module.load()
	module:hook("message/bare", message_filter, 500);
	module:hook("message/full", message_filter, 500);
	module:hook("message/host", message_filter, 500);
end

