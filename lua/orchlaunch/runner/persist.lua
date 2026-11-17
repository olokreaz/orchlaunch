-- OrchLaunch — persistence the runner does before it acts on the project.
--
-- Saving can fail (for example when a file changed on disk). The runner must
-- still act on what is in memory, so a failed save is ignored here; the save
-- path itself reports the problem to the user.

local state = require("orchlaunch.state")

local M = {}

--- Saves the project state before a CMake step or a launch reads it.
function M.before_action()
    pcall(state.save)
end

return M
