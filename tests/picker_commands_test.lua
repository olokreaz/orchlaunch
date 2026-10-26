-- Commands built on the pickers must actually do something:
--   :OrchLaunchRunHere, :OrchLaunchSelectProfile, :OrchLaunchSelectPreset,
--   :OrchLaunchSelectTool, :OrchLaunchToolchains, :OrchLaunchExternalTools,
--   :OrchLaunchCMake.
-- Regression: in "buffer" mode they only printed "Selected ..." and
-- :OrchLaunchRunHere used a brace counter that never matched a configuration.

local here = vim.fn.fnamemodify(debug.getinfo(1, "S").source:sub(2), ":p:h")
package.path = here .. "/?.lua;" .. package.path
local h = require("harness")
h.require_tool("sh")

local messages = {}
vim.notify = function(msg, level)
    messages[#messages + 1] = { text = tostring(msg), level = level }
end
local function saw(fragment, level)
    for _, m in ipairs(messages) do
        if m.text:find(fragment, 1, true) and (level == nil or m.level == level) then
            return true
        end
    end
    return false
end

local choose
local calls = {}
vim.ui.select = function(items, opts, cb)
    calls[#calls + 1] = { items = items, prompt = opts.prompt, format_item = opts.format_item }
    local index = choose and choose(items)
    cb(index and items[index] or nil, index)
end
local function reset()
    messages, calls, choose = {}, {}, nil
    vim.cmd("silent! %bwipeout!")
    vim.cmd("silent! only")
end

local orch = require("orchlaunch")
local state = require("orchlaunch.state")
local config = require("orchlaunch.config")
local root = h.tempdir()
orch.setup({ root = root, silent = true })
orch.create_project(root)

local function wait_for_file(path, ms)
    vim.wait(ms or 5000, function()
        return vim.fn.filereadable(path) == 1
    end, 20)
    return vim.fn.filereadable(path) == 1
end

-- ---- :OrchLaunchRunHere ------------------------------------------------------------
local function marker_config(name, marker, compact)
    return {
        name = name,
        type = "native",
        target = "/bin/sh",
        args = { "-c", "echo ran > " .. marker },
        console = { mode = "none" },
    }, compact
end
local m_one, m_two, m_three = root .. "/one.mark", root .. "/two.mark", root .. "/three.mark"
local doc = table.concat({
    "{",
    '  "configurations": [',
    "    {",
    '      "name": "One {braces} }",',
    '      "type": "native",',
    '      "target": "/bin/sh",',
    '      "args": ["-c", "echo ran > ' .. m_one .. '"],',
    '      "console": { "mode": "none" }',
    "    },",
    '    { "name": "Two", "type": "native", "target": "/bin/sh", "args": ["-c", "echo ran > ' .. m_two .. '"], "console": { "mode": "none" } },',
    '    { "name": "Three", "type": "native", "target": "/bin/sh", "args": ["-c", "echo ran > ' .. m_three .. '"], "console": { "mode": "none" } }',
    "  ]",
    "}",
}, "\n")
local runs_path = root .. "/.orch/run_configurations.json"
h.write(runs_path, doc)
vim.cmd("OrchLaunchReload")
local _ = marker_config

local function cursor_on(text)
    for i, l in ipairs(vim.api.nvim_buf_get_lines(0, 0, -1, false)) do
        if l:find(text, 1, true) then
            vim.api.nvim_win_set_cursor(0, { i, 4 })
            return
        end
    end
    error("text not found: " .. text)
end

reset()
vim.cmd("edit " .. vim.fn.fnameescape(runs_path))
cursor_on('"type": "native"') -- inside the first (multi-line) configuration
h.ok(":OrchLaunchRunHere does not raise", function()
    vim.cmd("OrchLaunchRunHere")
end)
h.check("the configuration under the cursor ran", wait_for_file(m_one), vim.inspect(messages))
vim.wait(300)
h.eq("others did not run (two)", vim.fn.filereadable(m_two), 0)
h.eq("others did not run (three)", vim.fn.filereadable(m_three), 0)

reset()
vim.cmd("edit " .. vim.fn.fnameescape(runs_path))
cursor_on('"name": "Two"') -- a one-line configuration
vim.cmd("OrchLaunchRunHere")
h.check("a one-line configuration runs", wait_for_file(m_two), vim.inspect(messages))
vim.wait(300)
h.eq("neighbouring one-line configuration did not run", vim.fn.filereadable(m_three), 0)

reset()
vim.cmd("edit " .. vim.fn.fnameescape(runs_path))
vim.api.nvim_win_set_cursor(0, { 1, 0 }) -- the opening brace, outside any configuration
vim.cmd("OrchLaunchRunHere")
h.check("a cursor outside configurations warns", saw("not inside a configuration", vim.log.levels.WARN), vim.inspect(messages))

reset()
h.write(root .. "/notes.json", "{}")
vim.cmd("edit " .. vim.fn.fnameescape(root .. "/notes.json"))
vim.cmd("OrchLaunchRunHere")
h.check("other files are refused", saw("only works in run_configurations.json", vim.log.levels.WARN), vim.inspect(messages))

reset()
vim.cmd("edit " .. vim.fn.fnameescape(runs_path))
vim.api.nvim_buf_set_lines(0, 0, -1, false, { "{ broken" })
vim.cmd("OrchLaunchRunHere")
h.check("invalid JSON is reported", saw("not valid JSON", vim.log.levels.ERROR), vim.inspect(messages))
vim.cmd("edit! " .. vim.fn.fnameescape(runs_path))

-- ---- :OrchLaunchSelectProfile ----------------------------------------------------------
state.add_toolchain(config.toolchain({ name = "gcc", type = "system", cmake = "cmake", c = "gcc", cxx = "g++", debugger = "gdb" }))
state.add_cmake_profile(config.cmake_settings({ name = "Debug", toolchain = "gcc" }))
state.add_cmake_profile(config.cmake_settings({ name = "Release", toolchain = "gcc" }))
state.set_active_cmake_profile("Debug")
state.save()

reset()
choose = function(items)
    for i, item in ipairs(items) do
        if item.name == "Release" then
            return i
        end
    end
end
vim.cmd("OrchLaunchSelectProfile")
h.eq("selecting a profile activates it", state.active_cmake_profile(), "Release")
h.check("activation is announced", saw("active CMake profile: Release"), vim.inspect(messages))
vim.cmd("OrchLaunchReload")
h.eq("the active profile is persisted", state.active_cmake_profile(), "Release")

-- ---- :OrchLaunchSelectPreset ---------------------------------------------------------------
h.write(root .. "/CMakePresets.json", [[{
  "version": 3,
  "configurePresets": [ { "name": "dev", "generator": "Ninja", "binaryDir": "${sourceDir}/build" },
                        { "name": "lonely", "generator": "Ninja", "binaryDir": "${sourceDir}/build2" } ]
}]])
state.add_cmake_profile(config.cmake_settings({ name = "Dev profile", toolchain = "gcc", configure_preset = "dev" }))
state.save()
vim.cmd("OrchLaunchReload")

reset()
choose = function(items)
    for i, item in ipairs(items) do
        if item.name == "dev" then
            return i
        end
    end
end
vim.cmd("OrchLaunchSelectPreset configure")
h.eq("selecting a preset activates the profile wrapping it", state.active_cmake_profile(), "Dev profile")

reset()
choose = function(items)
    for i, item in ipairs(items) do
        if item.name == "lonely" then
            return i
        end
    end
end
vim.cmd("OrchLaunchSelectPreset configure")
h.check("a preset without a profile says what to do", saw("no profile uses the configure preset", vim.log.levels.WARN), vim.inspect(messages))
h.eq("the active profile is unchanged", state.active_cmake_profile(), "Dev profile")

-- ---- :OrchLaunchSelectTool ------------------------------------------------------------------
local tool_mark = root .. "/tool.mark"
state.add_external_tool(config.external_tool({ name = "mark", program = "/bin/sh", args = { "-c", "echo ran > " .. tool_mark } }))
state.save()
reset()
choose = function(items)
    for i, item in ipairs(items) do
        if item.name == "mark" then
            return i
        end
    end
end
vim.cmd("OrchLaunchSelectTool")
h.check("selecting a tool runs it", wait_for_file(tool_mark), vim.inspect(messages))

-- ---- editors: toolchains, tools, profiles jump to the entry ----------------------------------
local function line_text()
    return vim.api.nvim_get_current_line()
end
for _, case in ipairs({
    { command = "OrchLaunchToolchains", pick = "gcc", file = "toolchain.json", needle = '"name": "gcc"' },
    { command = "OrchLaunchExternalTools", pick = "mark", file = "external_tools.json", needle = '"name": "mark"' },
    { command = "OrchLaunchCMake", pick = "Release", file = "cmake_settings.json", needle = '"name": "Release"' },
}) do
    reset()
    choose = function(items)
        for i, item in ipairs(items) do
            if item.name == case.pick then
                return i
            end
        end
    end
    vim.cmd(case.command)
    h.eq(case.command .. " opens " .. case.file, vim.fs.basename(vim.api.nvim_buf_get_name(0)), case.file)
    h.check(case.command .. " puts the cursor on the entry", line_text():find(case.needle, 1, true) ~= nil, line_text())
end

h.done("picker commands")
