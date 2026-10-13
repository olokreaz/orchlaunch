-- End-to-end test: the nui-components UI layer.
--
-- Renders the browser, every editor form and the list dialogs, drives their
-- widgets (text inputs, selects, checkboxes, buttons) and verifies the results
-- are persisted through `state`. This is what a user actually clicks through.

local here = vim.fn.fnamemodify(debug.getinfo(1, "S").source:sub(2), ":p:h")
package.path = here .. "/?.lua;" .. package.path
local h = require("harness")

local notifications = {}
vim.notify = function(msg)
    notifications[#notifications + 1] = tostring(msg)
end

local function last_notify()
    return notifications[#notifications] or ""
end

local function noted(fragment)
    for _, msg in ipairs(notifications) do
        if msg:find(fragment, 1, true) then
            return true
        end
    end
    return false
end

--- Concatenates every visible buffer line (floating windows included).
local function screen_text()
    local lines = {}
    for _, win in ipairs(vim.api.nvim_list_wins()) do
        local buf = vim.api.nvim_win_get_buf(win)
        for _, line in ipairs(vim.api.nvim_buf_get_lines(buf, 0, -1, false)) do
            lines[#lines + 1] = line
        end
    end
    return table.concat(lines, "\n")
end

--- Presses the first focusable button whose rendered label contains `fragment`.
local function press(renderer, fragment)
    for _, component in ipairs(renderer:get_focusable_components()) do
        local props = component:get_props()
        if type(props.on_press) == "function"
            and type(props.lines) == "string"
            and props.lines:find(fragment, 1, true)
        then
            props.on_press(component)
            return true
        end
    end
    return false
end

--- Sets the value of a widget by id (no-op when missing).
local function set(renderer, id, value)
    local component = renderer:get_component_by_id(id)
    if component then
        component:set_current_value(value)
        return true
    end
    return false
end

local root = h.tempdir()
local orch = require("orchlaunch")
local state = require("orchlaunch.state")
local config = require("orchlaunch.config")
local cmake = require("orchlaunch.cmake")

orch.create_project(root)
state.add_toolchain(config.toolchain({
    name = "Gcc", type = "system", cmake = "cmake", c = "gcc", cxx = "g++", debugger = "gdb",
}))
state.add_external_tool(config.external_tool({ name = "gen", program = "${workspace}/gen" }))
state.add_configuration(config.native({
    name = "Game", target = "/bin/echo", args = { "-x" }, console = config.console({ mode = "embedded" }),
}))
state.add_configuration(config.remote_debug({
    name = "Attach", symbol = "game", connection = "localhost:1234", adapter = "gdb",
}))
state.add_configuration(config.compound({ name = "All", configurations = { "Game", "Attach" } }))
state.add_cmake_profile(config.cmake_settings({ name = "Debug", build_type = "Debug" }))
state.save()

-- Make CMake targets available to the editors without a real configure.
-- Reloading clears runtime data, so this is re-armed after every reload.
local function arm_targets()
    state.set_runtime("cmake_targets", {
        { name = "hello", type = "EXECUTABLE" },
        { name = "greet", type = "STATIC_LIBRARY" },
    })
    state.set_runtime("cmake_source_dir", cmake.source_dir())
end
arm_targets()

-- ============================================================================
-- 1. browser
-- ============================================================================
local browser = require("orchlaunch.ui.browser").open()
vim.wait(300)
h.check("browser renders", browser ~= nil)
h.check("browser list component", browser:get_component_by_id("orch_list") ~= nil)
h.check("browser details component", browser:get_component_by_id("orch_details") ~= nil)
local btext = screen_text()
h.contains("browser title", btext, "Run / Debug Configurations")
h.contains("browser lists configurations", btext, "Game")
h.contains("browser list shows type", btext, "native")
h.contains("browser Run button", btext, "Run (r)")
h.contains("browser Debug button", btext, "Debug (d)")
h.contains("browser New button", btext, "New (a)")
h.contains("browser Duplicate button", btext, "Duplicate (y)")
h.contains("browser Delete button", btext, "Delete (D)")
h.contains("browser Set Active button", btext, "Set Active (A)")
h.contains("browser Toolchains entry", btext, "Toolchains")
h.contains("browser External Tools entry", btext, "External Tools")
h.contains("browser CMake entry", btext, "CMake")
h.contains("browser Load CMake button", btext, "Load CMake (m)")
browser:close()
vim.wait(50)

-- ============================================================================
-- 2. native editor — full round trip
-- ============================================================================
local saved_native = false
local r = require("orchlaunch.ui.editor").open_native(nil, function()
    saved_native = true
end)
vim.wait(300)
h.check("native editor has name field", r:get_component_by_id("name") ~= nil)
h.check("native editor has CMake target select", r:get_component_by_id("target_choice") ~= nil)
h.check("native editor has console chooser", r:get_component_by_id("console_mode") ~= nil)

set(r, "name", "NewNative")
set(r, "target_choice", { id = "hello" })
set(r, "cwd", "${workspace}/run")
set(r, "args", "-x\n-y")
set(r, "environment", "A=1\nB=2")
set(r, "console_mode", { id = "hidden" })
set(r, "keep_open", false)
set(r, "clear_on_start", false)
set(r, "before_build", true)
set(r, "before_external", "gen")

h.check("native editor Save button pressed", press(r, "Save"), "no Save button found")
h.check("native editor on_saved fired", saved_native)

state.reload()
arm_targets()
local native = state.configuration("NewNative")
h.check("native configuration persisted", native ~= nil)
h.eq("native target taken from select", native and native.target, "hello")
h.eq("native cwd persisted", native and native.cwd, "${workspace}/run")
h.eq("native args parsed", native and native.args, { "-x", "-y" })
h.eq("native environment parsed", native and native.environment, { A = "1", B = "2" })
h.eq("native console mode persisted", native and native.console.mode, "hidden")
h.eq("native keep_open persisted", native and native.console.keep_open, false)
h.eq("native clear_on_start persisted", native and native.console.clear_on_start, false)
h.eq("native before build flag", native and native.before.tools[1], "build")
h.eq("native before external tool", native and native.before.tools[2].tool, "gen")

-- duplicate name is rejected
notifications = {}
local dup = require("orchlaunch.ui.editor").open_native(nil, nil)
vim.wait(200)
set(dup, "name", "Game")
press(dup, "Save")
h.check("native editor rejects a duplicate name", noted("already exists"), last_notify())
dup:close()
vim.wait(50)

-- ============================================================================
-- 3. remote debug editor
-- ============================================================================
local saved_remote = false
local rr = require("orchlaunch.ui.editor").open_remote(nil, function()
    saved_remote = true
end)
vim.wait(300)
h.check("remote editor has symbol select", rr:get_component_by_id("symbol_choice") ~= nil)
set(rr, "name", "Remote2")
set(rr, "symbol_choice", { id = "hello" })
set(rr, "connection", "host:9000")
set(rr, "adapter", "lldb")
h.check("remote editor Save pressed", press(rr, "Save"))
h.check("remote editor on_saved fired", saved_remote)
state.reload()
arm_targets()
local remote = state.configuration("Remote2")
h.eq("remote type", remote and remote.type, "remote-debug")
h.eq("remote symbol persisted", remote and remote.symbol, "hello")
h.eq("remote connection persisted", remote and remote.connection, "host:9000")
h.eq("remote adapter persisted", remote and remote.adapter, "lldb")

-- ============================================================================
-- 4. compound editor
-- ============================================================================
local saved_compound = false
local rc = require("orchlaunch.ui.editor").open_compound(nil, function()
    saved_compound = true
end)
vim.wait(300)
set(rc, "name", "All2")
set(rc, "configurations", "Game\nRemote2")
h.check("compound editor Save pressed", press(rc, "Save"))
h.check("compound editor on_saved fired", saved_compound)
state.reload()
arm_targets()
local compound = state.configuration("All2")
h.eq("compound type", compound and compound.type, "compound")
h.eq("compound children persisted", compound and compound.configurations, { "Game", "Remote2" })

-- ============================================================================
-- 5. toolchain editor
-- ============================================================================
local saved_tc = false
local rt = require("orchlaunch.ui.editor").open_toolchain(nil, function()
    saved_tc = true
end)
vim.wait(300)
h.check("toolchain editor has type chooser", rt:get_component_by_id("type") ~= nil)
set(rt, "name", "Clang")
set(rt, "type", { id = "system" })
set(rt, "cmake", "cmake")
set(rt, "c", "clang")
set(rt, "cxx", "clang++")
set(rt, "debugger", "lldb")
h.check("toolchain editor Save pressed", press(rt, "Save"))
h.check("toolchain editor on_saved fired", saved_tc)
state.reload()
arm_targets()
local tc = state.toolchain("Clang")
h.check("toolchain persisted", tc ~= nil)
h.eq("toolchain cxx", tc and tc.cxx, "clang++")
h.eq("toolchain type", tc and tc.type, "system")

-- ============================================================================
-- 6. external tool editor
-- ============================================================================
local saved_ext = false
local rext = require("orchlaunch.ui.editor").open_external_tool(nil, function()
    saved_ext = true
end)
vim.wait(300)
set(rext, "name", "gen2")
set(rext, "program", "${workspace}/tools/gen")
set(rext, "args", "--release\n--verbose")
set(rext, "cwd", "${workspace}")
h.check("external editor Save pressed", press(rext, "Save"))
h.check("external editor on_saved fired", saved_ext)
state.reload()
arm_targets()
local ext = state.external_tool("gen2")
h.check("external tool persisted", ext ~= nil)
h.eq("external tool program", ext and ext.program, "${workspace}/tools/gen")
h.eq("external tool args", ext and ext.args, { "--release", "--verbose" })

-- ============================================================================
-- 7. toolchains list dialog
-- ============================================================================
local tl = require("orchlaunch.ui.list_dialog").open_toolchains()
vim.wait(300)
local tl_text = screen_text()
h.check("toolchains dialog list", tl:get_component_by_id("orch_list") ~= nil)
h.contains("toolchains dialog title", tl_text, "Toolchains")
h.contains("toolchains dialog lists items", tl_text, "Gcc")
h.contains("toolchains dialog New button", tl_text, "New chain (a)")
h.contains("toolchains dialog details", tl_text, "Debugger")
tl:close()
vim.wait(50)

-- ============================================================================
-- 8. CMake profiles dialog
-- ============================================================================
local cp = require("orchlaunch.ui.list_dialog").open_cmake_profiles()
vim.wait(300)
local cp_text = screen_text()
h.check("cmake profiles dialog list", cp:get_component_by_id("orch_list") ~= nil)
h.contains("cmake profiles dialog title", cp_text, "CMake Profiles")
h.contains("cmake profiles active marker", cp_text, "●")
h.contains("cmake profiles Set Active button", cp_text, "Set Active")
h.contains("cmake profiles Import button", cp_text, "Import presets")
h.contains("cmake profiles Toggle button", cp_text, "Toggle")
h.contains("cmake profiles Project button", cp_text, "Project")
cp:close()
vim.wait(50)

-- ============================================================================
-- 9. shared UI helpers
-- ============================================================================
local UI = require("orchlaunch.ui")
h.eq("UI.lines", UI.lines("a\n\n b \n"), { "a", "b" })
h.eq("UI.parse_env", UI.parse_env("A=1\nBAD\nB=2"), { A = "1", B = "2" })
h.eq("UI.format_env", UI.format_env({ B = "2", A = "1" }), "A=1\nB=2")
h.eq("UI.format_lines", UI.format_lines({ "x", "y" }), "x\ny")

h.done("UI end-to-end")
