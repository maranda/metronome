local log = require "util.logger".init("net.connlisteners");
local traceback = debug.traceback;

module "httpserver"

function fail()
	log("error", "Attempt to use legacy connlisteners API.");
	log("error", "Legacy connlisteners API usage, %s", traceback("", 2));
end

register, deregister = fail, fail;
get, start = fail, fail, epic_fail;

return _M;
