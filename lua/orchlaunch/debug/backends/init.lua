-- OrchLaunch — built-in debugger backends.
--
-- Requiring this module registers every bundled backend and returns the shared
-- registry, so callers can `require("orchlaunch.debug.backends").resolve(req)`.

require("orchlaunch.debug.backends.lldb")
require("orchlaunch.debug.backends.gdb")

return require("orchlaunch.debug.backend")
