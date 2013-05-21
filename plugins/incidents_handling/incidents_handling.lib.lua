-- * Metronome IM *
--
-- This file is part of the Metronome XMPP server and is released under the
-- ISC License, please see the LICENSE file in this source package for more
-- information about copyright and licensing.

local pairs, ipairs, os_date, string, table, tonumber = pairs, ipairs, os.date, string, table, tonumber

local dataforms_new = require "util.dataforms".new
local st = require "util.stanza"

local xmlns_inc = "urn:xmpp:incident:2"
local xmlns_iodef = "urn:ietf:params:xml:ns:iodef-1.0"
local my_host = nil

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
		instructions = "Started/Ended Time, Contacts, Sources and Targets of the attack are mandatory. See RFC 5070 for further format instructions.",
		{ name = "FORM_TYPE", type = "hidden", value = "http://jabber.org/protocol/commands" },
		
		{ name = "name", type = "hidden", value = my_host },
		{ name = "entity", type ="text-single", label = "Remote entity to query" },
		{ name = "started", type = "text-single", label = "Incident Start Time" },
		{ name = "ended", type = "text-single", label = "Incident Ended Time" },
		{ name = "reported", type = "hidden", value = ft_str() },
		{ name = "description", type = "text-single", label = "Description",
		  desc = "Description syntax is: <lang (in xml:lang format)> <short description>" },
		{ name = "contacts", type = "text-multi", label = "Contacts",
		  desc = "Contacts entries format is: <address> <type> <role> - separated by new lines" },
		{ name = "related", type = "text-multi", label = "Related Incidents", 
		  desc = "Related incidents entries format is: <CSIRT's FQDN> <Incident ID> - separated by new lines" },
		{ name = "impact", type = "text-single", label = "Impact Assessment", 
		  desc = "Impact assessment format is: <severity> <completion> <type>" },
		{ name = "sources", type = "text-multi", label = "Attack Sources", 
		  desc = "Attack sources format is: <address> <category> <count> <count-type>" },
		{ name = "targets", type = "text-multi", label = "Attack Targets", 
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
		insert_fixed(layout, string.format("For NodeRole: %s", (target.noderole.cat == "ext-category" and target.noderole.ext) or targets.noderole.cat))
		for _, address in ipairs(target.addresses) do
			insert_fixed(layout, string.format("---> Address: %s Type: %s", address.text, (address.cat == "ext-category" and address.ext) or address.cat))
		end
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
	elseif type == "noderole" then
		local noderole_ext = nil
		if cat ~= "client" or cat ~= "server-internal" or cat ~= "server-public" or cat ~= "www" or
		   cat ~= "mail" or cat ~= "messaging" or cat ~= "streaming" or cat ~= "voice" or
		   cat ~= "file" or cat ~= "ftp" or cat ~= "p2p" or cat ~= "name" or
		   cat ~= "directory" or cat ~= "credential" or cat ~= "print" or cat ~= "application" or
		   cat ~= "database" or cat ~= "infra" or cat ~= "log" then
			noderole_ext = true
		end
		return noderole_ext
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

		for _, related in ipairs(object.related) do
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

		if s_type == "request" then stanza.attr.type = "get"
		elseif s_type == "response" then stanza.attr.type = "set"
		else stanza.attr.type = "set" end 

		return stanza
	end
end 


_M = {} -- wraps methods into the library.
_M.ft_str = ft_str
_M.get_incident_layout = get_incident_layout
_M.render_list = render_list
_M.render_single = render_single
_M.get_type = get_type
_M.stanza_parser = stanza_parser
_M.stanza_construct = stanza_construct
_M.set_my_host = function(host) my_host = host end

return _M

