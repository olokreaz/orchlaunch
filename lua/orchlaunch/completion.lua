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

--- Visual categories. Each one has its own icon and highlight group, so the
--- completion menu tells macros, vars and env apart. `hl` names a group defined
--- in `M.highlights()`, which links to a standard group and follows the theme.
M.KINDS = {
    macro = { icon = "󰅩", hl = "OrchLaunchCompletionMacro", name = "Macro" },
    var = { icon = "󰀫", hl = "OrchLaunchCompletionVar", name = "Variable" },
    env = { icon = "󰆧", hl = "OrchLaunchCompletionEnv", name = "Environment" },
    keyword = { icon = "󰌌", hl = "OrchLaunchCompletionKeyword", name = "Prefix" },
}

--- Highlight groups and the standard groups they link to. Linked, not coloured,
--- so a colourscheme change restyles them without any code change.
---@return table<string, string> group -> link target
function M.highlights()
    return {
        OrchLaunchCompletionMacro = "Include",
        OrchLaunchCompletionVar = "Identifier",
        OrchLaunchCompletionEnv = "Constant",
        OrchLaunchCompletionKeyword = "Keyword",
    }
end

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
    { label = "targetName", detail = "CMake target name (libraries too)" },
    { label = "targetDir", detail = "directory of the built artifact" },
    { label = "sourceParentDir", detail = "parent of the CMake source directory" },
    { label = "projectDir", detail = "alias of workspace (CLion $PROJECT_DIR$)" },
    { label = "userHome", detail = "home directory of the user" },
    { label = "tempDir", detail = "system temporary directory" },
    { label = "osName", detail = "operating system name (Linux, Darwin, ...)" },
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
---@return { label: string, insert: string, detail: string, kind: table }[]
function M.items(prefix, bufnr)
    local out = {}
    local K = M.KINDS
    if prefix:sub(1, 4) == "env:" then
        for _, name in ipairs(M.env_names()) do
            out[#out + 1] = { label = "env:" .. name, insert = "env:" .. name .. "}", detail = "environment variable", kind = K.env }
        end
        return out
    end

    if prefix:sub(1, 4) == "var:" then
        for _, name in ipairs(M.var_names(bufnr)) do
            out[#out + 1] = { label = "var:" .. name, insert = "var:" .. name .. "}", detail = "from this step's vars", kind = K.var }
        end
        return out
    end

    for _, m in ipairs(M.MACROS) do
        out[#out + 1] = { label = m.label, insert = m.label .. "}", detail = m.detail, kind = K.macro }
    end
    out[#out + 1] = { label = "var:", insert = "var:", detail = "value from the step's vars", kind = K.keyword }
    out[#out + 1] = { label = "env:", insert = "env:", detail = "environment variable", kind = K.keyword }
    return out
end

return M
