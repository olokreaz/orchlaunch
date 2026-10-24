-- OrchLaunch — Semantic validation for configuration files.
--
-- Provides validation beyond JSON Schema: cross-references, cycles,
-- missing targets, unknown toolchains, etc. Uses vim.diagnostic.

local config = require("orchlaunch.config")
local state = require("orchlaunch.state")

local M = {}

local ns = vim.api.nvim_create_namespace("orchlaunch")

---@class DiagnosticItem
---@field lnum integer
---@field col integer
---@field end_lnum integer
---@field end_col integer
---@field severity integer
---@field message string
---@field source string

--- Finds the line and column range of a JSON key-value pair by searching text.
---@param lines string[]
---@param key string
---@param value string
---@param start_line integer
---@return integer? lnum, integer? col, integer? end_lnum, integer? end_col
local function find_key_value(lines, key, value, start_line)
    local pattern = '"' .. key .. '"%s*:%s*"' .. value:gsub('([%(%)%.%%%+%-%*%?%[%]%^%$])', '%%%1') .. '"'
    for i = start_line, #lines do
        local line = lines[i]
        local s, e = line:find(pattern)
        if s then
            return i - 1, s - 1, i - 1, e
        end
    end
    return nil
end

--- Finds the line of an object containing a specific key-value pair.
---@param lines string[]
---@param obj_start integer
---@param target_key string
---@param target_value string
---@return integer? lnum, integer? col, integer? end_lnum, integer? end_col
local function find_in_object(lines, obj_start, target_key, target_value)
    local brace_depth = 0
    local in_target = false

    for i = obj_start, #lines do
        local line = lines[i]
        for _, ch in ipairs(vim.fn.split(line, "")) do
            if ch == "{" then
                if brace_depth == 0 then in_target = true end
                brace_depth = brace_depth + 1
            elseif ch == "}" then
                brace_depth = brace_depth - 1
                if brace_depth == 0 and in_target then return end
            end
        end

        if brace_depth >= 1 then
            local key, val = line:match('"(%w+)"%s*:%s*"([^"]*)"')
            if key == "name" then
                -- This is a new object, check if it's our target
            end
        end
    end
    return nil
end

