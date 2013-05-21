-- * Metronome IM *
--
-- This file is part of the Metronome XMPP server and is released under the
-- ISC License, please see the LICENSE file in this source package for more
-- information about copyright and licensing.

--- Adds a little fantasy to the API's room:destroy.
--- let's have some fun when it comes to lynching lamers.

local muc_host = module:get_host();
local timer = require "util.timer";
local default_quotes = {
	{
		{ "/me three gloomish elemental lights mysteriously appear...", "*", 4 },
		{ "Hi guys! I'm the server entity itself, prepare to be smited.", "Metronome", 6 },
		{ "/me starts modifying the space-time quantum fabric composing the room...", "Metronome", 8 },
		{ "/me waves *o/* and *poofs*", "Metronome", 9 },
		{ "/me light spectrum fluctuates and flickers erratically, as %s starts to gravitically implode together with all its inoccupants.", "*", 11 }
	}
}
local default_screams = { "ArghHHHHhhhhh!", "NooooooOOOOooooooOo!", "EwwwwwwwwwwWWWWWWW AghhhhHH!", "AAAAAAAAAAHHHHHhhhhhhhh!" };	
local quotes = module:get_option_array("zap_and_dest_quotes", default_quotes);
local screams = module:get_option_array("zap_and_dest_screams", default_screams);

-- injects the new function into the mt

hosts[muc_host].modules.muc.stanza_handler.muc_new_room.room_mt["zap_and_destroy"] = function (self)
	-- Select randomly between quote sets.
	local quote_set = math.random(1,#quotes);	

	-- We check that quotes/timeseq in the set has at most 5 entries....
	if #quotes[quote_set] > 5 then
		module:log("error", "quotes and timesequences sets table can't exceed 5 entries, halting.");
		return true;
	end

	-- Set timesequences and check that timesequences are numbers, FIX: Crappy.
	local check_seqs = false;

	for i=1,5 do if type(quotes[quote_set][i][3]) ~= "number" then
		check_seqs = true; break; end end
	if check_seqs then module:log("error", "time sequences values can contain only number entries! Halting."); return true; end
	
	-- Safety checks done? Begin!
	-- Loop through quotes and add timers.
	for i=1,5 do
		timer.add_task(quotes[quote_set][i][3], function () self:broadcast_message(stanza.stanza("message", { from = self.jid.."/"..quotes[quote_set][i][2], to = self.jid, type = "groupchat"}):body(quotes[quote_set][i][1]:format(self.jid))) end);
	end

	-- When the looping is done we shall have everyone scream, using the last timeseq entry.
	timer.add_task(quotes[quote_set][#quotes[quote_set]][3], function ()
	for _, occupants in pairs(self._occupants) do
		for jid in pairs(occupants.sessions) do
			self:handle_to_room(jid, stanza.stanza("message", { from = jid, to = self.jid, type = "groupchat"}):body(screams[math.random(1,#screams)]));
		end
	end end);

	-- Now that we're done, on with the disintegration.
	-- Shall wait two seconds after the last sequence.
	local t_wait = quotes[quote_set][#quotes[quote_set]][3] + 2;
	timer.add_task(t_wait, function () self:destroy(nil, "The room implodes into itself and fizzles out of existance..."); end);
end
