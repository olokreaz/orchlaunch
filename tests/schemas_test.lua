-- JSON Schema integration: mappings, registration with jsonls (a scripted fake
-- server, plus the real vscode-json-language-server when installed), the
-- $schema writer and :OrchLaunchCheck information.

local here = vim.fn.fnamemodify(debug.getinfo(1, "S").source:sub(2), ":p:h")
package.path = here .. "/?.lua;" .. package.path
local h = require("harness")

local messages = {}
vim.notify = function(msg)
    messages[#messages + 1] = tostring(msg)
end

local orch = require("orchlaunch")
local schemas = require("orchlaunch.schemas")
local config = require("orchlaunch.config")
local root = h.tempdir()
orch.setup({ root = root, silent = true })
orch.create_project(root)

-- ---- mappings ----------------------------------------------------------------
local mappings = schemas.mappings()
h.eq("four schema mappings", #mappings, 4)
for _, mapping in ipairs(mappings) do
    local path = vim.uri_to_fname(mapping.url)
    h.check(("%s points at an existing schema file"):format(mapping.fileMatch[1]), vim.fn.filereadable(path) == 1, mapping.url)
    h.check("fileMatch is limited to .orch files", mapping.fileMatch[1]:find("/.orch/", 1, true) ~= nil)
    h.check("url is a file:// url", mapping.url:sub(1, 8) == "file:///", mapping.url)
end
h.eq("github urls cover the four files", vim.tbl_count(schemas.github_urls()), 4)

-- special characters in the plugin path are percent-encoded
h.eq("uri round trip with spaces and symbols",
    vim.uri_to_fname(vim.uri_from_fname("/tmp/my plugins/50%/a#b/orchlaunch")),
    "/tmp/my plugins/50%/a#b/orchlaunch")
h.check("urls never contain raw spaces", not mappings[1].url:find(" ", 1, true))

--- Stops every running client (client:stop() since Neovim 0.11).
local function stop_all()
    for _, c in ipairs(vim.lsp.get_clients()) do
        if vim.fn.has("nvim-0.11") == 1 then
            c:stop()
        else
            vim.lsp.stop_client(c.id)
        end
    end
    vim.wait(300)
end

-- ---- fake jsonls ---------------------------------------------------------------
--- Starts a scripted language server that records what it receives.
local function fake_server(name, settings, bufnr)
    local received = {}
    local closing = false
    local function cmd()
        local srv = {}
        function srv.request(method, _, callback)
            if method == "initialize" then
                callback(nil, { capabilities = {} })
            elseif method == "shutdown" then
                callback(nil, nil)
            end
            return true, 1
        end
        function srv.notify(method, params)
            received[#received + 1] = { method = method, params = params }
            return true
        end
        function srv.is_closing()
            return closing
        end
        function srv.terminate()
            closing = true
        end
        return srv
    end
    local id = vim.lsp.start({ name = name, cmd = cmd, root_dir = root, settings = settings }, { bufnr = bufnr })
    return id, received
end

local function config_notifications(received)
    local out = {}
    for _, item in ipairs(received) do
        if item.method == "workspace/didChangeConfiguration" then
            out[#out + 1] = item.params
        end
    end
    return out
end

local function open_orch_buffer(name)
    local path = root .. "/.orch/" .. name
    vim.cmd("edit " .. vim.fn.fnameescape(path))
    vim.bo.filetype = "json"
    return vim.api.nvim_get_current_buf()
end

local user_schema = { fileMatch = { "*.mine.json" }, url = "file:///user/own.schema.json" }

-- jsonls attaching to an .orch buffer: our schemas are added, the user's kept
vim.cmd("silent! %bwipeout!")
local buf = open_orch_buffer("run_configurations.json")
local id, received = fake_server("jsonls", { json = { schemas = { user_schema } } }, buf)
h.check("fake jsonls started", id ~= nil)
vim.wait(1000, function()
    return #config_notifications(received) > 0
end, 20)
local notes = config_notifications(received)
h.check("jsonls gets a didChangeConfiguration notification", #notes >= 1)
local sent = notes[#notes] and notes[#notes].settings.json.schemas or {}
local urls = {}
for _, entry in ipairs(sent) do
    urls[#urls + 1] = entry.url
end
h.eq("user schema + four of ours", #sent, 5)
h.check("the user's own schema is kept", vim.tbl_contains(urls, user_schema.url), vim.inspect(urls))
for _, mapping in ipairs(mappings) do
    h.check("registered: " .. mapping.fileMatch[1], vim.tbl_contains(urls, mapping.url))
end
h.eq("the user's schema stays first", sent[1] and sent[1].url, user_schema.url)

-- attaching another .orch buffer must not duplicate anything
local buf2 = open_orch_buffer("toolchain.json")
vim.lsp.buf_attach_client(buf2, id)
vim.wait(300)
local last = config_notifications(received)
local final = last[#last].settings.json.schemas
h.eq("no duplicates after a second attach", #final, 5)

-- check_info reflects reality
local info = schemas.check_info()
h.eq("check_info finds jsonls", info.jsonls_found, true)
h.eq("check_info sees our schemas registered", info.schemas_registered, true)
h.eq("check_info client count", #info.jsonls_clients, 1)
stop_all()

-- other servers and non-.orch buffers are left alone
vim.cmd("silent! %bwipeout!")
local lua_buf = open_orch_buffer("run_configurations.json")
local _, other = fake_server("lua_ls", {}, lua_buf)
vim.wait(300)
h.eq("a non-json server gets nothing", #config_notifications(other), 0)

vim.cmd("silent! %bwipeout!")
local elsewhere = root .. "/package.json"
h.write(elsewhere, "{}")
vim.cmd("edit " .. vim.fn.fnameescape(elsewhere))
vim.bo.filetype = "json"
local _, foreign = fake_server("jsonls", {}, vim.api.nvim_get_current_buf())
vim.wait(300)
h.eq("a buffer outside .orch gets nothing", #config_notifications(foreign), 0)
stop_all()

-- jsonls = false switches the registration off, even after it was on
orch.setup({ root = root, silent = true, jsonls = false })
vim.cmd("silent! %bwipeout!")
local off_buf = open_orch_buffer("run_configurations.json")
local _, disabled = fake_server("jsonls", {}, off_buf)
vim.wait(300)
h.eq("jsonls = false: nothing is registered", #config_notifications(disabled), 0)
stop_all()
orch.setup({ root = root, silent = true })

-- ---- write_schema_ref -----------------------------------------------------------
orch.setup({ root = root, silent = true, write_schema_ref = true })
local url = schemas.github_urls().toolchain

local function write_buffer(lines)
    vim.cmd("silent! %bwipeout!")
    local path = root .. "/.orch/toolchain.json"
    h.write(path, "{}\n")
    vim.cmd("edit! " .. vim.fn.fnameescape(path))
    vim.api.nvim_buf_set_lines(0, 0, -1, false, lines)
    vim.cmd("silent write")
    return h.read(path)
end

local out = write_buffer({ "{", '  "toolchains": []', "}" })
h.eq("$schema is inserted as the first member", out, '{\n  "$schema": "' .. url .. '",\n  "toolchains": []\n}\n')
h.check("the written file is valid JSON", pcall(vim.json.decode, out))
h.check("empty list is still []", out:find('"toolchains": []', 1, true) ~= nil)

out = write_buffer({ "{}" })
h.eq("an empty object gets the reference", out, '{ "$schema": "' .. url .. '" }\n')

out = write_buffer({ '{ "toolchains": [] }' })
h.eq("a one-line document keeps its layout", out, '{ "$schema": "' .. url .. '", "toolchains": [] }\n')

out = write_buffer({ "{", '  "$schema": "https://example.com/old.json",', '  "toolchains": []', "}" })
h.eq("a wrong $schema is corrected in place", out, '{\n  "$schema": "' .. url .. '",\n  "toolchains": []\n}\n')

local already = { "{", '  "$schema": "' .. url .. '",', '  "toolchains": []', "}" }
out = write_buffer(already)
h.eq("a correct $schema is left alone", out, table.concat(already, "\n") .. "\n")

out = write_buffer({ "{", '  "toolchains": [', "    {broken" })
h.check("an invalid document is left untouched", not out:find("$schema", 1, true), out)

-- a toolchain.json that merely lives in the project is not ours
vim.cmd("silent! %bwipeout!")
local foreign_file = root .. "/toolchain.json"
h.write(foreign_file, "{}\n")
vim.cmd("edit! " .. vim.fn.fnameescape(foreign_file))
vim.api.nvim_buf_set_lines(0, 0, -1, false, { '{ "mine": true }' })
vim.cmd("silent write")
h.check("a same-named file outside .orch is not modified", not h.read(foreign_file):find("$schema", 1, true), h.read(foreign_file))

-- files written by the plugin itself carry the reference too
local saved = root .. "/.orch/external_tools.json"
config.save(saved, { tools = {} })
local text = h.read(saved)
h.check("config.save adds $schema when enabled", text:find(schemas.github_urls().external_tools, 1, true) ~= nil, text)
h.check("config.save keeps empty lists as []", text:find('"tools": []', 1, true) ~= nil, text)
config.save(root .. "/other.json", { tools = {} })
h.check("unrelated files are not touched", not h.read(root .. "/other.json"):find("$schema", 1, true))

orch.setup({ root = root, silent = true })
config.save(saved, { tools = {} })
h.check("option off: no $schema is written", not h.read(saved):find("$schema", 1, true))

-- ---- :OrchLaunchCheck messages ---------------------------------------------------
messages = {}
vim.cmd("silent! %bwipeout!")
stop_all()
vim.cmd("OrchLaunchCheck")
local joined = table.concat(messages, "\n")
h.check("OrchLaunchCheck mentions jsonls", joined:find("jsonls:", 1, true) ~= nil, joined)

-- ---- the real vscode-json-language-server --------------------------------------
if vim.fn.executable("vscode-json-language-server") == 1 then
    local project = h.tempdir()
    orch.setup({ root = project, silent = true })
    orch.create_project(project)

    vim.ui.input = function(_, cb)
        cb(table.remove(h.inputs, 1))
    end
    vim.ui.select = function(items, _, cb)
        cb(items[1], 1)
    end
    h.inputs = {}
    for _, case in ipairs({
        { "native", { "N1" } },
        { "remote-debug", { "R1", "localhost:1234" } },
        { "external_tool", { "T1", "clang-format" } },
        { "toolchain", { "TC1" } },
        { "cmake_profile", { "P1" } },
    }) do
        h.inputs = vim.deepcopy(case[2])
        vim.cmd("silent! %bwipeout!")
        vim.cmd("OrchLaunchNew " .. case[1])
    end

    -- positive control: a wrong document must be flagged, proving the schema applied
    local bad = project .. "/.orch/run_configurations.json"
    local good_text = h.read(bad)
    h.write(bad, '{ "configurations": {} }\n')
    vim.cmd("silent! %bwipeout!")
    vim.cmd("edit! " .. vim.fn.fnameescape(bad))
    vim.bo.filetype = "json"
    local jbuf = vim.api.nvim_get_current_buf()
    local client_id = vim.lsp.start({
        name = "jsonls",
        cmd = { "vscode-json-language-server", "--stdio" },
        root_dir = project,
        settings = { json = { validate = { enable = true } } },
    }, { bufnr = jbuf })
    h.check("real jsonls started", client_id ~= nil)

    vim.wait(15000, function()
        return #vim.diagnostic.get(jbuf) > 0
    end, 50)
    local diagnostics = vim.diagnostic.get(jbuf)
    h.check("jsonls flags a document that violates the schema", #diagnostics > 0, vim.inspect(diagnostics))
    local flagged = diagnostics[1] and diagnostics[1].message or ""
    h.check("the diagnostic is about the wrong type", flagged:lower():find("array", 1, true) ~= nil, flagged)
    local registered = schemas.check_info()
    h.eq("check_info sees the schemas on the real client", registered.schemas_registered, true)

    -- files the plugin wrote must raise no schema diagnostics at all
    h.write(bad, good_text)
    local names = { "run_configurations.json", "external_tools.json", "toolchain.json", "cmake_settings.json" }
    for _, name in ipairs(names) do
        vim.cmd("silent! %bwipeout!")
        local path = project .. "/.orch/" .. name
        vim.cmd("edit! " .. vim.fn.fnameescape(path))
        vim.bo.filetype = "json"
        local b = vim.api.nvim_get_current_buf()
        vim.lsp.buf_attach_client(b, client_id)
        vim.wait(2500)
        local found = vim.diagnostic.get(b)
        local texts = {}
        for _, d in ipairs(found) do
            texts[#texts + 1] = d.message
        end
        h.eq(("jsonls accepts %s written by the plugin"):format(name), #found, 0)
        if #found > 0 then
            print("      " .. table.concat(texts, " | "))
        end
    end
    stop_all()
else
    print("NOTE  vscode-json-language-server not installed: skipping the real jsonls checks")
end

h.done("JSON Schema / jsonls integration")
