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

--- file:// URL of a path, with every special character percent-encoded.
---@param path string
---@return string
local function file_url(path)
    return vim.uri_from_fname(vim.fs.normalize(path))
end

local jsonpos = require("orchlaunch.jsonpos")

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

--- Checks if a buffer path is inside a `.orch` directory (not merely somewhere
--- below a project that has one: a `package.json` or a user's own
--- `toolchain.json` next to `.orch/` must be left alone).
---@param bufnr integer
---@return boolean
local function is_orch_buffer(bufnr)
    local name = vim.api.nvim_buf_get_name(bufnr)
    if name == "" then
        return false
    end
    return vim.fs.normalize(name):find("/%.orch/") ~= nil
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

--- Sends a notification to a client (`client:notify` since Neovim 0.11, the
--- dot form before).
---@param client vim.lsp.Client
---@param method string
---@param params table
local function notify_client(client, method, params)
    if vim.fn.has("nvim-0.11") == 1 then
        client:notify(method, params)
    else
        client.notify(method, params)
    end
end

--- Registers the OrchLaunch schemas with a jsonls client, keeping every schema
--- the user already configured, and tells the server.
---@param client vim.lsp.Client
---@param mappings table[]
local function apply_schemas_to_client(client, mappings)
    local settings = client.config.settings
    if type(settings) ~= "table" then
        settings = {}
        client.config.settings = settings
    end
    settings.json = type(settings.json) == "table" and settings.json or {}
    settings.json.schemas = merge_schemas(settings.json.schemas or {}, mappings)

    -- Neovim >= 0.11 answers workspace/configuration pulls from `client.settings`
    -- (not always the same table as `client.config.settings`).
    if type(client.settings) == "table" and client.settings ~= settings then
        client.settings.json = type(client.settings.json) == "table" and client.settings.json or {}
        client.settings.json.schemas = merge_schemas(client.settings.json.schemas or {}, mappings)
    end

    notify_client(client, "workspace/didChangeConfiguration", { settings = settings })
end

---@param client vim.lsp.Client
---@return boolean
local function is_jsonls(client)
    local name = client.name:lower()
    return name == "jsonls" or name == "json-lsp"
end

--- Adds (or corrects) the `$schema` member of a document in a buffer with a
--- minimal text edit, so formatting, key order, undo history and folds survive.
---@param bufnr integer
---@param url string
local function ensure_schema_ref(bufnr, url)
    local root = jsonpos.parse_buffer(bufnr)
    if not root or root.kind ~= "object" then
        return
    end

    local member = jsonpos.member(root, "$schema")
    if member then
        local value = member.value
        if value.kind == "string" and value.value == url then
            return
        end
        if value.line == value.end_line then
            vim.api.nvim_buf_set_text(bufnr, value.line, value.col, value.end_line, value.end_col, { vim.json.encode(url) })
        end
        return
    end

    local literal = vim.json.encode("$schema") .. ": " .. vim.json.encode(url)
    if #root.members == 0 then
        vim.api.nvim_buf_set_text(bufnr, root.line, root.col, root.end_line, root.end_col, { "{ " .. literal .. " }" })
        return
    end

    -- Insert after the opening brace: on its own line, indented like the first member.
    local first = root.members[1]
    local lines = vim.api.nvim_buf_get_lines(bufnr, first.key_line, first.key_line + 1, false)
    if first.key_line > root.line then
        local indent = (lines[1] or ""):sub(1, first.key_col)
        vim.api.nvim_buf_set_text(bufnr, root.line, root.col + 1, root.line, root.col + 1, { "", indent .. literal .. "," })
    else
        -- one-line document: `{ "a": 1 }` -> `{ "$schema": "...", "a": 1 }`
        vim.api.nvim_buf_set_text(bufnr, first.key_line, first.key_col, first.key_line, first.key_col, { literal .. ", " })
    end
end

--- Sets up automatic schema registration for jsonls.
---
--- Safe to call repeatedly: the previous registration is replaced, so changing
--- `jsonls` / `write_schema_ref` between calls takes effect.
---@param opts? { jsonls?: boolean, write_schema_ref?: boolean }
function M.setup(opts)
    opts = opts or {}
    local jsonls_enabled = opts.jsonls ~= false
    local write_schema_ref = opts.write_schema_ref == true

    -- Always (re)create the group first so a later setup() with the features
    -- turned off removes the old autocommands.
    local group = vim.api.nvim_create_augroup("OrchLaunchSchemas", { clear = true })

    if jsonls_enabled then
        -- When jsonls attaches to a buffer in .orch/, register our schemas
        vim.api.nvim_create_autocmd("LspAttach", {
            group = group,
            callback = function(args)
                local client = args.data and vim.lsp.get_client_by_id(args.data.client_id)
                if not client or not is_jsonls(client) then
                    return
                end
                -- Only apply to buffers in .orch directories
                if not is_orch_buffer(args.buf) then
                    return
                end
                apply_schemas_to_client(client, M.mappings())
            end,
        })

        -- jsonls was already running when an .orch buffer was opened
        vim.api.nvim_create_autocmd("FileType", {
            group = group,
            pattern = "json",
            callback = function(args)
                if not is_orch_buffer(args.buf) then
                    return
                end
                for _, client in pairs(vim.lsp.get_clients({ bufnr = args.buf })) do
                    if is_jsonls(client) then
                        apply_schemas_to_client(client, M.mappings())
                        break
                    end
                end
            end,
        })
    end

    -- Write $schema reference when saving .orch files (if enabled)
    if write_schema_ref then
        vim.api.nvim_create_autocmd("BufWritePre", {
            group = group,
            callback = function(args)
                if not is_orch_buffer(args.buf) then
                    return
                end
                local key = get_schema_key(args.buf)
                local url = key and M.github_urls()[key]
                if url then
                    ensure_schema_ref(args.buf, url)
                end
            end,
        })
    end
end

--- Returns diagnostic info for :OrchLaunchCheck
---@return table
function M.check_info()
    local info = {
        jsonls_found = false,
        jsonls_installed = vim.fn.executable("vscode-json-language-server") == 1,
        jsonls_clients = {},
        schemas_registered = false,
    }

    local ours = {}
    for _, mapping in ipairs(M.mappings()) do
        ours[mapping.url] = true
    end

    for _, client in pairs(vim.lsp.get_clients()) do
        if is_jsonls(client) then
            info.jsonls_found = true
            info.jsonls_clients[#info.jsonls_clients + 1] = {
                name = client.name,
                id = client.id,
                root_dir = client.config.root_dir,
            }

            local settings = client.config.settings
            if type(settings) == "table" and type(settings.json) == "table" then
                for _, schema in ipairs(settings.json.schemas or {}) do
                    if schema.url and ours[schema.url] then
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
