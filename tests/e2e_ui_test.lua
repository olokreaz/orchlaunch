-- End-to-end test: the fibrous UI.
--
-- Opens the browser, every editor form and the list dialogs, drives them through
-- the fibrous handles and verifies the results are persisted through `state`.
-- This is what a user actually clicks through.

local here = vim.fn.fnamemodify(debug.getinfo(1, "S").source:sub(2), ":p:h")
package.path = here .. "/?.lua;" .. package.path
local h = require("harness")

vim.o.columns = 140
vim.o.lines = 44

if not (pcall(require, "fibrous")) then
    print("SKIP  fibrous is not installed")
    h.done("fibrous UI end-to-end (skipped)")
    return
end

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

local function screen(handle)
    return table.concat(vim.api.nvim_buf_get_lines(handle.bufnr, 0, -1, false), "\n")
end

local root = h.tempdir()
local orch = require("orchlaunch")
local state = require("orchlaunch.state")
local config = require("orchlaunch.config")

local function arm_targets()
    local cmake = require("orchlaunch.cmake")
    state.set_runtime("cmake_source_dir", cmake.source_dir())
    state.set_runtime("cmake_binary_dir", cmake.binary_dir())
    state.set_runtime("cmake_targets", {
        { name = "hello", type = "EXECUTABLE", artifact = "build/hello" },
        { name = "greet", type = "STATIC_LIBRARY", artifact = "build/libgreet.a" },
    })
end


orch.create_project(root)
state.add_toolchain(config.toolchain({
    name = "Gcc",
    type = "system",
    cmake = "cmake",
    c = "gcc",
    cxx = "g++",
    debugger = "gdb",
}))
state.add_external_tool(config.external_tool({ name = "gen", program = "${workspace}/gen" }))
state.add_configuration(config.native({ name = "Game", target = "hello" }))
state.add_configuration(config.remote_debug({
    name = "Attach",
    symbol = "hello",
    connection = "localhost:1234",
    adapter = "gdb",
}))
state.add_configuration(config.compound({ name = "All", configurations = { "Game", "Attach" } }))
state.add_cmake_profile(config.cmake_settings({ name = "Debug", build_type = "Debug" }))
state.set_active_cmake_profile("Debug")
state.save()
arm_targets()

-- ============================================================================
-- 1. browser
-- ============================================================================
local browser = require("orchlaunch.ui.fibrous.browser").open()
vim.wait(200)
h.check("browser renders", browser ~= nil and vim.api.nvim_win_is_valid(browser.winid))
local btext = screen(browser)
h.contains("browser title", btext, "Run / Debug Configurations")
h.contains("browser lists Game", btext, "Game")
h.contains("browser lists Attach", btext, "Attach")
h.contains("browser lists All", btext, "All")
h.contains("browser New config action", btext, "New config")
h.contains("browser Edit action", btext, "Edit")
h.contains("browser Delete action", btext, "Delete")
h.contains("browser Set Active action", btext, "Set Active")
h.contains("browser Load CMake action", btext, "Load CMake")
h.contains("browser Run hint", btext, "Run")
h.contains("browser Debug hint", btext, "Debug")
browser.unmount()

-- ============================================================================
-- 2. native editor — full round trip
-- ============================================================================
local saved_native = false
local r = require("orchlaunch.ui.fibrous.editors.native").open(nil, function()
    saved_native = true
end)
vim.wait(200)
h.check("native editor has name field", r.orch.values.name == "")
h.eq("native runtime defaults to executable", r.orch.values.runtime, "executable")
r.orch.set("name", "NewNative")
r.orch.set("runtime", "static")
r.orch.set("target_choice", "hello")
r.orch.set("cwd", "${workspace}/run")
r.orch.set("args", "-x\n-y")
r.orch.set("environment", "A=1\nB=2")
r.orch.set("console_mode", "hidden")
r.orch.set("keep_open", false)
r.orch.set("clear_on_start", false)
r.orch.set("before_build", true)
r.orch.set("before_build_target", "hello")
r.orch.set("before_external", "gen")
vim.wait(50)
r.orch.save()
vim.wait(100)

