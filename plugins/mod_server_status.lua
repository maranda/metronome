-- * Metronome IM *
--
-- This file is part of the Metronome XMPP server and is released under the
-- ISC License, please see the LICENSE file in this source package for more
-- information about copyright and licensing.

module:depends("http")

local base_path = module:get_option_string("server_status_basepath", "/server-status/")
local show_hosts = module:get_option_array("server_status_show_hosts", nil)
local show_comps = module:get_option_array("server_status_show_comps", nil)
local json_output = module:get_option_boolean("server_status_json", false)
local hosts = metronome.hosts

local json_encode = require "util.json".encode

-- code begin

if not stanza_counter and not show_hosts and not show_comps then
	module:log ("error", "mod_server_status requires at least one of the following things:")
	module:log ("error", "mod_stanza_counter loaded, or either server_status_show_hosts or server_status_show_comps configuration values set.")
	return false
end

local response_table = {}
response_table.header = '<?xml version="1.0" encoding="UTF-8" ?>'
response_table.doc_header = '<document>'
response_table.doc_closure = '</document>'
response_table.stanzas = {
		elem_header = '  <stanzas>', elem_closure = '  </stanzas>',
		incoming = '    <incoming iq="%d" message="%d" presence="%d" />', 
		outgoing = '    <outgoing iq="%d" message="%d" presence="%d" />'
}
response_table.hosts = {
		elem_header = '  <hosts>', elem_closure = '  </hosts>',
		status = '    <status name="%s" current="%s" />'
}
response_table.comps = {
		elem_header = '  <components>', elem_closure = '  </components>',
		status = '    <status name="%s" current="%s" />'
}

local function forge_response_xml()
	local hosts_s = {}; local components = {}; local stats = {}; local hosts_stats = {}; local comps_stats = {}

	local function t_builder(t,r) for _, bstring in ipairs(t) do r[#r+1] = bstring end end

	if show_hosts then t_builder(show_hosts, hosts_s) end
	if show_comps then t_builder(show_comps, components) end
	
	-- build stanza stats if there
	local stanzas = response_table.stanzas;
	local stanza_counter = metronome.stanza_counter;

	if stanza_counter then
		stats[1] = stanzas.elem_header
		stats[2] = stanzas.incoming:format(stanza_counter.iq.incoming,
						   stanza_counter.message.incoming,
						   stanza_counter.presence.incoming)
		stats[3] = stanzas.outgoing:format(stanza_counter.iq.outgoing,
						   stanza_counter.message.outgoing,
						   stanza_counter.presence.outgoing)
		stats[4] = stanzas.elem_closure
	end

	-- build hosts stats if there
	local rt_hosts = response_table.hosts

	if hosts_s[1] then
		hosts_stats[1] = rt_hosts.elem_header
		for _, name in ipairs(hosts_s) do 
			hosts_stats[#hosts_stats+1] = rt_hosts.status:format(
				name, hosts[name] and "online" or "offline")
		end
		hosts_stats[#hosts_stats+1] = rt_hosts.elem_closure
	end

	-- build components stats if there
	local comps = response_table.comps

	if components[1] then
		comps_stats[1] = comps.elem_header
		for _, name in ipairs(components) do
			local component = hosts[name].modules.component
			comps_stats[#comps_stats+1] = comps.status:format(
				name, component and component.connected and "online" or 
				hosts[name] and component == nil and "online" or "offline")
		end
		comps_stats[#comps_stats+1] = comps.elem_closure
	end

	-- build xml document
	local result = {}
	result[#result+1] = response_table.header; result[#result+1] = response_table.doc_header -- start
	t_builder(stats, result); t_builder(hosts_stats, result); t_builder(comps_stats, result)
	result[#result+1] = response_table.doc_closure -- end

	return table.concat(result, "\n")
end

local function forge_response_json()
	local result = {}

	if stanza_counter then result.stanzas = {} ; result.stanzas = stanza_counter end
	if show_hosts then
		result.hosts = {}
		for _,n in ipairs(show_hosts) do result.hosts[n] = hosts[n] and "online" or "offline" end
	end
	if show_comps then
		result.components = {}
		for _,n in ipairs(show_comps) do 
			local component = hosts[n].modules.component
			result.components[n] = component and component.connected and "online" or
			hosts[n] and component == nil and "online" or "offline"
		end
	end

	return json_encode(result)
end

-- http handlers

local function request(event)
	local response = event.response
	if not json_output then
		response.headers.content_type = "text/xml"
		response:send(forge_response_xml()) 
	else
		response.headers.content_type = "application/json"
		response:send(forge_response_json())
	end
end

-- initialization.

module:provides("http", {
	default_path = base_path,
        route = {
                ["GET /"] = request
        }
})

