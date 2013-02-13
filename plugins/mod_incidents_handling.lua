module:depends("adhoc")

local datamanager = require "util.datamanager"
local dataforms_new = require "util.dataforms".new
local st = require "util.stanza"
local id_gen = require "util.uuid".generate

local pairs, ipairs, os_date, os_time, string, table, tonumber = pairs, ipairs, os.date, os.time, string, table, tonumber

local xmlns_inc = "urn:xmpp:incident:2"
local xmlns_iodef = "urn:ietf:params:xml:ns:iodef-1.0"

incidents = {}
local my_host = module:get_host()

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
	local data = stanza_parser(stanza)
	local new_object = {
		time = os_time(),
		status = (not report and "open") or nil,
		data = data
	}

	self[data.id.text] = new_object
	self:clean() ; self:save()
end

function _inc_mt:new_object(fields, formtype)
	local _contacts, _related, _impact, _sources, _targets = fields.contacts, fields.related, fields.impact, fields.sources, fields.targets
	local fail = false

	-- Process contacts
	local contacts = {}
	for _, contact in ipairs(_contacts.tags) do
		local address, atype, role, type = contact:get_text():match("^(%w+)%s(%w+)%s(%w+)%s(%w+)$")
		if not address or not atype or not arole or not type then fail = true ; break end
		contacts[#contacts + 1] = {
			role = role,
			ext_role = (role ~= "creator" or role ~= "admin" or role ~= "tech" or role ~= "irt" or role ~= "cc" and true) or nil,
			type = type,
			ext_type = (type ~= "person" or type ~= "organization" and true) or nil,
			jid = (atype == "jid" and address) or nil,
			email = (atype == "email" and address) or nil,
			telephone = (atype == "telephone" and address) or nil,
			postaladdr = (atype == "postaladdr" and address) or nil
		}
	end

	local related = {}
	for _, related in ipairs(_related.tags) do
		local fqdn, id = related:get_text():match("^(%w+)%s(%w+)$")
		if fqdn and id then related[#related + 1] = { text = id, name = fqdn } end
	end

	local _severity, _completion, _type = _impact:get_child("value"):get_text():match("^(%w+)%s(%w+)%s(%w+)$")
	local impact = { lang = "en", severity = _severity, completion = _completion, type = _type }

	local sources = {}
	for _, source in ipairs(_sources.tags) do
		local address, cat, count, count_type = source:get_text():match("^(%w+)%s(%w+)%s(%w+)%s(%w+)$")
		if not address or not cat or not count or not count_type then fail = true ; break end
		local cat, cat_ext = get_type(cat, "category")
		local count_type, count_ext = get_type(count_type, "counter")

		sources[#sources + 1] = {
			address = { cat = cat, ext = cat_ext, text = address },
			counter = { type = count_type, ext_type = count_ext, value = count }
		}
	end

	local targets = {}
	for _, target in ipairs(_targets.tags) do
		local address, cat, noderole = target:get_text():match("^(%w+)%s(%w+)%s(%w+)$")
		if not address or not cat or not node_role then fail = true ; break end
		local cat, cat_ext = get_type(cat, "category")

		targets[#targets + 1] = {
			addresses = { text = address, cat = cat, ext = cat_ext }
		}
	end

	local new_object = {}
	if not fail then
		new_object["time"] = os_time()
		new_object["status"] = (formtype == "request" and "open") or nil
		new_object["data"] = {
			id = { text = id_gen(), name = my_host },
			contacts = contacts,
			related = related,
			impact = impact,
			sources = sources,
			targets = targets
		}
		
		self[new_object.data.id.text] = new_object
		return new_object.data.id.text
	else return false end
end

-- // Util and Functions //

local function ft_str()
	local d = os_date("%FT%T%z"):gsub("^(.*)(%+%d+)", function(dt, z) 
		if z == "+0000" then return dt.."Z" else return dt..z end
	end)
	return d
end

local function get_incident_layout(i_type)
	local layout = {
		title = (i_type == "report" and "Incident report form") or (i_type == "request" and "Request for assistance with incident form"),
		instructions = "Started/Ended Time, Contacts, Sources and Targets of the attack are mandatory. See RFC 5072 for further format instructions.",
		{ name = "FORM_TYPE", type = "hidden", value = "http://jabber.org/protocol/commands" },
		
		{ name = "name", type = "hidden", value = my_host },
		{ name = "entity", type ="text-single", label = "Remote entity to query" },
		{ name = "started", type = "text-single", label = "Incident Start Time" },
		{ name = "ended", type = "text-single", label = "Incident Ended Time" },
		{ name = "reported", type = "hidden", value = ft_str() },
		{ name = "contacts", type = "text-multi", label = "Contacts",
		  desc = "Contacts entries format is: <address> <role> [type (email or jid, def. is jid)] - separated by new lines" },
		{ name = "related", type = "text-multi", label = "Related Incidents", 
		  desc = "Related incidents entries format is: <CSIRT's FQDN> <Incident ID> - separated by new lines" },
		{ name = "impact", type = "text-single", label = "Impact Assessment", 
		  desc = "Impact assessment format is: <severity> <completion> <type>" },
		{ name = "sources", type = "text-multi", label = "Attack Sources", 
		  desc = "Attack sources format is: <address> <category> <count> <count-type>" },
		{ name = "targets", type = "text-multi", label = "Attack Sources", 
		  desc = "Attack target format is: <address> <category> <noderole>" }
	}

	if i_type == "request" then
		table.insert(layout, { 
			name = "expectation",
			type = "list-single",
			label = "Expected action from remote entity",
			value = {
				{ value = "nothing", label = "No action" },
				{ value = "contact-sender", label = "Contact us, regarding the incident" },
				{ value = "investigate", label = "Investigate the entities listed into the incident" },
				{ value = "block-host", label = "Block the involved accounts" },
				{ value = "other", label = "Other action, filling the description field is required" }
			}})
		table.insert(layout, { name = "description", type = "text-single", label = "Description" })
	end

	return dataforms_new(layout)
end

local function render_list(incidents)
	local layout = {
		title = "Stored Incidents List",
		instructions = "You can select and view incident reports here, if a followup/response is possible it'll be noted in the step after selection.",
		{ name = "FORM_TYPE", type = "hidden", value = "http://jabber.org/protocol/commands" },
		{ 
			name = "ids",
			type = "list-single",
			label = "Stored Incidents",
			value = {}
		}
	}

	-- Render stored incidents list

	for id in pairs(incidents) do
		table.insert(layout[2].value, { value = id, label = id })
	end

	return dataforms_new(layout)
end

local function insert_fixed(t, item) table.insert(t, { type = "fixed", value = item }) end

local function render_single(incident)
	local layout = {
		title = string.format("Incident ID: %s - Friendly Name: %s", incident.data.id.text, incident.data.id.name),
		instructions = incident.data.desc.text,
		{ name = "FORM_TYPE", type = "hidden", value = "http://jabber.org/protocol/commands" }
	}

	insert_fixed(layout, "Start Time: "..incident.data.start_time)
	insert_fixed(layout, "End Time: "..incident.data.end_time)
	insert_fixed(layout, "Report Time: "..incident.data.report_time)

	insert_fixed(layout, "Contacts --")
	for _, contact in ipairs(incident.data.contacts) do
		insert_fixed(layout, string.format("Role: %s Type: %s", contact.role, contact.type))
		if contact.jid then insert_fixed(layout, "--> JID: "..contact.jid..(contact.xmlns and ", XMLNS: "..contact.xmlns or "")) end
		if contact.email then insert_fixed(layout, "--> E-Mail: "..contact.email) end
		if contact.telephone then insert_fixed(layout, "--> Telephone: "..contact.telephone) end
		if contact.postaladdr then insert_fixed(layout, "--> Postal Address: "..contact.postaladdr) end
	end

	insert_fixed(layout, "Related Activity --")	
	for _, related in ipairs(incident.data.related) do
		insert_fixed(layout, string.format("Name: %s ID: %s", related.name, related.text))
	end

	insert_fixed(layout, "Assessment --")
	insert_fixed(layout, string.format("Language: %s Severity: %s Completion: %s Type: %s",
		incident.data.assessment.lang, incident.data.assessment.severity, incident.data.assessment.completion, incident.data.assessment.type))

	insert_fixed(layout, "Sources --")
	for _, source in ipairs(incident.data.event_data.sources) do
		insert_fixed(layout, string.format("Address: %s Counter: %s", source.address.text, source.counter.value))
	end

	insert_fixed(layout, "Targets --")
	for _, target in ipairs(incident.data.event_data.targets) do
		insert_fixed(layout, string.format("Address: %s Type: %s", target.address, target.ext))
	end

	if incident.data.expectation then
		insert_fixed(layout, "Expected Action: "..incident.data.expectation.action)
		if incident.data.expectation.desc then
			insert_fixed(layout, "Expected Action Description: "..incident.data.expectation.desc)
		end
	end

	if incident.type == "request" and incident.status == "open" then
		table.insert(layout, { name = "response-datetime", type = "hidden", value = ft_str() })
		table.insert(layout, { name = "response", type = "text-single", label = "Respond to the request" })
	end

	return dataforms_new(layout)
end

local function get_type(var, typ)
	if typ == "counter" then
		local count_type, count_ext = var, nil
		if count_type ~= "byte" or count_type ~= "packet" or count_type ~= "flow" or count_type ~= "session" or
		   count_type ~= "alert" or count_type ~= "message" or count_type ~= "event" or count_type ~= "host" or
		   count_type ~= "site" or count_type ~= "organization" then
			count_ext = count_type
			count_type = "ext-type"
		end
		return count_type, count_ext
	elseif typ == "category" then
		local cat, cat_ext = var, nil
		if cat ~= "asn" or cat ~= "atm" or cat ~= "e-mail" or cat ~= "ipv4-addr" or
		   cat ~= "ipv4-net" or cat ~= "ipv4-net-mask" or cat ~= "ipv6-addr" or cat ~= "ipv6-net" or
		   cat ~= "ipv6-net-mask" or cat ~= "mac" then
			cat_ext = cat
			cat = "ext-category"
		end
		return cat, cat_ext
	end
end

local function do_tag_mapping(tag, object)
	if tag.name == "IncidentID" then
		object.id = { text = tag:get_text(), name = tag.attr.name }
	elseif tag.name == "StartTime" then
		object.start_time = tag:get_text()
	elseif tag.name == "EndTime" then
		object.end_time = tag:get_text()
	elseif tag.name == "ReportTime" then
		object.report_time = tag:get_text()
	elseif tag.name == "Description" then
		object.desc = { text = tag:get_text(), lang = tag.attr["xml:lang"] }
	elseif tag.name == "Contact" then
		local jid = tag:get_child("AdditionalData").tags[1]
		local email = tag:get_child("Email")
		local telephone = tag:get_child("Telephone")
		local postaladdr = tag:get_child("PostalAddress")
		if not object.contacts then
			object.contacts = {}
			object.contacts[1] = {
				role = tag.attr.role,
				ext_role = (tag.attr["ext-role"] and true) or nil,
				type = tag.attr.type,
				ext_type = (tag.attr["ext-type"] and true) or nil,
				xmlns = jid.attr.xmlns,
				jid = jid:get_text(),
				email = email,
				telephone = telephone,
				postaladdr = postaladdr
			}
		else
			object.contacts[#object.contacts + 1] = { 
				role = tag.attr.role,
				ext_role = (tag.attr["ext-role"] and true) or nil,
				type = tag.attr.type,
				ext_type = (tag.attr["ext-type"] and true) or nil,
				xmlns = jid.attr.xmlns,
				jid = jid:get_text(),
				email = email,
				telephone = telephone,
				postaladdr = postaladdr
			}
		end
	elseif tag.name == "RelatedActivity" then
		object.related = {}
		for _, t in ipairs(tag.tags) do
			if tag.name == "IncidentID" then
				object.related[#object.related + 1] = { text = t:get_text(), name = tag.attr.name }
			end
		end
	elseif tag.name == "Assessment" then
		local impact = tag:get_child("Impact")
		object.assessment = { lang = impact.attr.lang, severity = impact.attr.severity, completion = impact.attr.completion, type = impact.attr.type } 
	elseif tag.name == "EventData" then
		local source = tag:get_child("Flow").tags[1]
		local target = tag:get_child("Flow").tags[2]
		local expectation = tag:get_child("Flow").tags[3]
		object.event_data = { sources = {}, targets = {} }
		for _, t in ipairs(source.tags) do
			local addr = t:get_child("Address")
			local cntr = t:get_child("Counter")
			object.event_data.sources[#object.event_data.sources + 1] = {
				address = { cat = addr.attr.category, ext = addr.attr["ext-category"], text = addr:get_text() },
				counter = { type = cntr.attr.type, ext_type = cntr.attr["ext-type"], value = cntr:get_text() }
			}
		end
		for _, entry in ipairs(target.tags) do
			local noderole = { cat = entry:get_child("NodeRole").attr.category, ext = entry:get_child("NodeRole").attr["ext-category"] }
			local current = #object.event_data.targets + 1
			object.event_data.targets[current] = { addresses = {}, noderole = noderole }
			for _, tag in ipairs(entry.tags) do				
				object.event_data.targets[current].addresses[#object.event_data.targets[current].addresses + 1] = { text = tag:get_text(), cat = tag.attr.category, ext = tag.attr["ext-category"] }
			end
		end
		if expectation then 
			object.event_data.expectation = { 
				action = expectation.attr.action,
				desc = expectation:get_child("Description") and expectation:get_child("Description"):get_text()
			} 
		end
	elseif tag.name == "History" then
		object.history = {}
		for _, t in ipairs(tag.tags) do
			object.history[#object.history + 1] = {
				action = t.attr.action,
				date = t:get_child("DateTime"):get_text(),
				desc = t:get_chilld("Description"):get_text()
			}
		end
	end
end

local function stanza_parser(stanza)
	local object = {}
	
	if stanza:get_child("report", xmlns_inc) then
		local report = st.clone(stanza):get_child("report", xmlns_inc):get_child("Incident", xmlns_iodef)
		for _, tag in ipairs(report.tags) do do_tag_mapping(tag, object) end
	elseif stanza:get_child("request", xmlns_inc) then
		local request = st.clone(stanza):get_child("request", xmlns_inc):get_child("Incident", xmlns_iodef)
		for _, tag in ipairs(request.tags) do do_tag_mapping(tag, object) end
	elseif stanza:get_child("response", xmlns_inc) then
		local response = st.clone(stanza):get_child("response", xmlns_inc):get_child("Incident", xmlns_iodef)
		for _, tag in ipairs(response.tags) do do_tag_mapping(tag, object) end
	end

	return object
end

local function stanza_construct(id)
	if not id then return nil
	else
		local object = incidents[id].data
		local s_type = incidents[id].type
		local stanza = st.iq():tag(s_type or "report", { xmlns = xmlns_inc })
		stanza:tag("Incident", { xmlns = xmlns_iodef, purpose = incidents[id].purpose })
			:tag("IncidentID", { name = object.id.name }):text(object.id.text):up()
			:tag("StartTime"):text(object.start_time):up()
			:tag("EndTime"):text(object.end_time):up()
			:tag("ReportTime"):text(object.report_time):up()
			:tag("Description", { ["xml:lang"] = object.desc.lang }):text(object.desc.text):up():up();
		
		local incident = stanza:get_child(s_type, xmlns_inc):get_child("Incident", xmlns_iodef)		

		for _, contact in ipairs(object.contacts) do
			incident:tag("Contact", { role = (contact.ext_role and "ext-role") or contact.role,
						  ["ext-role"] = (contact.ext_role and contact.role) or nil,
						  type = (contact.ext_type and "ext-type") or contact.type,
						  ["ext-type"] = (contact.ext_type and contact.type) or nil })
				:tag("Email"):text(contact.email):up()
				:tag("Telephone"):text(contact.telephone):up()
				:tag("PostalAddress"):text(contact.postaladdr):up()
				:tag("AdditionalData")
					:tag("jid", { xmlns = contact.xmlns }):text(contact.jid):up():up():up()
	
		end

		incident:tag("RelatedActivity"):up();

		for _, related in ipairs(object.relateds) do
			incident:get_child("RelatedActivity")			
				:tag("IncidentID", { name = related.name }):text(related.text):up();
		end

		incident:tag("Assessment")
			:tag("Impact", { 
				lang = object.assessment.lang,
				severity = object.assessment.severity,
				completion = object.assessment.completion,
				type = object.assessment.type
			}):up():up();

		incident:tag("EventData")
			:tag("Flow")
				:tag("System", { category = "source" }):up()
				:tag("System", { category = "target" }):up():up():up();

		local e_data = incident:get_child("EventData")

		local sources = e_data:get_child("Flow").tags[1]
		local targets = e_data:get_child("Flow").tags[2]

		for _, source in ipairs(object.event_data.sources) do
			sources:tag("Node")
				:tag("Address", { category = source.address.cat, ["ext-category"] = source.address.ext })
					:text(source.address.text):up()
				:tag("Counter", { type = source.counter.type, ["ext-type"] = source.counter.ext_type })
					:text(source.counter.value):up():up();
		end

		for _, target in ipairs(object.event_data.targets) do
			targets:tag("Node"):up() ; local node = targets.tags[#targets.tags]
			for _, address in ipairs(target.addresses) do
				node:tag("Address", { category = address.cat, ["ext-category"] = address.ext }):text(address.text):up();
			end
			node:tag("NodeRole", { category = target.noderole.cat, ["ext-category"] = target.noderole.ext }):up();
		end

		if object.event_data.expectation then
			e_data:tag("Expectation", { action = object.event_data.expectation.action }):up();
			if object.event_data.expectation.desc then
				local expectation = e_data:get_child("Expectation")
				expectation:tag("Description"):text(object.event_data.expectation.desc):up();
			end
		end

		if object.history then
			local history = incident:tag("History"):up();
			
			for _, item in ipairs(object.history) do
				history:tag("HistoryItem", { action = item.action })
					:tag("DateTime"):text(item.date):up()
					:tag("Description"):text(item.desc):up():up();
			end	
		end

		-- Sanitize contact empty tags
		for _, tag in ipairs(incident) do
			if tag.name == "Contact" then
				for i, check in ipairs(tag) do
					if (check.name == "Email" or check.name == "PostalAddress" or check.name == "Telephone") and
					   not check:get_text() then
						table.remove(tag, i) 
					end
				end	
			end
		end

		return stanza
	end
end 

local function report_handler(event)
	local origin, stanza = event.origin, event.stanza

	incidents:add(stanza, true)
	return origin.send(st.reply(stanza))
end

local function inquiry_handler(event)
	local origin, stanza = event.origin, event.stanza

	local inc_id = stanza:get_child("inquiry", xmlns_inc):get_child("Incident", xmlns_iodef):get_child("IncidentID"):get_text()
	if incidents[inc_id] then
		local report_iq = stanza_construct(incidents[inc_id])
		report_iq.attr.from = stanza.attr.to
		report_iq.attr.to = stanza.attr.from
		report_iq.attr.type = "set"

		origin.send(st.reply(stanza))
		return origin.send(report_iq)
	else
		return origin.send(st.error_reply(stanza))
	end	
end

local function request_handler(event)
	local origin, stanza = event.origin, event.stanza

	local req_id = stanza:get_child("request", xmlns_inc):get_child("Incident", xmlns_iodef):get_child("IncidentID"):get_text()
	if not incidents[req_id] then
		return origin.send(st.error_reply(stanza))
	else
		return origin.send(st.reply(stanza))
	end
end

local function response_handler(event)
	local origin, stanza = event.origin, event.stanza

	local res_id = stanza:get_child("response", xmlns_inc):get_child("Incident", xmlns_iodef):get_child("IncidentID"):get_text()
	if incidents[res_id] then
		incidents[res_id] = nil
		incidents:add(stanza, true)
		return origin.send(st.reply(stanza))
	else
		return origin.send(st.error_reply(stanza))
	end
end

-- // Adhoc Commands //

local function list_incidents_command_handler(self, data, state)
	local list_incidents_layout = render_list(incidents)

	if state then
		if state.step == 1 then
			if data.action == "cancel" then 
				return { status = "canceled" }
			elseif data.action == "back" then
				return { status = "executing", actions = { "next", "cancel", default = "next" }, form = list_incident_layout }, {}
			end

			local single_incident_layout = state.form_layout
			local fields = single_incident_layout:data(data.form)

			if fields.response then
				local iq_send = stanza_construct(incidents[state.id])

				incidents[state.id].status = "closed"
				module:send(iq_send)
				return { status = "completed", info = "Response sent." }
			else
				return { status = "completed" }
			end
		else
			if data.action == "cancel" then return { status = "canceled" } end
			local fields = list_incidents_layout:data(data.form)

			if fields.ids then
				local single_incident_layout = render_single(incident[fields.ids])
				return { status = "executing", actions = { "back", "cancel", "complete", default = "complete" }, form = single_incident_layout }, { step = 1, form_layout = single_incident_layout, id = fields.ids }
			else
				return { status = "completed", error = { message = "You need to select the report ID to continue." } }
			end
		end
	else
		return { status = "executing", actions = { "next", "cancel", default = "next" }, form = list_incidents_layout }, {}
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
			local iq_send = st.iq({ from = my_host, to = data.server, type = "get" })
						:tag("inquiry", { xmlns = xmlns_inc })
							:tag("Incident", { xmlns = xmlns_iodef, purpose = "traceback" })
								:tag("IncidentID", { name = data.hostname }):text(fields.id):up():up():up()

			module:send(iq_send)
			return { status = "completed", info = "Inquiry sent, if an answer can be obtained from the remote server it'll be listed between incidents." }
		end
	else
		return { status = "executing", form = send_inquiry_layout }, "executing"
	end
end

local function rr_command_handler(self, data, state, formtype)
	local send_layout = get_incident_layout(formtype)
	local err_no_fields = { status = "completed", error = { message = "You need to fill all fields." } }
	local err_proc = { status = "completed", error = { message = "There was an error processing your request, check out the syntax" } }

	if state then
		if data.action == "cancel" then return { status = "canceled" } end
		local fields = send_layout:data(data.form)
			
		if fields.started and fields.ended and fields.reported and fields.contacts and
		   fields.related and fields.impact and fields.sources and fields.target and
		   fields.entity then
			if formtype == "request" and not fields.expectation then return err_no_fields end
			local id = incidents:new_object(fields, formtype)
			if not id then return err_proc end

			local stanza = stanza_construct(id)
			stanza.attr.from = my_host
			stanza.attr.to = fields.entity
			module:send(stanza)

			return { status = "completed" }
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