h.check("native editor on_saved fired", saved_native)
state.reload()
arm_targets()
local native = state.configuration("NewNative")
h.check("native configuration persisted", native ~= nil)
h.eq("native runtime persisted", native and native.runtime, "static")
h.eq("native target taken from select", native and native.target, "hello")
h.eq("native cwd persisted", native and native.cwd, "${workspace}/run")
h.eq("native args parsed", native and native.args, { "-x", "-y" })
h.eq("native environment parsed", native and native.environment, { A = "1", B = "2" })
h.eq("native console mode persisted", native and native.console.mode, "hidden")
h.eq("native keep_open persisted", native and native.console.keep_open, false)
h.eq("native clear_on_start persisted", native and native.console.clear_on_start, false)
h.eq("native before build target", (function()
    local step = native and native.before and native.before.tools[1]
    return type(step) == "table" and step.type .. ":" .. step.target
end)(), "build:hello")
h.eq("native before external tool", native and native.before.tools[2].tool, "gen")

-- duplicate name is rejected and the editor stays open
notifications = {}
local dup = require("orchlaunch.ui.fibrous.editors.native").open(nil, nil)
vim.wait(150)
dup.orch.set("name", "Game")
dup.orch.save()
vim.wait(50)
h.check("native editor rejects a duplicate name", noted("already exists"), last_notify())
h.check("duplicate editor stays open", vim.api.nvim_win_is_valid(dup.winid))
dup.orch.close()

-- ============================================================================
-- 3. remote debug editor
-- ============================================================================
local saved_remote = false
local rr = require("orchlaunch.ui.fibrous.editors.remote").open(nil, function()
    saved_remote = true
end)
vim.wait(150)
rr.orch.set("name", "Remote2")
rr.orch.set("symbol_choice", "hello")
rr.orch.set("connection", "host:9000")
rr.orch.set("adapter", "lldb")
rr.orch.save()
vim.wait(100)
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
local rc = require("orchlaunch.ui.fibrous.editors.compound").open(nil, function()
    saved_compound = true
end)
vim.wait(150)
rc.orch.set("name", "All2")
rc.orch.set("configurations", "Game\nRemote2")
rc.orch.save()
vim.wait(100)
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
local rt = require("orchlaunch.ui.fibrous.editors.toolchain").open(nil, function()
    saved_tc = true
end)
vim.wait(150)
rt.orch.set("name", "Clang")
rt.orch.set("type", "system")
rt.orch.set("cmake", "cmake")
rt.orch.set("c", "clang")
rt.orch.set("cxx", "clang++")
rt.orch.set("debugger", "lldb")
rt.orch.set("environment", "ORCH_TOOLCHAIN_ENV=yes")
rt.orch.save()
vim.wait(100)
h.check("toolchain editor on_saved fired", saved_tc)
state.reload()
arm_targets()
local tc = state.toolchain("Clang")
h.check("toolchain persisted", tc ~= nil)
h.eq("toolchain cxx", tc and tc.cxx, "clang++")
h.eq("toolchain type", tc and tc.type, "system")
h.eq("toolchain environment", tc and tc.environment, { ORCH_TOOLCHAIN_ENV = "yes" })

-- ============================================================================
-- 6. external tool editor
-- ============================================================================
local saved_ext = false
local rext = require("orchlaunch.ui.fibrous.editors.external_tool").open(nil, function()
    saved_ext = true
end)
vim.wait(150)
rext.orch.set("name", "gen2")
rext.orch.set("program", "${workspace}/tools/gen")
rext.orch.set("args", "--release\n--verbose")
rext.orch.set("cwd", "${workspace}")
rext.orch.save()
vim.wait(100)
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
local tl = require("orchlaunch.ui.dialogs.toolchains").open()
vim.wait(200)
local tl_text = screen(tl)
h.contains("toolchains dialog title", tl_text, "Toolchains")
h.contains("toolchains dialog lists items", tl_text, "Gcc")
h.contains("toolchains dialog details", tl_text, "Debugger")
tl.unmount()

