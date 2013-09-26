-- * Metronome IM *
--
-- This file is part of the Metronome XMPP server and is released under the
-- ISC License, please see the LICENSE file in this source package for more
-- information about copyright and licensing.

module:depends("adhoc")

local datamanager = require "util.datamanager"
local dataforms_new = require "util.dataforms".new
local st = require "util.stanza"
local id_gen = require "util.uuid".generate

local pairs, os_time, setmetatable = pairs, os.time, setmetatable

local xmlns_inc = "urn:xmpp:incident:2"
local xmlns_iodef = "urn:ietf:params:xml:ns:iodef-1.0"

local my_host = module:get_host()
local ih_lib = module:require("incidents_handling")
ih_lib.set_my_host(my_host)
incidents = {}

local expire_time = module:get_option_number("incidents_expire_time", 0)

-- Incidents Table Methods

local _inc_mt = {} ; _inc_mt.__index = _inc_mt

function _inc_mt:init()
	self:clean() ; self:save()			
end

function _inc_mt:clean()
	if expire_time > 0 then
		for id, incident in pairs(self) do
			if ((os_time() - incident.time) > expire_time) and incident.status ~= "open" then
				incident = nil
			end
		end
	end
end

function _inc_mt:save()
	if not datamanager.store("incidents", my_host, "incidents_store", incidents) then
		module:log("error", "Failed to save the incidents store!")
	end
end

function _inc_mt:add(stanza, report)
	local data = ih_lib.stanza_parser(stanza)
	local new_object = {
		time = os_time(),
		status = (not report and "open") or nil,
		data = data
	}

	self[data.id.text] = new_object
	self:clean() ; self:save()
end

