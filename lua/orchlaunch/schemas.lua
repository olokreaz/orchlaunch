-- OrchLaunch — JSON Schema integration for jsonls (vscode-json-language-server).
--
-- This module handles automatic registration of OrchLaunch schemas with
-- jsonls when it attaches to buffers inside a .orch directory.

local M = {}

local function get_plugin_root()
    -- Resolve the plugin root from the location of this file
    local source = debug.getinfo(1, "S").source
    local path = source:sub(2) -- remove leading '@'
    -- path is .../lua/orchlaunch/schemas.lua
    local root = vim.fs.dirname(vim.fs.dirname(vim.fs.dirname(path)))
    return vim.fs.normalize(root)
end

local function get_schema_dir()
    return vim.fs.joinpath(get_plugin_root(), "schemas")
end

local function url_encode(path)
    return path:gsub(" ", "%%20")
end

local function file_url(path)
    return "file://" .. url_encode(vim.fs.normalize(path))
end

--- Returns the schema mappings for jsonls.
--- Each mapping has fileMatch patterns and a file:// URL to the schema.
---@return table[]
function M.mappings()
    local schema_dir = get_schema_dir()
    return {
        {
            fileMatch = { "**/.orch/run_configurations.json" },
            url = file_url(vim.fs.joinpath(schema_dir, "run_configurations.schema.json"))
        },
        {
            fileMatch = { "**/.orch/external_tools.json" },
            url = file_url(vim.fs.joinpath(schema_dir, "external_tools.schema.json"))
        },
        {
            fileMatch = { "**/.orch/toolchain.json" },
            url = file_url(vim.fs.joinpath(schema_dir, "toolchain.schema.json"))
        },
        {
            fileMatch = { "**/.orch/cmake_settings.json" },
            url = file_url(vim.fs.joinpath(schema_dir, "cmake_settings.schema.json"))
        },
    }
end

--- GitHub raw URLs for write_schema_ref option
---@return table<string, string>
function M.github_urls()
    return {
        run_configurations = "https://raw.githubusercontent.com/olokreaz/orchlaunch/master/schemas/run_configurations.schema.json",
        external_tools = "https://raw.githubusercontent.com/olokreaz/orchlaunch/master/schemas/external_tools.schema.json",
        toolchain = "https://raw.githubusercontent.com/olokreaz/orchlaunch/master/schemas/toolchain.schema.json",
        cmake_settings = "https://raw.githubusercontent.com/olokreaz/orchlaunch/master/schemas/cmake_settings.schema.json",
    }
end

--- Checks if a buffer path is inside a .orch directory.
---@param bufnr integer
---@return boolean
local function is_orch_buffer(bufnr)
    local name = vim.api.nvim_buf_get_name(bufnr)
    if name == "" then return false end
    local dir = vim.fs.dirname(name)
    return vim.fs.find(".orch", { path = dir, upward = true })[1] ~= nil
end

--- Gets the schema key for a buffer (run_configurations, external_tools, etc.)
---@param bufnr integer
---@return string?
local function get_schema_key(bufnr)
    local name = vim.api.nvim_buf_get_name(bufnr)
    if name == "" then return nil end
    local filename = vim.fs.basename(name)
    if filename == "run_configurations.json" then return "run_configurations" end
    if filename == "external_tools.json" then return "external_tools" end
    if filename == "toolchain.json" then return "toolchain" end
    if filename == "cmake_settings.json" then return "cmake_settings" end
    if filename == "breakpoints.json" then return "breakpoints" end
    return nil
end