-- ============================================================================
-- 8. external tools dialog
-- ============================================================================
local te = require("orchlaunch.ui.dialogs.external_tools").open()
vim.wait(200)
local te_text = screen(te)
h.contains("external tools dialog title", te_text, "External Tools")
h.contains("external tools dialog lists items", te_text, "gen")
te.unmount()

-- ============================================================================
-- 9. CMake profiles dialog
-- ============================================================================
local cp = require("orchlaunch.ui.fibrous.cmake_profiles").open()
vim.wait(200)
local cp_text = screen(cp)
h.contains("cmake profiles dialog title", cp_text, "CMake Profiles")
h.contains("cmake profiles active marker", cp_text, "●")
h.contains("cmake profiles list", cp_text, "Debug")
cp.unmount()

-- ============================================================================
-- 9b. focus returns to the parent dialog after closing an editor
-- ============================================================================
local tl = require("orchlaunch.ui.dialogs.toolchains").open()
vim.wait(150)
h.check("toolchains list opens", tl ~= nil and vim.api.nvim_win_is_valid(tl.winid))
local list_win = tl.winid
local toolchain = state.toolchains().toolchains[1]
local form = require("orchlaunch.ui.fibrous.editors.toolchain").open(toolchain, function() end)
vim.wait(100)
h.eq("toolchain editor is focused", vim.api.nvim_get_current_win(), form.winid)
vim.api.nvim_feedkeys("q", "x", false)
vim.wait(100)
h.eq("focus returns to the toolchains list", vim.api.nvim_get_current_win(), list_win)
h.check("toolchains list survives editor close", vim.api.nvim_win_is_valid(list_win))
tl.unmount()
vim.wait(50)

-- ============================================================================
-- 9c. CMake targets browser
-- ============================================================================
local targets = require("orchlaunch.ui.fibrous.targets").open()
vim.wait(200)
local targets_text = screen(targets)
h.contains("targets dialog title", targets_text, "CMake Targets")
h.contains("targets dialog lists executable", targets_text, "hello")
h.contains("targets dialog lists library", targets_text, "greet")
h.contains("targets dialog build hint", targets_text, "Build")
h.contains("targets dialog run hint", targets_text, "Run")
h.contains("targets dialog debug hint", targets_text, "Debug")
h.contains("targets dialog config hint", targets_text, "Edit config")
h.contains("targets dialog shows artifact", targets_text, "build/hello")

local targets_win = targets.winid
vim.api.nvim_feedkeys("e", "x", false)
vim.wait(150)
local target_cfg = state.configuration("hello")
h.check("target edit creates its configuration", target_cfg ~= nil)
h.eq("target configuration builds its target", (function()
    local step = target_cfg and target_cfg.before and target_cfg.before.tools[1]
    return type(step) == "table" and step.target
end)(), "hello")
h.check("target edit opens the native editor", vim.api.nvim_get_current_win() ~= targets_win)
vim.api.nvim_feedkeys("q", "x", false)
vim.wait(100)
h.eq("focus returns to targets", vim.api.nvim_get_current_win(), targets_win)
targets.unmount()

-- ============================================================================
-- 10. shared UI helpers
-- ============================================================================
local UI = require("orchlaunch.ui")
h.eq("UI.lines", UI.lines("a\n\n b \n"), { "a", "b" })
h.eq("UI.parse_env", UI.parse_env("A=1\nBAD\nB=2"), { A = "1", B = "2" })
h.eq("UI.format_env", UI.format_env({ B = "2", A = "1" }), "A=1\nB=2")
h.eq("UI.format_lines", UI.format_lines({ "x", "y" }), "x\ny")

h.done("fibrous UI end-to-end")
