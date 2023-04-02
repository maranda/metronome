-- * Metronome IM *
--
-- This file is part of the Metronome XMPP server and is released under the
-- ISC License, please see the LICENSE file in this source package for more
-- information about copyright and licensing.

-- Backported from: https://git.polynom.me/PapaTutuWawa/prosody-modules

-- Helper functions for mod_mix
local function find(array, f)
    -- Searches for an element for which f returns true. The first element
    -- and its index are returned. If none are found, then -1, nil is returned.
    --
    -- f is a function that takes the value and returns either true or false.
    for i, v in pairs(array) do
        if f(v) then return i, v; end
    end

    return -1, nil;
end

local function find_str(array, str)
    -- Returns the index of str in array. -1 if array does not contain str
    local i, _ = find(array, function(v) return v == str; end);
    return i;
end

local function in_array(array, element)
    -- Returns true if element is in array. False otherwise.
    local i, _ = find(array, function(v) return v == element; end);
    return i ~= -1;
end

return {
    find_str = find_str,
    find = find,
    in_array = in_array,
};
