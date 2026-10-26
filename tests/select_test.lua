-- vim.ui.select based pickers (lua/orchlaunch/select.lua), driven by a
-- scripted vim.ui.select.

local here = vim.fn.fnamemodify(debug.getinfo(1, "S").source:sub(2), ":p:h")
package.path = here .. "/?.lua;" .. package.path
local h = require("harness")

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

local calls = {}
local choose -- function(items) -> index | nil
vim.ui.select = function(items, opts, cb)
    calls[#calls + 1] = { items = items, prompt = opts.prompt, format_item = opts.format_item }
    local index = choose and choose(items) or nil
    cb(index and items[index] or nil, index)
end
local function reset()
    calls, messages, choose = {}, {}, nil
end
local function label(call, i)
    return call.format_item(call.items[i])
end

local select = require("orchlaunch.select")
local orch = require("orchlaunch")
local state = require("orchlaunch.state")
local config = require("orchlaunch.config")

-- ---- no project loaded ---------------------------------------------------------
reset()
for name, fn in pairs({
    select_and_run = select.select_and_run,
    select_active = select.select_active,
    select_cmake_target = select.select_cmake_target,
    select_toolchain = select.select_toolchain,
    select_cmake_profile = select.select_cmake_profile,
    select_external_tool = select.select_external_tool,
    select_cmake_preset = function() select.select_cmake_preset({ kind = "configure" }) end,
}) do
    reset()
    h.ok(name .. " without a project does not raise", fn)
    h.check(name .. " without a project warns", saw("no .orch project loaded", vim.log.levels.WARN), vim.inspect(messages))
    h.eq(name .. " without a project shows no picker", #calls, 0)
end

-- ---- project without entries ----------------------------------------------------
local root = h.tempdir()
orch.setup({ root = root, silent = true })
orch.create_project(root)

for name, case in pairs({
    select_and_run = { select.select_and_run, "no run configurations" },
    select_active = { select.select_active, "no run configurations" },
    select_toolchain = { select.select_toolchain, "no toolchains" },
    select_cmake_profile = { select.select_cmake_profile, "no CMake profiles" },
    select_external_tool = { select.select_external_tool, "no external tools" },
}) do
    reset()
    case[1]()
    h.check(name .. " on an empty project says so", saw(case[2], vim.log.levels.WARN), vim.inspect(messages))
    h.eq(name .. " on an empty project shows no picker", #calls, 0)
end
reset()
select.select_cmake_target({ on_select = function() end })
h.check("select_cmake_target without a model says so", saw("no CMake targets loaded", vim.log.levels.WARN), vim.inspect(messages))

-- ---- populated project -----------------------------------------------------------
state.add_toolchain(config.toolchain({ name = "gcc", type = "system", cmake = "cmake", c = "gcc", cxx = "g++", debugger = "gdb" }))
state.add_toolchain(config.toolchain({ name = "clang", type = "unix", cmake = "cmake", c = "clang", cxx = "clang++", debugger = "lldb" }))
state.add_external_tool(config.external_tool({ name = "fmt", program = "clang-format", cwd = "/src" }))
state.add_external_tool(config.external_tool({ name = "gen", program = "python3" }))
state.add_cmake_profile(config.cmake_settings({ name = "Debug", toolchain = "gcc" }))
state.add_cmake_profile(config.cmake_settings({ name = "Release", toolchain = "clang" }))
state.add_configuration(config.native({ name = "app", target = "app" }))
state.add_configuration(config.native({ name = "bare" }))
state.add_configuration(config.remote_debug({ name = "remote", connection = "host:1234" }))
state.add_configuration(config.compound({ name = "all", configurations = { "app", "remote" } }))
state.save()

-- select_toolchain
reset()
local picked
choose = function() return 2 end
select.select_toolchain({ on_select = function(tc) picked = tc end })
h.eq("toolchain picker is shown once", #calls, 1)
h.eq("toolchain picker lists every toolchain", #calls[1].items, 2)
h.check("toolchain label shows the toolchain", label(calls[1], 1):find("gcc", 1, true) ~= nil, label(calls[1], 1))
h.eq("choosing returns the toolchain", picked and picked.name, "clang")
reset()
picked = nil
select.select_toolchain({ on_select = function(tc) picked = tc end })
h.eq("cancelling selects nothing", picked, nil)
h.ok("select_toolchain without on_select does not raise", function()
    choose = function() return 1 end
    select.select_toolchain()
end)

-- select_external_tool
reset()
choose = function() return 1 end
select.select_external_tool({ on_select = function(tool) picked = tool end })
h.eq("tool picker lists every tool", #calls[1].items, 2)
h.check("tool label shows program and cwd", label(calls[1], 1):find("clang-format", 1, true) ~= nil and label(calls[1], 1):find("/src", 1, true) ~= nil, label(calls[1], 1))
h.check("tool without cwd says so", label(calls[1], 2):find("cwd=workspace", 1, true) ~= nil, label(calls[1], 2))
h.eq("choosing returns the tool", picked and picked.name, "fmt")

-- select_cmake_profile
reset()
choose = function() return 2 end
select.select_cmake_profile({ on_select = function(p) picked = p end })
h.eq("profile picker lists profiles", #calls[1].items, 2)
h.eq("choosing returns the profile", picked and picked.name, "Release")
h.check("profile label shows its toolchain", label(calls[1], 1):find("tc=gcc", 1, true) ~= nil, label(calls[1], 1))
reset()
select.select_cmake_profile({ kind = "build", on_select = function() end })
h.check("kind filter with no match says so", saw("no matching CMake profiles", vim.log.levels.WARN) or #calls == 1, vim.inspect(messages))

-- a hand-written profile without `kind` (the schema allows omitting it) must not break the label
h.write(root .. "/.orch/cmake_settings.json", '{ "cmake": { "active": "Hand", "profiles": [ { "name": "Hand" } ] } }\n')
vim.cmd("OrchLaunchReload")
reset()
choose = function() return 1 end
h.ok("a profile without kind can be listed", function()
    select.select_cmake_profile({ on_select = function(p) picked = p end })
end)
h.eq("a profile without kind can be chosen", picked and picked.name, "Hand")
h.ok("its label renders", function()
    label(calls[1], 1)
end)

-- select_and_run / select_active use the real run configurations
reset()
choose = function() return nil end
select.select_and_run()
h.eq("run picker lists the configurations", #calls[1].items, 4)
h.check("native label shows its target", label(calls[1], 1):find("native → app", 1, true) ~= nil, label(calls[1], 1))
h.check("native without target says so", label(calls[1], 2):find("no target", 1, true) ~= nil, label(calls[1], 2))
h.check("remote label shows its connection", label(calls[1], 3):find("host:1234", 1, true) ~= nil, label(calls[1], 3))
h.check("compound label shows the child count", label(calls[1], 4):find("2 children", 1, true) ~= nil, label(calls[1], 4))
h.check("run prompt mentions run", calls[1].prompt:find("run", 1, true) ~= nil, calls[1].prompt)
reset()
select.select_and_run({ mode = "debug" })
h.check("debug prompt mentions debug", calls[1].prompt:find("debug", 1, true) ~= nil, calls[1].prompt)

reset()
choose = function() return 3 end
select.select_active()
local active = require("orchlaunch.active")
h.eq("select_active stores the choice", active.get(state.root()), "remote")
h.check("select_active confirms", saw("active configuration: remote"), vim.inspect(messages))
reset()
select.select_active()
h.check("the active configuration is marked", label(calls[1], 3):find("●", 1, true) ~= nil, label(calls[1], 3))
h.check("others are not marked", label(calls[1], 1):find("●", 1, true) == nil, label(calls[1], 1))

-- select_cmake_preset with a real CMakePresets.json
h.write(root .. "/CMakePresets.json", [[{
  "version": 3,
  "configurePresets": [
    { "name": "base", "hidden": true, "generator": "Ninja" },
    { "name": "dev", "inherits": "base", "binaryDir": "${sourceDir}/build" }
  ],
  "buildPresets": [ { "name": "dev-build", "configurePreset": "dev" } ]
}]])
vim.cmd("OrchLaunchReload")
reset()
choose = function() return 2 end
select.select_cmake_preset({ kind = "configure", on_select = function(p) picked = p end })
h.check("preset picker is shown", #calls == 1, #calls)
h.check("hidden presets are marked", calls[1] and label(calls[1], 1):find("(hidden)", 1, true) ~= nil, calls[1] and label(calls[1], 1))
h.eq("choosing returns the preset", picked and picked.name, "dev")
reset()
select.select_cmake_preset({ kind = "build", on_select = function(p) picked = p end })
h.check("build presets are listed separately", calls[1] and #calls[1].items == 1, vim.inspect(messages))
reset()
select.select_cmake_preset({ kind = "package", on_select = function() end })
h.check("a missing preset kind warns", saw("no package presets found", vim.log.levels.WARN), vim.inspect(messages))
reset()
h.ok("select_cmake_preset without kind does not raise", function()
    select.select_cmake_preset({ on_select = function() end })
end)

-- generic_select
reset()
choose = function() return 2 end
select.generic_select({ { name = "a" }, { name = "b" } }, { on_select = function(item) picked = item end })
h.eq("generic_select labels by name", calls[1].format_item({ name = "zz" }), "zz")
h.eq("generic_select returns the choice", picked and picked.name, "b")

h.done("selection pickers")
