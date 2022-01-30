-- * Metronome IM *
--
-- This file is part of the Metronome XMPP server and is released under the
-- ISC License, please see the LICENSE file in this source package for more
-- information about copyright and licensing.
--
-- As per the sublicensing clause, this file is also MIT/X11 Licensed.
-- ** Copyright (c) 2008-2012, Kim Alvefur, Matthew Wild, Waqas Hussain

local t_insert, t_remove, t_concat = table.insert, table.remove, table.concat;
local s_format, s_match, s_gsub, s_find = string.format, string.match, string.gsub, string.find;
local tostring, setmetatable, pairs, ipairs, type, os =
	tostring, setmetatable, pairs, ipairs, type, os;

local getstyle, getstring, do_pretty_printing;
local ok, termcolours = pcall(require, "util.termcolours");
if ok then
	do_pretty_printing = true;
	getstyle, getstring = termcolours.getstyle, termcolours.getstring;
end

local id, new_id, uuid = 0;
ok, uuid = pcall(require, "util.uuid");
if ok then
	new_id = uuid.generate;
else
	new_id = function() id = id + 1; return "lx"..id; end
end	

local xmlns_stanzas = "urn:ietf:params:xml:ns:xmpp-stanzas";

local _ENV = nil;

local stanza_mt = { __type = "stanza" };
stanza_mt.__index = stanza_mt;
local stanza_mt = stanza_mt;

local function stanza(name, attr)
	local stanza = { name = name, attr = attr or {}, tags = {} };
	return setmetatable(stanza, stanza_mt);
end
local stanza = stanza;

function stanza_mt:query(xmlns)
	return self:tag("query", { xmlns = xmlns });
end

function stanza_mt:body(text, attr)
	return self:tag("body", attr):text(text);
end

