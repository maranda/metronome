-- * Metronome IM *
--
-- This file is part of the Metronome XMPP server and is released under the
-- ISC License, please see the LICENSE file in this source package for more
-- information about copyright and licensing.

-- Backported from: https://git.polynom.me/PapaTutuWawa/prosody-modules

return {
    -- XMLNS
    -- MIX
    mix_core = "urn:xmpp:mix:core:1";
    mix_anon = "urn:xmpp:mix:anon:0";
    mix_admin = "urn:xmpp:mix:admin:0";
    mix_presence = "urn:xmpp:mix:presence:0";
    -- MAM
    mam = "urn:xmpp:mam:2";
    -- User Avatar
    avatar = "urn:xmpp:avatar:data";
    avatar_metadata = "urn:xmpp:avatar:metadata";
    -- MIX PubSub nodes
    messages = "urn:xmpp:mix:nodes:messages";
    presence = "urn:xmpp:mix:nodes:presence";
    participants = "urn:xmpp:mix:nodes:participants";
    info = "urn:xmpp:mix:nodes:info";
    allowed = "urn:xmpp:mix:nodes:allowed";
    banned = "urn:xmpp:mix:nodes:banned";
    config = "urn:xmpp:mix:nodes:config";
    -- PubSub
    pubsub = "http://jabber.org/protocol/pubsub";
    pubsub_event = "http://jabber.org/protocol/pubsub#event";
    pubsub_error = "http://jabber.org/protocol/pubsub#errors";
};
