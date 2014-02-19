-- * Metronome IM *
--
-- This file is part of the Metronome XMPP server and is released under the
-- ISC License, please see the LICENSE file in this source package for more
-- information about copyright and licensing.
--
-- As per the sublicensing clause, this file is also MIT/X11 Licensed.
-- ** Copyright (c) 2008-2011, Matthew Wild, Waqas Hussain

local match = string.match;
local nodeprep = require "util.encodings".stringprep.nodeprep;
local nameprep = require "util.encodings".stringprep.nameprep;
local resourceprep = require "util.encodings".stringprep.resourceprep;

local escapes = {
	[" "] = "\\20"; ['"'] = "\\22";
	["&"] = "\\26"; ["'"] = "\\27";
	["/"] = "\\2f"; [":"] = "\\3a";
	["<"] = "\\3c"; [">"] = "\\3e";
	["@"] = "\\40"; ["\\"] = "\\5c";
};
local unescapes = {};
for k, v in pairs(escapes) do unescapes[v] = k; end

module "jid"

local function _split(jid)
	if not jid then return; end
	local node, host, resource, pos;
	node, pos = match(jid, "^([^@/]+)@()");
	host, pos = match(jid, "^([^@/]+)()", pos);
	if node and not host then return nil, nil, nil; end
	resource = match(jid, "^/(.+)$", pos);
	if (not host) or ((not resource) and #jid >= pos) then return nil, nil, nil; end
	return node, host, resource;
end
split = _split;

function bare(jid)
	local node, host = _split(jid);
	if node and host then
		return node.."@"..host;
	end
	return host;
end

function section(jid, type)
	if not jid then return; end
	local node, host, resource, pos;
	node, pos = match(jid, "^([^@/]+)@()");
	host, pos = match(jid, "^([^@/]+)()", pos);
	if host then resource = match(jid, "^/(.+)$", pos); end
	if type == "node" then return node;
	elseif type == "host" then return host;
	elseif type == "resource" then return resource; end
end

function prepped_section(jid, type)
	local bit = section(jid, type);
	if not bit then return; end
	if type == "node" then return nodeprep(bit);
	elseif type == "host" then return nameprep(bit);
	elseif type == "resource" then return resourceprep(bit); end
end

local function _prepped_split(jid)
	local node, host, resource = _split(jid);
	if host then
		host = nameprep(host);
		if not host then return; end
		if node then
			node = nodeprep(node);
			if not node then return; end
		end
		if resource then
			resource = resourceprep(resource);
			if not resource then return; end
		end
		return node, host, resource;
	end
end
prepped_split = _prepped_split;

function prep(jid)
	local node, host, resource = _prepped_split(jid);
	if host then
		if node then
			host = node .. "@" .. host;
		end
		if resource then
			host = host .. "/" .. resource;
		end
	end
	return host;
end

function join(node, host, resource)
	if node and host and resource then
		return node.."@"..host.."/"..resource;
	elseif node and host then
		return node.."@"..host;
	elseif host and resource then
		return host.."/"..resource;
	elseif host then
		return host;
	end
	return nil; -- Invalid JID
end

function compare(jid, acl)
	-- compare jid to single acl rule
	-- TODO compare to table of rules?
	local jid_node, jid_host, jid_resource = _split(jid);
	local acl_node, acl_host, acl_resource = _split(acl);
	if ((acl_node ~= nil and acl_node == jid_node) or acl_node == nil) and
		((acl_host ~= nil and acl_host == jid_host) or acl_host == nil) and
		((acl_resource ~= nil and acl_resource == jid_resource) or acl_resource == nil) then
		return true
	end
	return false
end

function escape(s) return s and (s:gsub(".", escapes)); end
function unescape(s) return s and (s:gsub("\\%x%x", unescapes)); end

return _M;
