![alt text](https://metronome.im/Media/Metronome/Pictures/metronome-banner.png)
-

This software codebase initiated as a fork of prosody trunk (to be 0.9) merged with LW.Org's custom, patches initiating from August 7th 2012 (see first commit).

Being mainly based on Prosody a lot of Metronome's code is backport compatible, but as development progressed a good portion of it completely diverged from mainstream's to better suit LW.Org IM's needs.

Differences from Prosody are, but not limited to:

 * The Pubsub API and wrapped modules, mod_pubsub and mod_pep
 * The MUC API and wrapper plugins
 * Pluggable MUC configuration
 * Pluggable Routing API
 * Core stack: Modulemanager, Usermanager, Hostmanager, Module API, etc...
 * More aggressive memory usage optimisations
 * Bidirectional S2S Streams
 * Dialback errors handling and "DB without DB" (XEP-344)
 * The anonymous auth backend (mod_auth_anonymous & sasl.lua ineherent part)
 * Included plugins, utils
 * SPIM prevention system
 * Hits/blacklist/whitelist based host filtering (mod_gate_guard)
 * The HTTP API
 * BOSH's JSON Padding and XEP-0252 support
 * Extensive Microblogging over XMPP support
 * Daemon Control Utility
 * It does have only one server backend being libevent and has a hard dep. on lua-event