--- Finds all configuration objects in the buffer and returns their info.
---@param bufnr integer
---@return table[]
local function parse_configurations(bufnr)
    local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
    local configs = {}

    local in_configs = false
    local brace_depth = 0
    local obj_start = nil
    local current = {}

    for i, line in ipairs(lines) do
        local trimmed = line:match("^%s*(.*)") or ""

        if not in_configs and trimmed:match('"configurations"%s*:%s*%[') then
            in_configs = true
        end

        if in_configs then
            for _, ch in ipairs(vim.fn.split(line, "")) do
                if ch == "{" then
                    if brace_depth == 1 then
                        current = { start_line = i - 1 }
                    end
                    brace_depth = brace_depth + 1
                elseif ch == "}" then
                    brace_depth = brace_depth - 1
                    if brace_depth == 1 then
                        current.end_line = i - 1
                        configs[#configs + 1] = vim.deepcopy(current)
                        current = {}
                    end
                end
            end

            if brace_depth >= 2 then
                local key, val = line:match('"(%w+)"%s*:%s*"([^"]*)"')
                if key and val then
                    current[key] = val
                end
            end
        end
    end

    return configs
end

--- Validates run_configurations.json buffer.
---@param bufnr integer
---@return DiagnosticItem[]
local function validate_run_configurations(bufnr)
    local diagnostics = {}
    if not state.is_loaded() then return diagnostics end

    local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
    local configs = parse_configurations(bufnr)

    -- Build lookup tables from state
    local cmake_targets = {}
    local cmake = state.cmake()
    if cmake then
        local runner = require("orchlaunch.runner")
        local targets = runner.load_cmake()
        if targets then
            for _, t in ipairs(targets) do
                cmake_targets[t.name] = t
            end
        end
    end

    local toolchains = {}
    for _, tc in ipairs(state.toolchains().toolchains) do
        toolchains[tc.name] = true
    end

    local profiles = {}
    for _, p in ipairs(state.cmake().profiles) do
        profiles[p.name] = true
    end

    local ext_tools = {}
    for _, t in ipairs(state.external_tools().tools) do
        ext_tools[t.name] = true
    end

    local config_names = {}
    for _, c in ipairs(state.run_configurations().configurations) do
        config_names[c.name] = true
    end

    for _, cfg in ipairs(configs) do
        local start_line = cfg.start_line
        local end_line = cfg.end_line

        -- Check for duplicate names
        if cfg.name and config_names[cfg.name] then
            -- Count occurrences
            local count = 0
            for _, c in ipairs(configs) do
                if c.name == cfg.name then count = count + 1 end
            end
            if count > 1 then
                diagnostics[#diagnostics + 1] = {
                    lnum = cfg.start_line,
                    col = 0,
                    end_lnum = cfg.start_line,
                    end_col = -1,
                    severity = vim.diagnostic.severity.ERROR,
                    message = ("Duplicate configuration name: %s"):format(cfg.name),
                    source = "orchlaunch",
                }
            end
        end

        if cfg.type == "native" then
            -- Check target exists
            if cfg.target then
                local target_name = cfg.target
                local is_path = target_name:find("[/\\]") or vim.fn.filereadable(target_name) == 1
                if not is_path and not cmake_targets[target_name] then
                    local l, c, el, ec = find_key_value(vim.api.nvim_buf_get_lines(0, 0, -1, false), "target", cfg.target, cfg.start_line)
                    diagnostics[#diagnostics + 1] = {
                        lnum = l or cfg.start_line,
                        col = c or 0,
                        end_lnum = el or cfg.start_line,
                        end_col = ec or -1,
                        severity = vim.diagnostic.severity.WARN,
                        message = ("CMake target not found: %s"):format(target_name),
                        source = "orchlaunch",
                    }
                end
            end

            -- Check sudo with hidden/none console
            if cfg.sudo == true and cfg.console and (cfg.console.mode == "hidden" or cfg.console.mode == "none") then
                local l, c, el, ec = find_key_value(vim.api.nvim_buf_get_lines(0, 0, -1, false), "sudo", "true", cfg.start_line)
                diagnostics[#diagnostics + 1] = {
                    lnum = l or cfg.start_line,
                    col = c or 0,
                    end_lnum = el or cfg.start_line,
                    end_col = ec or -1,
                    severity = vim.diagnostic.severity.WARN,
                    message = "sudo is incompatible with console mode hidden/none (no TTY for password prompt)",
                    source = "orchlaunch",
                }
            end

            -- Check empty native (no target and no before steps)
            if not cfg.target and not cfg.runtime and not (cfg.before and cfg.before.tools and #cfg.before.tools > 0) then
                diagnostics[#diagnostics + 1] = {
                    lnum = cfg.start_line,
                    col = 0,
                    end_lnum = cfg.end_line,
                    end_col = -1,
                    severity = vim.diagnostic.severity.INFO,
                    message = "Native configuration has no target, no runtime, and no before-launch steps",
                    source = "orchlaunch",
                }
            end

        elseif cfg.type == "remote-debug" then
            if not cfg.connection or cfg.connection == "" then
                diagnostics[#diagnostics + 1] = {
                    lnum = cfg.start_line,
                    col = 0,
                    end_lnum = cfg.end_line,
                    end_col = -1,
                    severity = vim.diagnostic.severity.ERROR,
                    message = "remote-debug configuration requires 'connection' (host:port)",
                    source = "orchlaunch",
                }
            end
        elseif cfg.type == "compound" then
            -- Check for cycles and missing references
            if cfg.configurations then
                local visited = {}
                local function check_cycle(name, path)
                    if visited[name] then return end
                    visited[name] = true
                    path[#path + 1] = name

                    local child_cfg = state.configuration(name)
                    if not child_cfg then
                        diagnostics[#diagnostics + 1] = {
                            lnum = cfg.start_line,
                            col = 0,
                            end_lnum = cfg.end_line,
                            end_col = -1,
                            severity = vim.diagnostic.severity.ERROR,
                            message = ("Compound references unknown configuration: %s"):format(name),
                            source = "orchlaunch",
                        }
                    elseif child_cfg.type == "compound" and child_cfg.configurations then
                        for _, cname in ipairs(child_cfg.configurations) do
                            for _, p in ipairs(path) do
                                if p == cname then
                                    diagnostics[#diagnostics + 1] = {
                                        lnum = cfg.start_line,
                                        col = 0,
                                        end_lnum = cfg.end_line,
                                        end_col = -1,
                                        severity = vim.diagnostic.severity.ERROR,
                                        message = ("Compound configuration cycle detected: %s"):format(table.concat(path, " -> ") .. " -> " .. cname),
                                        source = "orchlaunch",
                                    }
                                end
                            end
                            check_cycle(cname, vim.deepcopy(path))
                        end
                    end
                end

                for _, child in ipairs(cfg.configurations) do
                    check_cycle(child, { cfg.name })
                end
            end
        end

        -- Validate before-launch tools
        if cfg.before and cfg.before.tools then
            for _, tool in ipairs(cfg.before.tools) do
                if type(tool) == "table" and tool.type == "external" and tool.tool then
                    if not ext_tools[tool.tool] then
                        diagnostics[#diagnostics + 1] = {
                            lnum = cfg.start_line,
                            col = 0,
                            end_lnum = cfg.end_line,
                            end_col = -1,
                            severity = vim.diagnostic.severity.WARN,
                            message = ("Before-launch references unknown external tool: %s"):format(tool.tool),
                            source = "orchlaunch",
                        }
                    end
                elseif type(tool) == "table" and (tool.type == "build" or tool.type == "install") and tool.target then
                    -- Could validate target exists
                end
            end
        end
    end

    return diagnostics
end

--- Validates external_tools.json buffer.
---@param bufnr integer
---@return DiagnosticItem[]
local function validate_external_tools(bufnr)
    local diagnostics = {}
    if not state.is_loaded() then return diagnostics end

    local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
    local data, err = config.load(vim.api.nvim_buf_get_name(bufnr))
    if not data or not data.tools then return diagnostics end

    for i, tool in ipairs(data.tools) do
        if type(tool) == "table" and tool.name then
            -- Could check program exists, but that's slow
        end
    end
    return diagnostics
end

--- Validates toolchain.json buffer.
---@param bufnr integer
---@return DiagnosticItem[]
local function validate_toolchain(bufnr)
    local diagnostics = {}
    if not state.is_loaded() then return diagnostics end

    local data, err = config.load(vim.api.nvim_buf_get_name(bufnr))
    if not data or not data.toolchains then return diagnostics end

    for i, tc in ipairs(data.toolchains) do
        if type(tc) == "table" and tc.name then
            -- Could validate compiler paths exist
        end
    end
    return diagnostics
end

--- Validates cmake_settings.json buffer.
---@param bufnr integer
---@return DiagnosticItem[]
local function validate_cmake_settings(bufnr)
    local diagnostics = {}
    if not state.is_loaded() then return diagnostics end

    local data, err = config.load(vim.api.nvim_buf_get_name(bufnr))
    if not data then return diagnostics end

    local doc = data.cmake or data.settings or data
    if doc and doc.profiles then
        local profiles = doc.profiles
        local toolchain_names = {}
        for _, tc in ipairs(state.toolchains().toolchains) do
            toolchain_names[tc.name] = true
        end

        for i, profile in ipairs(profiles) do
            if profile.toolchain and not toolchain_names[profile.toolchain] then
                diagnostics[#diagnostics + 1] = {
                    lnum = 0,
                    col = 0,
                    end_lnum = 0,
                    end_col = -1,
                    severity = vim.diagnostic.severity.WARN,
                    message = ("Profile '%s' references unknown toolchain: %s"):format(profile.name or "?", profile.toolchain),
                    source = "orchlaunch",
                }
            end
        end
    end
    return diagnostics
end

--- Validates a buffer and updates diagnostics.
---@param bufnr integer
function M.validate_buffer(bufnr)
    if not vim.api.nvim_buf_is_valid(bufnr) then return end

    local filename = vim.fs.basename(vim.api.nvim_buf_get_name(bufnr))
    local diagnostics = {}

    if filename == "run_configurations.json" then
        diagnostics = validate_run_configurations(bufnr)
    elseif filename == "external_tools.json" then
        diagnostics = validate_external_tools(bufnr)
    elseif filename == "toolchain.json" then
        diagnostics = validate_toolchain(bufnr)
    elseif filename == "cmake_settings.json" then
        diagnostics = validate_cmake_settings(bufnr)
    end

    vim.diagnostic.set(ns, bufnr, diagnostics, { source = "orchlaunch" })
end

--- Clears diagnostics for a buffer.
---@param bufnr integer
function M.clear_diagnostics(bufnr)
    vim.diagnostic.reset(ns, bufnr)
end

return M