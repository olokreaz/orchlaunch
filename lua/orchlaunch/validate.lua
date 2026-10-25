-- OrchLaunch — Semantic validation for configuration files.
--
-- JSON Schema (via jsonls) checks structure; this module checks meaning:
-- cross references, duplicate names, compound cycles, unknown targets, ...
--
-- The checks are pure functions of the document text and a small context
-- (`M.check`), so they are easy to test. `M.validate_buffer` wires them to
-- `vim.diagnostic`. Nothing here spawns a process: CMake targets come from the
-- cached model only.

local jsonpos = require("orchlaunch.jsonpos")
local state = require("orchlaunch.state")

local M = {}

local ns = vim.api.nvim_create_namespace("orchlaunch")
local SEV = vim.diagnostic.severity

local TOOLCHAIN_TYPES = { system = true, unix = true, msvc = true }
local CONFIGURATION_TYPES = { native = true, ["remote-debug"] = true, compound = true }

---@class OrchDiagnostic
---@field lnum integer
---@field col integer
---@field end_lnum integer
---@field end_col integer
---@field severity integer
---@field message string
---@field source string

---@class OrchValidationContext
---@field targets? table<string, boolean> CMake target names; nil when unknown.
---@field toolchains table<string, boolean>
---@field tools table<string, boolean> External tool names.

--- Builds a diagnostic spanning a node.
---@param node OrchJsonNode
---@param severity integer
---@param message string
---@return OrchDiagnostic
local function at_node(node, severity, message)
    return {
        lnum = node.line,
        col = node.col,
        end_lnum = node.end_line,
        end_col = node.end_col,
        severity = severity,
        message = message,
        source = "orchlaunch",
    }
end

--- Builds a diagnostic for an object: highlights its first line.
---@param node OrchJsonNode
---@param severity integer
---@param message string
---@return OrchDiagnostic
local function at_object(node, severity, message)
    return {
        lnum = node.line,
        col = node.col,
        end_lnum = node.line,
        end_col = -1,
        severity = severity,
        message = message,
        source = "orchlaunch",
    }
end

--- The diagnostic target for `key` of an object: its value when present,
--- otherwise the whole object.
---@param obj OrchJsonNode
---@param key string
---@param severity integer
---@param message string
---@return OrchDiagnostic
local function at_key(obj, key, severity, message)
    local value = jsonpos.get(obj, key)
    if value then
        return at_node(value, severity, message)
    end
    return at_object(obj, severity, message)
end

---@param node? OrchJsonNode
---@return boolean
local function is_nonempty_string(node)
    return node ~= nil and node.kind == "string" and node.value ~= ""
end