function _inc_mt:new_object(fields, formtype)
	local start_time, end_time, report_time = fields.started, fields.ended, fields.reported

	local _desc, _contacts, _related, _impact, _sources, _targets = fields.description, fields.contacts, fields.related, fields.impact, fields.sources, fields.targets
	local fail = false

	local _lang, _dtext = _desc:match("^(%a%a)%s(.*)$")
	if not _lang or not _dtext then return false end
	local desc = { text = _dtext, lang = _lang }

	local contacts = {}	
	for contact in _contacts:gmatch("[%w%p]+%s[%w%p]+%s[%w%p]+") do
		local address, atype, role = contact:match("^([%w%p]+)%s([%w%p]+)%s([%w%p]+)$")
		if not address or not atype or not role then fail = true ; break end
		contacts[#contacts + 1] = {
			role = role,
			ext_role = (role ~= "creator" or role ~= "admin" or role ~= "tech" or role ~= "irt" or role ~= "cc" and true) or nil,
			type = atype,
			ext_type = (atype ~= "person" or atype ~= "organization" and true) or nil,
			jid = (atype == "jid" and address) or nil,
			email = (atype == "email" and address) or nil,
			telephone = (atype == "telephone" and address) or nil,
			postaladdr = (atype == "postaladdr" and address) or nil
		}
	end

	local related = {}
	if _related then
		for related in _related:gmatch("[%w%p]+%s[%w%p]+") do
			local fqdn, id = related:match("^([%w%p]+)%s([%w%p]+)$")
			if fqdn and id then related[#related + 1] = { text = id, name = fqdn } end
		end
	end

	local _severity, _completion, _type = _impact:match("^([%w%p]+)%s([%w%p]+)%s([%w%p]+)$")
	local assessment = { lang = "en", severity = _severity, completion = _completion, type = _type }

	local sources = {}
	for source in _sources:gmatch("[%w%p]+%s[%w%p]+%s[%d]+%s[%w%p]+") do
		local address, cat, count, count_type = source:match("^([%w%p]+)%s([%w%p]+)%s(%d+)%s([%w%p]+)$")
		if not address or not cat or not count or not count_type then fail = true ; break end
		local cat, cat_ext = ih_lib.get_type(cat, "category")
		local count_type, count_ext = ih_lib.get_type(count_type, "counter")

		sources[#sources + 1] = {
			address = { cat = cat, ext = cat_ext, text = address },
			counter = { type = count_type, ext_type = count_ext, value = count }
		}
	end

	local targets, _preprocess = {}, {}
	for target in _targets:gmatch("[%w%p]+%s[%w%p]+%s[%w%p]+") do
		local address, cat, noderole, noderole_ext
		local address, cat, noderole = target:match("^([%w%p]+)%s([%w%p]+)%s([%w%p]+)$")
		if not address or not cat or not noderole then fail = true ; break end
		cat, cat_ext = ih_lib.get_type(cat, "category")
		noderole_ext = ih_lib.get_type(cat, "noderole")

		if not _preprocess[noderole] then _preprocess[noderole] = { addresses = {}, ext = noderole_ext } end
		
		_preprocess[noderole].addresses[#_preprocess[noderole].addresses + 1] = {
			text = address, cat = cat, ext = cat_ext
		}
	end
	for noderole, data in pairs(_preprocess) do
		local nr_cat = (data.ext and "ext-category") or noderole
		local nr_ext = (data.ext and noderole) or nil
		targets[#targets + 1] = { addresses = data.addresses, noderole = { cat = nr_cat, ext = nr_ext } }
	end

	local new_object = {}
	if not fail then
		new_object["time"] = os_time()
		new_object["status"] = (formtype == "request" and "open") or nil
		new_object["type"] = formtype
		new_object["data"] = {
			id = { text = id_gen(), name = my_host },
			start_time = start_time,
			end_time = end_time,
			report_time = report_time,
			desc = desc,
			contacts = contacts,
			related = related,
			assessment = assessment,
			event_data = { sources = sources, targets = targets }
		}
		
		self[new_object.data.id.text] = new_object
		self:clean() ; self:save()
		return new_object.data.id.text
	else return false end
end

-- // Handler Functions //

local function report_handler(event)
	local origin, stanza = event.origin, event.stanza

	incidents:add(stanza, true)
	return origin.send(st.reply(stanza))
end

local function inquiry_handler(event)
	local origin, stanza = event.origin, event.stanza

	local inc_id = stanza:get_child("inquiry", xmlns_inc):get_child("Incident", xmlns_iodef):get_child("IncidentID"):get_text()
	if incidents[inc_id] then
		module:log("debug", "Server %s queried for incident %s which we know about, sending it", stanza.attr.from, inc_id)
		local report_iq = stanza_construct(incidents[inc_id])
		report_iq.attr.from = stanza.attr.to
		report_iq.attr.to = stanza.attr.from
		report_iq.attr.type = "set"

		origin.send(st.reply(stanza))
		origin.send(report_iq)
		return true
	else
		module:log("error", "Server %s queried for incident %s but we don't know about it", stanza.attr.from, inc_id)
		origin.send(st.error_reply(stanza, "cancel", "item-not-found")) ; return true
	end	
end

local function request_handler(event)
	local origin, stanza = event.origin, event.stanza

	local req_id = stanza:get_child("request", xmlns_inc):get_child("Incident", xmlns_iodef):get_child("IncidentID"):get_text()
	if not incidents[req_id] then
		origin.send(st.error_reply(stanza, "cancel", "item-not-found")) ; return true
	else
		origin.send(st.reply(stanza)) ; return true
	end
end

local function response_handler(event)
	local origin, stanza = event.origin, event.stanza

	local res_id = stanza:get_child("response", xmlns_inc):get_child("Incident", xmlns_iodef):get_child("IncidentID"):get_text()
	if incidents[res_id] then
		incidents[res_id] = nil
		incidents:add(stanza, true)
		origin.send(st.reply(stanza)) ; return true
	else
		origin.send(st.error_reply(stanza, "cancel", "item-not-found")) ; return true
	end
end

local function results_handler(event) return true end -- TODO results handling

-- // Adhoc Commands //

local function list_incidents_command_handler(self, data, state)
	local list_incidents_layout = ih_lib.render_list(incidents)

	if state then
		if state.step == 1 then
			if data.action == "cancel" then 
				return { status = "canceled" }
			elseif data.action == "prev" then
				return { status = "executing", actions = { "next", default = "next" }, form = list_incidents_layout }, {}
			end

			local single_incident_layout = state.form_layout
			local fields = single_incident_layout:data(data.form)

			if fields.response then
				incidents[state.id].status = "closed"

				local iq_send = ih_lib.stanza_construct(incidents[state.id])
				module:send(iq_send)
				return { status = "completed", info = "Response sent." }
			else
				return { status = "completed" }
			end
		else
			if data.action == "cancel" then return { status = "canceled" } end
			local fields = list_incidents_layout:data(data.form)

			if fields.ids then
				local single_incident_layout = ih_lib.render_single(incidents[fields.ids])
				return { status = "executing", actions = { "prev", "complete", default = "complete" }, form = single_incident_layout }, { step = 1, form_layout = single_incident_layout, id = fields.ids }
			else
				return { status = "completed", error = { message = "You need to select the report ID to continue." } }
			end
		end
	else
		return { status = "executing", actions = { "next", default = "next" }, form = list_incidents_layout }, {}
	end
end

local function send_inquiry_command_handler(self, data, state)
	local send_inquiry_layout = dataforms_new{
		title = "Send an inquiry about an incident report to a host";
		instructions = "Please specify both the server host and the incident ID.";

		{ name = "FORM_TYPE", type = "hidden", value = "http://jabber.org/protocol/commands" };
		{ name = "server", type = "text-single", label = "Server to inquiry" };
		{ name = "hostname", type = "text-single", label = "Involved incident host" };
		{ name = "id", type = "text-single", label = "Incident ID" };
	}

	if state then
		if data.action == "cancel" then return { status = "canceled" } end
		local fields = send_inquiry_layout:data(data.form)

		if not fields.hostname or not fields.id or not fields.server then
			return { status = "completed", error = { message = "You must supply the server to quest, the involved incident host and the incident ID." } }
		else
			local iq_send = st.iq({ from = my_host, to = fields.server, type = "get" })
						:tag("inquiry", { xmlns = xmlns_inc })
							:tag("Incident", { xmlns = xmlns_iodef, purpose = "traceback" })
								:tag("IncidentID", { name = data.hostname }):text(fields.id):up():up():up()

			module:log("debug", "Sending incident inquiry to %s", fields.server)
			module:send(iq_send)
			return { status = "completed", info = "Inquiry sent, if an answer can be obtained from the remote server it'll be listed between incidents." }
		end
	else
		return { status = "executing", form = send_inquiry_layout }, "executing"
	end
end

local function rr_command_handler(self, data, state, formtype)
	local send_layout = ih_lib.get_incident_layout(formtype)
	local err_no_fields = { status = "completed", error = { message = "You need to fill all fields, except the eventual related incident." } }
	local err_proc = { status = "completed", error = { message = "There was an error processing your request, check out the syntax" } }

	if state then
		if data.action == "cancel" then return { status = "canceled" } end
		local fields = send_layout:data(data.form)
			
		if fields.started and fields.ended and fields.reported and fields.description and fields.contacts and
		   fields.impact and fields.sources and fields.targets and fields.entity then
			if formtype == "request" and not fields.expectation then return err_no_fields end
			local id = incidents:new_object(fields, formtype)
			if not id then return err_proc end

			local stanza = ih_lib.stanza_construct(id)
			stanza.attr.from = my_host
			stanza.attr.to = fields.entity
			module:log("debug","Sending incident %s stanza to: %s", formtype, stanza.attr.to)
			module:send(stanza)

			return { status = "completed", info = string.format("Incident %s sent to %s.", formtype, fields.entity) }
		else
			return err_no_fields
		end	   
	else
		return { status = "executing", form = send_layout }, "executing"
	end
end

local function send_report_command_handler(self, data, state)
	return rr_command_handler(self, data, state, "report")
end

local function send_request_command_handler(self, data, state)
	return rr_command_handler(self, data, state, "request")
end

local adhoc_new = module:require "adhoc".new
local list_incidents_descriptor = adhoc_new("List Incidents", xmlns_inc.."#list", list_incidents_command_handler, "admin")
local send_inquiry_descriptor = adhoc_new("Send Incident Inquiry", xmlns_inc.."#send_inquiry", send_inquiry_command_handler, "admin")
local send_report_descriptor = adhoc_new("Send Incident Report", xmlns_inc.."#send_report", send_report_command_handler, "admin")
local send_request_descriptor = adhoc_new("Send Incident Request", xmlns_inc.."#send_request", send_request_command_handler, "admin")
module:provides("adhoc", list_incidents_descriptor)
module:provides("adhoc", send_inquiry_descriptor)
module:provides("adhoc", send_report_descriptor)
module:provides("adhoc", send_request_descriptor)

-- // Hooks //

module:hook("iq-set/host/urn:xmpp:incident:2:report", report_handler)
module:hook("iq-get/host/urn:xmpp:incident:2:inquiry", inquiry_handler)
module:hook("iq-get/host/urn:xmpp:incident:2:request", request_handler)
module:hook("iq-set/host/urn:xmpp:incident:2:response", response_handler)
module:hook("iq-result/host/urn:xmpp:incident:2", results_handler)

-- // Module Methods //

module.load = function()
	if datamanager.load("incidents", my_host, "incidents_store") then incidents = datamanager.load("incidents", my_host, "incidents_store") end
	setmetatable(incidents, _inc_mt) ; incidents:init()
end

module.save = function()
	return { incidents = incidents }
end

module.restore = function(data)
	incidents = data.incidents or {}
	setmetatable(incidents, _inc_mt) ; incidents:init()
end
