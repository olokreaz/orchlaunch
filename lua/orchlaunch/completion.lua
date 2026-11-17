-- OrchLaunch — completion for `${...}` macros in `.orch/*.json`.
--
-- The JSON Schema cannot complete text inside a string, so this module provides
-- a blink.cmp source. It offers:
--   * the macros from config.expand (`${workspace}`, `${buildDir}`, ...)
--   * `${var:name}` for names declared in the nearest before-step `vars`
--   * `${env:NAME}` for environment variables that are set
--
-- Used only inside `.orch` JSON files; any other buffer returns no items.

local M = {}

--- Macros documented in config.expand, with a short description each.
M.MACROS = {
    { label = "workspace", detail = "project root" },
    { label = "orch", detail = "the .orch directory" },
    { label = "buildDir", detail = "CMake binary directory" },
    { label = "sourceDir", detail = "CMake source directory" },
    { label = "buildType", detail = "active build type (Debug, Release, ...)" },
    { label = "toolchain", detail = "active toolchain name" },
    { label = "target", detail = "this configuration's CMake target" },
    { label = "targetPath", detail = "built artifact of that target" },
    { label = "projectName", detail = "basename of the workspace" },
}

--- Text the cursor is inside of when the completion starts: the `${...}` opener
--- before the cursor, or nil. Returns the typed prefix after `${`.
---@param before_cursor string
---@return string? prefix
function M.prefix_at(before_cursor)
    local prefix = before_cursor:match("%${([%w_:%?]*)$")
    return prefix
end

--- Names declared in `vars` of the before-steps in this buffer, so `${var:`
--- can offer them.
---@param bufnr integer
---@return string[]
function M.var_names(bufnr)
    local jsonpos = require("orchlaunch.jsonpos")
    local root = jsonpos.parse_buffer(bufnr)
    local names, seen = {}, {}
    if not root then
        return names
    end

    -- configurations[].before.tools[].vars: only declared names are offered.
    local configs = jsonpos.get(root, "configurations")
    for _, cfg in ipairs(configs and configs.kind == "array" and configs.items or {}) do
        local before = jsonpos.get(cfg, "before")
        local steps = before and jsonpos.get(before, "tools")
        for _, step in ipairs(steps and steps.kind == "array" and steps.items or {}) do
            local vars = jsonpos.get(step, "vars")
            for _, member in ipairs(vars and vars.kind == "object" and vars.members or {}) do
                if not seen[member.key] then
                    seen[member.key] = true
                    names[#names + 1] = member.key
                end
            end
        end
    end
    table.sort(names)
    return names
end

--- Set environment variables, sorted by name. Reads the process environment
--- only, never writes it.
---@return string[]
function M.env_names()
    local names = vim.tbl_keys(vim.fn.environ())
    table.sort(names)
    return names
end

--- Items for a prefix typed after `${`.
---   ""        -> macros, `var:` and `env:` starters
---   "var:"    -> names from the before-step vars
---   "env:"    -> environment variables
---@param prefix string
---@param bufnr integer
---@return { label: string, insert: string, detail: string }[]
function M.items(prefix, bufnr)
    local out = {}
    if prefix:sub(1, 4) == "env:" then
        for _, name in ipairs(M.env_names()) do
            out[#out + 1] = { label = "env:" .. name, insert = "env:" .. name .. "}", detail = "environment variable" }
        end
        return out
    end

    if prefix:sub(1, 4) == "var:" then
        for _, name in ipairs(M.var_names(bufnr)) do
            out[#out + 1] = { label = "var:" .. name, insert = "var:" .. name .. "}", detail = "vars." .. name }
        end
        -- `${var:name?default}` form is offered by hand, the default is typed.
        return out
    end

    for _, m in ipairs(M.MACROS) do
        out[#out + 1] = { label = m.label, insert = m.label .. "}", detail = m.detail }
    end
    out[#out + 1] = { label = "var:", insert = "var:", detail = "value from the step's vars" }
    out[#out + 1] = { label = "env:", insert = "env:", detail = "environment variable" }
    return out
end

--- blink.cmp source. Register with:
---   sources.providers.orchlaunch = { name = "orchlaunch", module = "orchlaunch.completion.blink" }
--- and add "orchlaunch" to `sources.default` (or to `per_filetype.json`).
return M
