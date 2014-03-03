-- * Metronome IM *
--
-- This file is part of the Metronome XMPP server and is released under the
-- ISC License, please see the LICENSE file in this source package for more
-- information about copyright and licensing.

module:depends("adhoc");

local dataforms = require "util.dataforms";
local datamanager = require "util.datamanager";
local jid_compare = require "util.jid".compare;
local jid_split = require "util.jid".prepped_split;
local extract_data = module:require("sasl_aux").extract_data;
local user_exists = require "core.usermanager".user_exists;

local adhoc_xmlns = "http://jabber.org/protocol/commands";
local add_xmlns = "http://metronome.im/protocol/certificates#add";
local list_xmlns = "http://metronome.im/protocol/certificates#list";

local my_host = module.host;

local add_layout = dataforms.new{
	title = "Associate a new client certificate";
	instructions = "Associate a new TLS certificate to use for authentication  through SASL External.";
	{ name = "FORM_TYPE", type = "hidden", value = adhoc_xmlns };
	{ name = "name", type = "text-single", label = "The name of the certificate" };
	{ name = "resource", type = "text-single", label = "Optional name of allowed to use Client Resource" };
	{ name = "cert", type = "text-multi", label = "Paste your certificate (in PEM format)" };
}

local function list_layout(data)
	local layout = {
		title = "List account associated client certificates";
		instructions = "Delete or view the associated TLS certificates.";
		{ name = "FORM_TYPE", type = "hidden", value = adhoc_xmlns };
	}
	
	for name, data in pairs(data) do
		t_insert(layout, {
			name = name,
			type = "list-single",
			label = ("Certificate: %s%s"):format(name, data.resource and "(valid for resource: "..data.resource..")" or ""),
			value = {
				{ value = "none", default = true },
				{ value = "remove" }
			}
		});
	end
	
	return dataforms.new(layout);
end

local not_secure = {
	status = "error",
	error = { type = "cancel", condition = "policy-violation", message = "This command can be run only on a secured stream" }
};
local save_failed = { status = "completed", error = { message = "Failed to save the certificates' store" } };

-- Adhoc handlers

local function add_cert(self, data, state)
	if not secure then return not_secure; end

	if state then
		if data.action == "cancel" then return { status = "canceled" }; end
		local fields = add_layout:data(data.form);
		if fields.name and fields.cert then
			local from, name, cert, resource = data.from, fields.name, fields.cert, fields.resource;
			local store = datamanager.load(from, my_host, "certificates") or {};
			local replacing = store[name] and true;
			store[name] = { cert = cert, resource = resource };

			if datamanager.store(data.from, my_host, "certificates", store) then
				return { status = "completed", 
					 info = ("Certificate %s%s, has been successfully %s"):format(
						name, resource and " (valid for client resource "..resource.."),
						replacing and "replaced" or "added") };
			else
				return save_failed;
			end
		else
			return { status = "completed", 
				 error = { message = "You need to supply both the certificate name and the certificate itself" } };
		end
	else
		return { status = "executing", form = add_layout }, "executing";
	end
end

local function list_certs(self, data, state, secure)
	if not secure then return not_secure; end
	if data.action == "cancel" then return { status = "canceled" }; end

	if state then
		local layout, store = state.layout, state.store;
		local fields = layout:data(data.form);
		fields["FORM_TYPE"] = nil;
		
		for name, action in pairs(fields) do
			if action == "remove" then store[name] = nil; end
		end

		if datamanager.store(data.from, my_host, "certificates", store) then
			return { status = "completed", info = "Done" };
		else
			return save_failed;
		end
	else
		local store = datamanager.load(from, my_host, "certificates");
		if not store then
			return { status = "complete", error = { message = "You have no certificates" } };
		else
			local layout = list_layout(store);
			return { status = "executing", form = layout }, { store = store, layout = layout };
		end
	end
end

local adhoc_new = module:require "adhoc".new;
local add_descriptor = adhoc_new("Associate a client certificate with this account", add_xmlns, add_cert);
local list_descriptor = adhoc_new("List associated client certificates with this account", list_xmlns, list_certs);
module:provides("adhoc", add_descriptor);
module:provides("adhoc", list_descriptor);

-- Verify handler

module:hook("certificate-verification", function(sasl, session, authid, socket)
	session.log("debug", "Certification verification is being handled by mod_adhoc_cm...");
	local cert = socket:getpeercertificate();

	if not cert then
		return { false, "No certificate found" };
	end
	if not cert:validat(get_time()) then
		return { false, "Supplied certificate is expired" };
	end
	local data = extract_data(cert);
	for _, address in ipairs(data) do
		if authid == "" or jid_compare(authid, address) then
			local username, host = jid_split(address);
			if host == my_host and user_exists(username, host) then return { username }; end
		end
	end

	return { false, "Couldn't find a valid address which could be associated with an xmpp account" };
end, 10);