function stanza_mt:tag(name, attrs)
	local s = stanza(name, attrs);
	local last_add = self.last_add;
	if not last_add then last_add = {}; self.last_add = last_add; end
	(last_add[#last_add] or self):add_direct_child(s);
	t_insert(last_add, s);
	return self;
end

function stanza_mt:text(text)
	local last_add = self.last_add;
	if type(text) == "string" then
		(last_add and last_add[#last_add] or self):add_direct_child(text);
	end
	return self;
end

function stanza_mt:up()
	local last_add = self.last_add;
	if last_add then t_remove(last_add); end
	return self;
end

function stanza_mt:reset()
	self.last_add = nil;
	return self;
end

function stanza_mt:add_direct_child(child)
	if type(child) == "table" then
		t_insert(self.tags, child);
	end
	t_insert(self, child);
end

function stanza_mt:get_index(name, xmlns)
	for idx, tag in ipairs(self.tags) do
		if xmlns and (tag.name == name and tag.attr.xmlns == xmlns) then
			return idx;
		elseif not xmlns and tag.name == name then
			return idx;
		end
	end
end

function stanza_mt:get_last_tag_index(name, xmlns)
	if self.last_add then
		for idx, tag in ipairs(self.last_add[1]) do
			if xmlns and (tag.name == name and tag.attr.xmlns == xmlns) then
				return idx;
			elseif not xmlns and tag.name == name then
				return idx;
			end
		end
	end
end

function stanza_mt:add_child(child)
	local last_add = self.last_add;
	(last_add and last_add[#last_add] or self):add_direct_child(child);
	return self;
end

function stanza_mt:get_child(name, xmlns)
	for _, child in ipairs(self.tags) do
		if (not name or child.name == name)
			and ((not xmlns and self.attr.xmlns == child.attr.xmlns)
				or child.attr.xmlns == xmlns) then
			
			return child;
		end
	end
end

function stanza_mt:get_child_text(name, xmlns)
	local tag = self:get_child(name, xmlns);
	if tag then
		return tag:get_text();
	end
	return nil;
end

function stanza_mt:child_with_attr_value(name, attr, value)
	for _, child in ipairs(self.tags) do
		if child.name == name and child.attr[attr] and
		   child.attr[attr] == value then
			 return child;
		end
	end
end

function stanza_mt:child_with_name(name)
	for _, child in ipairs(self.tags) do
		if child.name == name then return child; end
	end
end

function stanza_mt:child_with_ns(ns)
	for _, child in ipairs(self.tags) do
		if child.attr.xmlns == ns then return child; end
	end
end

function stanza_mt:children()
	local i = 0;
	return function (a)
			i = i + 1
			return a[i];
		end, self, i;
end

function stanza_mt:childtags(name, xmlns)
	local tags = self.tags;
	local start_i, max_i = 1, #tags;
	return function ()
		for i = start_i, max_i do
			local v = tags[i];
			if (not name or v.name == name)
			and ((not xmlns and self.attr.xmlns == v.attr.xmlns)
				or v.attr.xmlns == xmlns) then
				start_i = i+1;
				return v;
			end
		end
	end;
end

function stanza_mt:maptags(callback)
	local tags, curr_tag = self.tags, 1;
	local n_children, n_tags = #self, #tags;
	
	local i = 1;
	while n_tags > 0 and curr_tag <= n_tags do
		if self[i] == tags[curr_tag] then
			local ret = callback(self[i]);
			if ret == nil then
				t_remove(self, i);
				t_remove(tags, curr_tag);
				i, curr_tag, n_children, n_tags =
				i - 1, curr_tag - 1, n_children - 1, n_tags - 1;
			else
				self[i] = ret;
				tags[curr_tag] = ret;
			end
			curr_tag = curr_tag + 1;
		end
		i = i + 1;
	end
	return self;
end

local xml_escape;
local escape_table = { ["'"] = "&apos;", ["\""] = "&quot;", ["<"] = "&lt;", [">"] = "&gt;", ["&"] = "&amp;" };
function xml_escape(str) return (s_gsub(str, "['&<>\"]", escape_table)); end

local function _dostring(t, buf, self, xml_escape, parentns)
	local nsid = 0;
	local name = t.name
	t_insert(buf, "<"..name);
	for k, v in pairs(t.attr) do
		if s_find(k, "\1", 1, true) then
			local ns, attrk = s_match(k, "^([^\1]*)\1?(.*)$");
			nsid = nsid + 1;
			t_insert(buf, " xmlns:ns"..nsid.."='"..xml_escape(ns).."' ".."ns"..nsid..":"..attrk.."='"..xml_escape(v).."'");
		elseif not(k == "xmlns" and v == parentns) then
			t_insert(buf, " "..k.."='"..xml_escape(v).."'");
		end
	end
	local len = #t;
	if len == 0 then
		t_insert(buf, "/>");
	else
		t_insert(buf, ">");
		for n=1,len do
			local child = t[n];
			if child.name then
				self(child, buf, self, xml_escape, t.attr.xmlns);
			else
				t_insert(buf, xml_escape(child));
			end
		end
		t_insert(buf, "</"..name..">");
	end
end
function stanza_mt.__tostring(t)
	local buf = {};
	_dostring(t, buf, _dostring, xml_escape, nil);
	return t_concat(buf);
end

function stanza_mt.top_tag(t)
	local attr_string = "";
	if t.attr then
		for k, v in pairs(t.attr) do if type(k) == "string" then attr_string = attr_string .. s_format(" %s='%s'", k, xml_escape(tostring(v))); end end
	end
	return s_format("<%s%s>", t.name, attr_string);
end

function stanza_mt.get_text(t)
	if #t.tags == 0 then
		return t_concat(t);
	end
end

function stanza_mt.get_error(stanza)
	local type, condition, text;
	
	local error_tag = stanza:get_child("error");
	if not error_tag then
		return nil, nil, nil;
	end
	type = error_tag.attr.type;
	
	for _, child in ipairs(error_tag.tags) do
		if child.attr.xmlns == xmlns_stanzas then
			if not text and child.name == "text" then
				text = child:get_text();
			elseif not condition then
				condition = child.name;
			end
			if condition and text then
				break;
			end
		end
	end
	return type, condition or "undefined-condition", text;
end

local function preserialize(stanza)
	local s = { name = stanza.name, attr = stanza.attr };
	for _, child in ipairs(stanza) do
		if type(child) == "table" then
			t_insert(s, preserialize(child));
		else
			t_insert(s, child);
		end
	end
	return s;
end

local function deserialize(stanza)
	-- Set metatable
	if stanza then
		local attr = stanza.attr;
		for i=1,#attr do attr[i] = nil; end
		local attrx = {};
		for att in pairs(attr) do
			if s_find(att, "|", 1, true) and not s_find(att, "\1", 1, true) then
				local ns,na = s_match(att, "^([^|]+)|(.+)$");
				attrx[ns.."\1"..na] = attr[att];
				attr[att] = nil;
			end
		end
		for a, v in pairs(attrx) do
			attr[a] = v;
		end
		setmetatable(stanza, stanza_mt);
		for _, child in ipairs(stanza) do
			if type(child) == "table" then
				deserialize(child);
			end
		end
		if not stanza.tags then
			-- Rebuild tags
			local tags = {};
			for _, child in ipairs(stanza) do
				if type(child) == "table" then
					t_insert(tags, child);
				end
			end
			stanza.tags = tags;
		end
	end
	
	return stanza;
end

local function _clone(stanza)
	local attr, tags = {}, {};
	for k, v in pairs(stanza.attr) do attr[k] = v; end
	local new = { name = stanza.name, attr = attr, tags = tags };
	for i=1,#stanza do
		local child = stanza[i];
		if child.name then
			child = _clone(child);
			t_insert(tags, child);
		end
		t_insert(new, child);
	end
	return setmetatable(new, stanza_mt);
end
local clone = _clone;

local function message(attr, body)
	if attr and not attr.id then attr.id = new_id(); end
	if not body then
		return stanza("message", attr or { id = new_id() });
	else
		return stanza("message", attr or { id = new_id() }):tag("body"):text(body):up();
	end
end
local function iq(attr)
	if attr and not attr.id then attr.id = new_id(); end
	return stanza("iq", attr or { id = new_id() });
end

local function reply(orig)
	return stanza(orig.name, orig.attr and { to = orig.attr.from, from = orig.attr.to, id = orig.attr.id, type = ((orig.name == "iq" and "result") or orig.attr.type) });
end

local xmpp_stanzas_attr = { xmlns = xmlns_stanzas };
local function error_reply(orig, type, condition, message)
	local t = reply(orig);
	t.attr.type = "error";
	t:tag("error", {type = type}) --COMPAT: Some day xmlns:stanzas goes here
		:tag(condition, xmpp_stanzas_attr):up();
	if (message) then t:tag("text", xmpp_stanzas_attr):text(message):up(); end
	return t; -- stanza ready for adding app-specific errors
end

local function presence(attr)
	if attr and not attr.id then attr.id = new_id(); end
	return stanza("presence", attr or { id = new_id() });
end

if do_pretty_printing then
	local style_attrk = getstyle("yellow");
	local style_attrv = getstyle("red");
	local style_tagname = getstyle("red");
	local style_punc = getstyle("magenta");
	
	local attr_format = " "..getstring(style_attrk, "%s")..getstring(style_punc, "=")..getstring(style_attrv, "'%s'");
	local top_tag_format = getstring(style_punc, "<")..getstring(style_tagname, "%s").."%s"..getstring(style_punc, ">");
	--local tag_format = getstring(style_punc, "<")..getstring(style_tagname, "%s").."%s"..getstring(style_punc, ">").."%s"..getstring(style_punc, "</")..getstring(style_tagname, "%s")..getstring(style_punc, ">");
	local tag_format = top_tag_format.."%s"..getstring(style_punc, "</")..getstring(style_tagname, "%s")..getstring(style_punc, ">");
	function stanza_mt.pretty_print(t)
		local children_text = "";
		for n, child in ipairs(t) do
			if type(child) == "string" then
				children_text = children_text .. xml_escape(child);
			else
				children_text = children_text .. child:pretty_print();
			end
		end

		local attr_string = "";
		if t.attr then
			for k, v in pairs(t.attr) do if type(k) == "string" then attr_string = attr_string .. s_format(attr_format, k, tostring(v)); end end
		end
		return s_format(tag_format, t.name, attr_string, children_text, t.name);
	end
	
	function stanza_mt.pretty_top_tag(t)
		local attr_string = "";
		if t.attr then
			for k, v in pairs(t.attr) do if type(k) == "string" then attr_string = attr_string .. s_format(attr_format, k, tostring(v)); end end
		end
		return s_format(top_tag_format, t.name, attr_string);
	end
else
	-- Sorry, fresh out of colours for you guys ;)
	stanza_mt.pretty_print = stanza_mt.__tostring;
	stanza_mt.pretty_top_tag = stanza_mt.top_tag;
end

return {
	stanza = stanza,
	stanza_mt = stanza_mt,
	xml_escape = xml_escape,
	new_id = new_id,
	preserialize = preserialize,
	deserialize = deserialize,
	clone = clone,
	message = message,
	iq = iq,
	reply = reply,
	error_reply = error_reply,
	presence = presence
};
