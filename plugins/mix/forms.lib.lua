-- * Metronome IM *
--
-- This file is part of the Metronome XMPP server and is released under the
-- ISC License, please see the LICENSE file in this source package for more
-- information about copyright and licensing.

-- Backported from: https://git.polynom.me/PapaTutuWawa/prosody-modules

local dataforms = require("util.dataforms");

local namespaces = module:require("namespaces", "mix");

return {
    -- MIX
    mix_info = dataforms.new({
        { name = "FORM_TYPE", type = "hidden", value = namespaces.mix_core },
        { name = "Name", type = "text-single" },
        { name = "Description", type = "text-single" },
        { name = "Contact", type = "jid-multi" }});
    -- MAM
    mam_query = dataforms.new({
        { name = "FORM_TYPE", type = "hidden", value = namespaces.mam },
        { name = "with", type = "jid-single" },
        { name = "start", type = "text-single" },
        { name = "end", type = "text-single" }});
};