--- Merges new schemas with existing client schemas, avoiding duplicates.
---@param existing table[]
---@param new table[]
---@return table[]
local function merge_schemas(existing, new)
    local seen = {}
    local result = {}

    for _, schema in ipairs(existing) do
        local key = schema.url or schema.fileMatch and schema.fileMatch[1]
        if key and not seen[key] then
            seen[key] = true
            result[#result + 1] = schema
        end
    end

    for _, schema in ipairs(new) do
        local key = schema.url or schema.fileMatch and schema.fileMatch[1]
        if key and not seen[key] then
            seen[key] = true
            result[#result + 1] = schema
        end
    end

    return result
end

--- Applies schema configuration to a jsonls client.
---@param client vim.lsp.Client
---@param mappings table[]
local function apply_schemas_to_client(client, mappings)
    local settings = client.config.settings
    if not settings then
        settings = {}
        client.config.settings = settings
    end
    if not settings.json then
        settings.json = {}
    end
    if not settings.json.schemas then
        settings.json.schemas = {}
    end

    settings.json.schemas = merge_schemas(settings.json.schemas, mappings)

    -- Notify the client of the configuration change
    client.notify("workspace/didChangeConfiguration", { settings = settings })
end

--- Sets up automatic schema registration for jsonls.
---@param opts? { jsonls?: boolean, write_schema_ref?: boolean }
function M.setup(opts)
    opts = opts or {}
    local jsonls_enabled = opts.jsonls ~= false
    local write_schema_ref = opts.write_schema_ref == true

    if not jsonls_enabled then
        return
    end

    local group = vim.api.nvim_create_augroup("OrchLaunchSchemas", { clear = true })

    -- When jsonls attaches to a buffer in .orch/, register our schemas
    vim.api.nvim_create_autocmd("LspAttach", {
        group = group,
        callback = function(args)
            local client = vim.lsp.get_client_by_id(args.data.client_id)
            if not client then return end

            -- Check if this is jsonls (could be named jsonls, json-lsp, etc.)
            local name = client.name:lower()
            if name ~= "jsonls" and name ~= "json-lsp" then
                return
            end

            -- Only apply to buffers in .orch directories
            if not is_orch_buffer(args.buf) then
                return
            end

            apply_schemas_to_client(client, M.mappings())
        end,
    })

    -- Also handle case where buffer is already open when jsonls starts
    vim.api.nvim_create_autocmd("FileType", {
        group = group,
        pattern = "json",
        callback = function(args)
            if not is_orch_buffer(args.buf) then return end

            -- Check existing clients
            for _, client in pairs(vim.lsp.get_clients({ bufnr = args.buf })) do
                local name = client.name:lower()
                if name == "jsonls" or name == "json-lsp" then
                    apply_schemas_to_client(client, M.mappings())
                    break
                end
            end
        end,
    })

    -- Write $schema reference when saving .orch files (if enabled)
    if write_schema_ref then
        vim.api.nvim_create_autocmd("BufWritePre", {
            group = group,
            callback = function(args)
                if not is_orch_buffer(args.buf) then return end
                local key = get_schema_key(args.buf)
                if not key then return end

                local urls = M.github_urls()
                local url = urls[key]
                if not url then return end

                local lines = vim.api.nvim_buf_get_lines(args.buf, 0, -1, false)
                local content = table.concat(lines, "\n")
                local ok, parsed = pcall(vim.json.decode, content)
                if not ok or type(parsed) ~= "table" then return end

                if parsed["$schema"] == url then return end

                parsed["$schema"] = url
                local new_content = vim.json.encode(parsed)
                -- Pretty-print with indentation
                local formatted = vim.fn.system("jq . 2>/dev/null", new_content)
                if vim.v.shell_error ~= 0 then
                    formatted = new_content
                end
                vim.api.nvim_buf_set_lines(args.buf, 0, -1, false, vim.split(formatted, "\n"))
            end,
        })
    end
end

--- Returns diagnostic info for :OrchLaunchCheck
---@return table
function M.check_info()
    local info = {
        jsonls_found = false,
        jsonls_clients = {},
        schemas_registered = false,
    }

    for _, client in pairs(vim.lsp.get_clients()) do
        local name = client.name:lower()
        if name == "jsonls" or name == "json-lsp" then
            info.jsonls_found = true
            info.jsonls_clients[#info.jsonls_clients + 1] = {
                name = client.name,
                id = client.id,
                root_dir = client.config.root_dir,
            }

            -- Check if our schemas are registered
            local settings = client.config.settings
            if settings and settings.json and settings.json.schemas then
                for _, schema in ipairs(settings.json.schemas) do
                    if schema.url and schema.url:match("orchlaunch") then
                        info.schemas_registered = true
                        break
                    end
                end
            end
        end
    end

    return info
end

return M