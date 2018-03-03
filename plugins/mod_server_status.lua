-- * Metronome IM *
--
-- This file is part of the Metronome XMPP server and is released under the
-- ISC License, please see the LICENSE file in this source package for more
-- information about copyright and licensing.

module:depends("http")

local ipairs, pairs, next = ipairs, pairs, next

local base_path = module:get_option_string("server_status_basepath", "/server-status/")
local show_hosts = module:get_option_array("server_status_show_hosts", nil)
local show_comps = module:get_option_array("server_status_show_comps", nil)
local json_output = module:get_option_boolean("server_status_json", false)
local metronome = metronome
local pposix = pposix
local hosts = metronome.hosts
local NULL = {}

local json_encode = require "util.json".encode

-- code begin

local response_table = {}
response_table.header = '<?xml version="1.0" encoding="UTF-8" ?>'
response_table.doc_header = '<document>'
response_table.doc_closure = '</document>'
response_table.memory = {
		elem_header = '  <memory>', elem_closure = '  </memory>',
		allocated = '    <allocated bytes="%d" />', 
		used = '    <used bytes="%d" />'
}
response_table.stanzas = {
		elem_header = '  <stanzas>', elem_closure = '  </stanzas>',
		incoming = '    <incoming-routed iq="%d" message="%d" presence="%d" />', 
		outgoing = '    <outgoing-routed iq="%d" message="%d" presence="%d" />'
}
response_table.sessions = {
		elem_header = '  <sessions>', elem_closure = '  </sessions>',
		bosh = '    <bosh number="%d" />',
		ws = '    <websockets number="%d" />',
		c2s = '    <c2s number="%d" />',
		s2s = '    <s2s incoming="%d" outgoing="%d" bidi="%d" />'
}
response_table.hosts = {
		elem_header = '  <hosts>', elem_closure = '  </hosts>',
		status = '    <status name="%s" current="%s" />'
}
response_table.comps = {
		elem_header = '  <components>', elem_closure = '  </components>',
		status = '    <status name="%s" current="%s" />'
}

local function count_sessions()
	local count_c2s, count_bosh, count_bidi, count_ws, count_s2sin, count_s2sout = 0, 0, 0, 0, 0, 0
	local incoming_s2s = metronome.incoming_s2s

	for name, host in pairs(hosts) do
		for _, user in pairs(host.sessions or NULL) do
			for resource, session in pairs(user.sessions or NULL) do
				if session.bosh_version then
					count_bosh = count_bosh + 1
				elseif session.ws_session then
					count_ws = count_ws + 1
				else
					count_c2s = count_c2s + 1
				end
			end
		end

		for _, session in pairs(host.s2sout or NULL) do
			if session.bidirectional then 
				count_bidi = count_bidi + 1 
			else
				count_s2sout = count_s2sout + 1			
			end
		end
	end

	for session in pairs(incoming_s2s) do 
		if session.bidirectional then
			count_bidi = count_bidi + 1 
		else
			count_s2sin = count_s2sin + 1
		end
	end

	return count_c2s, count_bosh, count_bidi, count_ws, count_s2sin, count_s2sout
end

local function t_builder(t,r) 
	for _, bstring in ipairs(t) do r[#r+1] = bstring end
end

local function forge_response_xml()
	local hosts_s, components, stats, mem_stats, hosts_stats, comps_stats, sessions_stats = {}, {}, {}, {}, {}, {}, {}

	if show_hosts then t_builder(show_hosts, hosts_s) end
	if show_comps then t_builder(show_comps, components) end

	-- total sessions handled by the server
	local count_c2s, count_bosh, count_bidi, count_ws, count_s2sin, count_s2sout = count_sessions()
	local sessions = response_table.sessions
	
	sessions_stats[1] = sessions.elem_header
	sessions_stats[2] = sessions.bosh:format(count_bosh)
	sessions_stats[3] = sessions.ws:format(count_ws)
	sessions_stats[4] = sessions.c2s:format(count_c2s)
	sessions_stats[5] = sessions.s2s:format(count_s2sin, count_s2sout, count_bidi)
	sessions_stats[6] = sessions.elem_closure
	
	-- if pposix is there build memory stats
	if pposix then
		local info = pposix.meminfo()
		local mem = response_table.memory
		mem_stats[1] = mem.elem_header
		mem_stats[2] = mem.allocated:format(info.allocated)
		mem_stats[3] = mem.used:format(info.used)
		mem_stats[4] = mem.elem_closure
	end
	
	-- build stanza stats if there
	local stanza_counter = metronome.stanza_counter

	if stanza_counter then
		local stanzas = response_table.stanzas
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

	if hosts_s[1] then
		local rt_hosts = response_table.hosts
		hosts_stats[1] = rt_hosts.elem_header
		for _, name in ipairs(hosts_s) do 
			hosts_stats[#hosts_stats+1] = rt_hosts.status:format(
				name, hosts[name] and "online" or "offline")
		end
		hosts_stats[#hosts_stats+1] = rt_hosts.elem_closure
	end

	-- build components stats if there

	if components[1] then
		local comps = response_table.comps
		comps_stats[1] = comps.elem_header
		for _, name in ipairs(components) do
			local component = hosts[name] and hosts[name].modules.component
			comps_stats[#comps_stats+1] = comps.status:format(
				name, component and component.connected and "online" or 
				hosts[name] and component == nil and "online" or "offline")
		end
		comps_stats[#comps_stats+1] = comps.elem_closure
	end

	-- build xml document
	local result = {}
	result[#result+1] = response_table.header; result[#result+1] = response_table.doc_header -- start
	t_builder(stats, result) ; t_builder(mem_stats, result) ; t_builder(sessions_stats, result)
	t_builder(hosts_stats, result) ; t_builder(comps_stats, result)
	result[#result+1] = response_table.doc_closure -- end

	return table.concat(result, "\n")
end

local function forge_response_json()
	local result = {}
	local stanza_counter = metronome.stanza_counter
	local count_c2s, count_bosh, count_bidi, count_ws, count_s2sin, count_s2sout = count_sessions()	

	if stanza_counter then
		result.stanzas = {}
		result.stanzas["iq-routed"] = stanza_counter.iq
		result.stanzas["message-routed"] = stanza_counter.message
		result.stanzas["presence-routed"] = stanza_counter.presence
	end

	result.sessions = {} ; local sessions = result.sessions
	sessions.bosh = count_bosh ; sessions.ws = count_ws ;  sessions.c2s = count_c2s
	sessions.s2s = { incoming = count_s2sin, outgoing = count_s2sout, bidi = count_bidi  }
	
	if pposix then
		local info = pposix.meminfo()
		result.memory = {} ; local memory = result.memory
		memory.allocated = { bytes = info.allocated } ; memory.used = { bytes = info.used }
	end

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

