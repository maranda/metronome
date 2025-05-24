![Metronome](https://archon.im/wp-content/uploads/2025/05/metronome-banner.png)
-

This software codebase began as a fork of prosody trunk (to be 0.9) merged with LW.Org's custom patches, initiating from August 7th 2012 (see first commit).

Being mainly based on Prosody a lot of Metronome's code is backport compatible, but as development keeps progressing the majority of the codebase has almost completely diverged from mainstream.

Differences from Prosody are, but not limited to:

 * The Pubsub API and wrapped modules, mod_pubsub and mod_pep
 * The MUC API and wrapper plugins
 * Pluggable MUC configuration
 * Pluggable Routing API
 * Core stack: Modulemanager, Usermanager, Hostmanager, Module API, etc...
 * More aggressive memory usage optimisations
 * Bidirectional S2S Streams
 * Direct TLS S2S Streams and XEP-0368 resolution
 * Dialback errors handling and "DB without DB" (XEP-344)
 * The anonymous auth backend (mod_auth_anonymous & sasl.lua ineherent part)
 * Included plugins, utils
 * SPIM prevention system
 * Hits/blacklist/whitelist based host filtering (mod_gate_guard)
 * In-Band Registration verification and account locking mechanism
 * The HTTP API
 * XEP-0252 support for BOSH's JSON Padding
 * Extensive Microblogging over XMPP support
 * Daemon Control Utility
 * It does have only one server backend being libevent and has a hard dep. on lua-event