--- Items of an array node that are objects.
---@param node? OrchJsonNode
---@return OrchJsonNode[]
local function object_items(node)
    local out = {}
    if node and node.kind == "array" then
        for _, item in ipairs(node.items) do
            if item.kind == "object" then
                out[#out + 1] = item
            end
        end
    end
    return out
end

--- Reports duplicate `name` values (every occurrence) in a list of objects.
---@param objects OrchJsonNode[]
---@param what string
---@param out OrchDiagnostic[]
local function check_duplicate_names(objects, what, out)
    local seen = {}
    for _, obj in ipairs(objects) do
        local name = jsonpos.get(obj, "name")
        if is_nonempty_string(name) then
            seen[name.value] = (seen[name.value] or 0) + 1
        end
    end
    for _, obj in ipairs(objects) do
        local name = jsonpos.get(obj, "name")
        if is_nonempty_string(name) and seen[name.value] > 1 then
            out[#out + 1] = at_node(name, SEV.ERROR, ("Duplicate %s name: %s"):format(what, name.value))
        end
    end
end

---@param target string
---@return boolean
local function looks_like_path(target)
    return target:find("[/\\]") ~= nil or target:find("^%${") ~= nil
end

--- Compound cycle detection over the compounds defined in the document.
--- Returns the cycle chain (`{"A", "B", "A"}`) when walking from `start`
--- through `child` returns to a configuration already on the path.
---@param graph table<string, string[]>
---@param start string
---@param child string
---@return string[]?
local function find_cycle(graph, start, child)
    local path = { start }
    local on_path = { [start] = true }
    local function walk(name)
        if on_path[name] then
            local chain = vim.list_extend({}, path)
            chain[#chain + 1] = name
            return chain
        end
        local children = graph[name]
        if not children then
            return nil
        end
        on_path[name] = true
        path[#path + 1] = name
        for _, next_name in ipairs(children) do
            local chain = walk(next_name)
            if chain then
                return chain
            end
        end
        path[#path] = nil
        on_path[name] = nil
        return nil
    end
    return walk(child)
end

---@param root OrchJsonNode
---@param ctx OrchValidationContext
---@return OrchDiagnostic[]
local function check_run_configurations(root, ctx)
    local out = {}
    local list = jsonpos.get(root, "configurations")
    local configs = object_items(list)

    check_duplicate_names(configs, "configuration", out)

    -- names defined in this document, and the compound graph
    local names, graph = {}, {}
    for _, cfg in ipairs(configs) do
        local name = jsonpos.get_string(cfg, "name")
        if name and name ~= "" then
            names[name] = true
            if jsonpos.get_string(cfg, "type") == "compound" then
                local children = {}
                local array = jsonpos.get(cfg, "configurations")
                if array and array.kind == "array" then
                    for _, child in ipairs(array.items) do
                        if child.kind == "string" then
                            children[#children + 1] = child.value
                        end
                    end
                end
                graph[name] = children
            end
        end
    end

    for _, cfg in ipairs(configs) do
        local name = jsonpos.get_string(cfg, "name")
        local kind = jsonpos.get_string(cfg, "type")

        if kind and not CONFIGURATION_TYPES[kind] then
            out[#out + 1] = at_key(cfg, "type", SEV.WARN, ("Unknown configuration type: %s"):format(kind))
        end

        if kind == "native" then
            local target = jsonpos.get(cfg, "target")
            if is_nonempty_string(target) and not looks_like_path(target.value) then
                if ctx.targets == nil then
                    out[#out + 1] = at_node(
                        target,
                        SEV.HINT,
                        ("Cannot verify target %q: CMake targets are not loaded (run :OrchLaunchLoadCMake)"):format(
                            target.value
                        )
                    )
                elseif not ctx.targets[target.value] and vim.fn.filereadable(target.value) == 0 then
                    out[#out + 1] = at_node(target, SEV.WARN, ("CMake target not found: %s"):format(target.value))
                end
            end

            local sudo = jsonpos.get(cfg, "sudo")
            local console = jsonpos.get(cfg, "console")
            local mode = console and jsonpos.get_string(console, "mode")
            if sudo and sudo.kind == "boolean" and sudo.value == true and (mode == "hidden" or mode == "none") then
                out[#out + 1] = at_node(
                    sudo,
                    SEV.WARN,
                    "sudo is incompatible with console mode hidden/none (no TTY for the password prompt)"
                )
            end

            local before = jsonpos.get(cfg, "before")
            local before_tools = before and jsonpos.get(before, "tools")
            local has_before = before_tools and before_tools.kind == "array" and #before_tools.items > 0
            if not is_nonempty_string(target) and not jsonpos.get(cfg, "runtime") and not has_before then
                out[#out + 1] = at_object(
                    cfg,
                    SEV.INFO,
                    "Native configuration has no target, no runtime, and no before-launch steps"
                )
            end
        elseif kind == "remote-debug" then
            if not is_nonempty_string(jsonpos.get(cfg, "connection")) then
                out[#out + 1] = at_object(cfg, SEV.ERROR, "remote-debug configuration requires 'connection' (host:port)")
            end
        elseif kind == "compound" then
            local array = jsonpos.get(cfg, "configurations")
            if array and array.kind == "array" then
                for _, child in ipairs(array.items) do
                    if child.kind == "string" then
                        local cycle = name and find_cycle(graph, name, child.value)
                        if cycle then
                            out[#out + 1] = at_node(
                                child,
                                SEV.ERROR,
                                ("Compound configuration cycle: %s"):format(table.concat(cycle, " -> "))
                            )
                        elseif not names[child.value] then
                            out[#out + 1] = at_node(
                                child,
                                SEV.ERROR,
                                ("Compound references unknown configuration: %s"):format(child.value)
                            )
                        end
                    end
                end
            end
        end

        -- before-launch steps
        local before = jsonpos.get(cfg, "before")
        local steps = before and jsonpos.get(before, "tools")
        if steps and steps.kind == "array" then
            for _, step in ipairs(steps.items) do
                if step.kind == "object" then
                    local step_type = jsonpos.get_string(step, "type")
                    if step_type == "external" then
                        local tool = jsonpos.get(step, "tool")
                        if is_nonempty_string(tool) and not ctx.tools[tool.value] then
                            out[#out + 1] = at_node(
                                tool,
                                SEV.WARN,
                                ("Before-launch references unknown external tool: %s"):format(tool.value)
                            )
                        end
                    elseif (step_type == "build" or step_type == "install") and ctx.targets then
                        local target = jsonpos.get(step, "target")
                        if is_nonempty_string(target) and not ctx.targets[target.value] then
                            out[#out + 1] = at_node(
                                target,
                                SEV.WARN,
                                ("Before-launch %s step references unknown CMake target: %s"):format(
                                    step_type,
                                    target.value
                                )
                            )
                        end
                    end
                end
            end
        end
    end

    return out
end

---@param root OrchJsonNode
---@return OrchDiagnostic[]
local function check_external_tools(root)
    local out = {}
    local tools = object_items(jsonpos.get(root, "tools"))
    check_duplicate_names(tools, "external tool", out)
    for _, tool in ipairs(tools) do
        if not is_nonempty_string(jsonpos.get(tool, "program")) then
            out[#out + 1] = at_object(tool, SEV.ERROR, "External tool requires 'program'")
        end
        if not is_nonempty_string(jsonpos.get(tool, "name")) then
            out[#out + 1] = at_object(tool, SEV.ERROR, "External tool requires 'name'")
        end
    end
    return out
end

---@param root OrchJsonNode
---@return OrchDiagnostic[]
local function check_toolchains(root)
    local out = {}
    local toolchains = object_items(jsonpos.get(root, "toolchains"))
    check_duplicate_names(toolchains, "toolchain", out)
    for _, tc in ipairs(toolchains) do
        for _, key in ipairs({ "name", "type", "cmake", "c", "cxx", "debugger" }) do
            if not is_nonempty_string(jsonpos.get(tc, key)) then
                out[#out + 1] = at_object(tc, SEV.ERROR, ("Toolchain requires '%s'"):format(key))
            end
        end
        local kind = jsonpos.get(tc, "type")
        if is_nonempty_string(kind) and not TOOLCHAIN_TYPES[kind.value] then
            out[#out + 1] = at_node(kind, SEV.WARN, ("Unknown toolchain type: %s (expected system, unix or msvc)"):format(kind.value))
        end
    end
    return out
end

---@param root OrchJsonNode
---@param ctx OrchValidationContext
---@return OrchDiagnostic[]
local function check_cmake_settings(root, ctx)
    local out = {}
    local doc = jsonpos.get(root, "cmake") or jsonpos.get(root, "settings") or root
    local profiles = object_items(jsonpos.get(doc, "profiles"))
    check_duplicate_names(profiles, "CMake profile", out)

    local defined = {}
    for _, profile in ipairs(profiles) do
        local name = jsonpos.get_string(profile, "name")
        if name then
            defined[name] = true
        end
        local toolchain = jsonpos.get(profile, "toolchain")
        if is_nonempty_string(toolchain) and not ctx.toolchains[toolchain.value] then
            out[#out + 1] = at_node(
                toolchain,
                SEV.WARN,
                ("Profile '%s' references unknown toolchain: %s"):format(name or "?", toolchain.value)
            )
        end
    end

    local active = jsonpos.get(doc, "active")
    if is_nonempty_string(active) and not defined[active.value] then
        out[#out + 1] = at_node(active, SEV.WARN, ("Active profile does not exist: %s"):format(active.value))
    end
    return out
end

--- Checks a configuration document. Pure: depends only on its arguments.
---
--- Invalid JSON yields a single syntax-error diagnostic.
---@param file_type "run_configurations" | "external_tools" | "toolchain" | "cmake_settings"
---@param text string
---@param ctx OrchValidationContext
---@return OrchDiagnostic[]
function M.check(file_type, text, ctx)
    local root, err, err_line, err_col = jsonpos.parse(text)
    if not root then
        return {
            {
                lnum = err_line or 0,
                col = err_col or 0,
                end_lnum = err_line or 0,
                end_col = (err_col or 0) + 1,
                severity = SEV.ERROR,
                message = "JSON syntax error: " .. tostring(err),
                source = "orchlaunch",
            },
        }
    end
    if root.kind ~= "object" then
        return { at_node(root, SEV.ERROR, "Expected a JSON object at the top level") }
    end

    if file_type == "run_configurations" then
        return check_run_configurations(root, ctx)
    elseif file_type == "external_tools" then
        return check_external_tools(root)
    elseif file_type == "toolchain" then
        return check_toolchains(root)
    elseif file_type == "cmake_settings" then
        return check_cmake_settings(root, ctx)
    end
    return {}
end

--- Builds the validation context from the loaded project. Never spawns a
--- process: CMake targets come from the cached model (or `nil` when unknown).
---@return OrchValidationContext
function M.context()
    local ctx = { targets = nil, toolchains = {}, tools = {} }
    if not state.is_loaded() then
        return ctx
    end

    for _, tc in ipairs(state.toolchains().toolchains) do
        ctx.toolchains[tc.name] = true
    end
    for _, tool in ipairs(state.external_tools().tools) do
        ctx.tools[tool.name] = true
    end

    local ok, targets = pcall(function()
        return require("orchlaunch.cmake").targets()
    end)
    if ok and type(targets) == "table" and #targets > 0 then
        ctx.targets = {}
        for _, target in ipairs(targets) do
            ctx.targets[target.name] = true
        end
    end
    return ctx
end

--- Maps a file name to its document type.
---@param filename string
---@return string?
local function file_type_of(filename)
    local base = filename:gsub("%.json$", "")
    if base == "run_configurations" or base == "external_tools" or base == "toolchain" or base == "cmake_settings" then
        return base
    end
    return nil
end

--- Validates a buffer (its current, possibly unsaved, content) and publishes
--- diagnostics.
---@param bufnr integer
---@return OrchDiagnostic[]? diagnostics
function M.validate_buffer(bufnr)
    if not vim.api.nvim_buf_is_valid(bufnr) then
        return nil
    end
    local file_type = file_type_of(vim.fs.basename(vim.api.nvim_buf_get_name(bufnr)))
    if not file_type then
        return nil
    end

    local text = table.concat(vim.api.nvim_buf_get_lines(bufnr, 0, -1, false), "\n")
    local diagnostics = M.check(file_type, text, M.context())
    vim.diagnostic.set(ns, bufnr, diagnostics, { source = "orchlaunch" })
    return diagnostics
end

--- Clears diagnostics for a buffer.
---@param bufnr integer
function M.clear_diagnostics(bufnr)
    vim.diagnostic.reset(ns, bufnr)
end

return M
