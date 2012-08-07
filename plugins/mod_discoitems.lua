-- mod_discoitems.lua
--
-- In the config, you can add:
--
-- disco_items = {
--  {"proxy.eu.jabber.org", "Jabber.org SOCKS5 service"};
--  {"conference.jabber.org", "The Jabber.org MUC"};
-- };
--

local st = require "util.stanza";

local result_query = st.stanza("query", {xmlns="http://jabber.org/protocol/disco#items"});
for _, item in ipairs(module:get_option("disco_items") or {}) do
	result_query:tag("item", {jid=item[1], name=item[2]}):up();
end

module:hook('iq/host/http://jabber.org/protocol/disco#items:query', function(event)
	local stanza = event.stanza;
	local query = stanza.tags[1];
	if stanza.attr.type == 'get' and not query.attr.node then
		event.origin.send(st.reply(stanza):add_child(result_query));
		return true;
	end
end, 100);
