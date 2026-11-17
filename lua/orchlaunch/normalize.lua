-- OrchLaunch — rewrite absolute paths as macros.
--
-- Older configurations stored the absolute build directory in `cwd` and the
-- absolute artifact in `target`. This module replaces only exact matches with
-- the equivalent macro (`${buildDir}`, `${sourceDir}`, `${workspace}`,
-- `${target}`), so the file keeps working when the project moves and matches
-- what the editor now generates. Anything that is not an exact match is left
-- alone.

local M = {}

local state = require("orchlaunch.state")
local cmake = require("orchlaunch.cmake")

--- Trailing-slash-insensitive equality for normalized absolute paths.
local function same_path(a, b)
    if type(a) ~= "string" or type(b) ~= "string" or a == "" or b == "" then
        return false
    end
    return vim.fs.normalize(a):gsub("/+$", "") == vim.fs.normalize(b):gsub("/+$", "")
end

--- Returns the macro form of `value`, or nil if it is not an exact match.
---@param value any
---@param table_of table<string, string> macro name -> absolute path
---@return string?
local function macro_for(value, table_of)
    if type(value) ~= "string" or value == "" then
        return nil
    end
    -- Priority order when two directories are equal (e.g. source == build).
    local order = { "buildDir", "sourceDir", "workspace" }
    for _, name in ipairs(order) do
        local dir = table_of[name]
        if dir and same_path(value, dir) then
            return "${" .. name .. "}"
        end
    end
    return nil
end

--- Plans the rewrite for one configuration. Returns a new table, or nil if
--- nothing needs to change.
---@param cfg table
---@return table?, string[]? changes
function M.plan(cfg)
    local dirs = {
        buildDir = cmake.binary_dir(),
        sourceDir = cmake.source_dir(),
        workspace = state.root(),
    }
    local changes = {}
    local updated = vim.deepcopy(cfg)

    local cwd_macro = macro_for(cfg.cwd, dirs)
    if cwd_macro then
        updated.cwd = cwd_macro
        changes[#changes + 1] = ("cwd: %s -> %s"):format(cfg.cwd, cwd_macro)
    end

    -- A target that is the absolute artifact path becomes the target name macro
    -- only when the configuration names an executable that the File API knows.
    if type(cfg.target) == "string" and cfg.target:find("[/\\]") then
        local known = nil
        for _, t in ipairs(cmake.targets() or {}) do
            local artifact = t.artifact
            if artifact and same_path(cfg.target, artifact) then
                known = t
                break
            end
        end
        if known then
            updated.target = known.name
            changes[#changes + 1] = ("target: %s -> %s"):format(cfg.target, known.name)
        end
    end

    if #changes == 0 then
        return nil
    end
    return updated, changes
end

--- Applies the rewrite to every run configuration and saves once.
---@return integer changed, string[] report
function M.run()
    local report = {}
    local changed = 0
    local configs = state.run_configurations().configurations or {}
    for _, cfg in ipairs(configs) do
        local updated, changes = M.plan(cfg)
        if updated then
            state.update_configuration(cfg.name, updated)
            changed = changed + 1
            for _, line in ipairs(changes) do
                report[#report + 1] = ("%s: %s"):format(cfg.name, line)
            end
        end
    end
    if changed > 0 then
        state.save()
    end
    return changed, report
end

return M
