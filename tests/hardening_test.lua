-- Regression tests for the medium/low audit fixes: safe persistence, schema
-- validation, sandboxed Lua profiles, preset conditions, async cancel and
-- unique fibrous augroups.

local here = vim.fn.fnamemodify(debug.getinfo(1, "S").source:sub(2), ":p:h")
package.path = here .. "/?.lua;" .. package.path
local h = require("harness")

local config = require("orchlaunch.config")
local state = require("orchlaunch.state")
local presets = require("orchlaunch.presets")
local process = require("orchlaunch.process")
local runner = require("orchlaunch.runner")
local util = require("orchlaunch.ui.fibrous.util")

--- @param path string
--- @param body string
local function script(path, body)
    h.write(path, "#!/bin/sh\n" .. body .. "\n")
    vim.fn.setfperm(path, "rwxr-xr-x")
    return path
end

-- ============================================================================
-- JSON validation
-- ============================================================================
local dir = h.tempdir()
h.write(dir .. "/bad.json", "{not json")
local bad, bad_err = config.load(dir .. "/bad.json")
h.check("malformed JSON returns nil", bad == nil, vim.inspect(bad))
h.check("malformed JSON returns an error", type(bad_err) == "string" and bad_err ~= "", vim.inspect(bad_err))

h.write(dir .. "/list.json", "[1, 2, 3]")
local list, list_err = config.load(dir .. "/list.json")
h.check("JSON list is rejected", list == nil, vim.inspect(list))
h.check("JSON list reports an object error", list_err and list_err:find("object", 1, true) ~= nil, list_err)

local empty_list = h.tempdir() .. "/empty.json"
h.write(empty_list, "[]")
h.eq("empty JSON list decodes to an empty table", config.load(empty_list), {})

-- ============================================================================
-- Sandboxed Lua profiles
-- ============================================================================
h.eq(
    "from_lua has no globals",
    config.from_lua("return { os = os == nil, print = print == nil, require = require == nil }"),
    { os = true, print = true, require = true }
)
local sandbox_ok = pcall(config.from_lua, "os.execute('true')")
h.check("from_lua blocks os.execute", not sandbox_ok)
local budget_ok = pcall(config.from_lua, "while true do end")
h.check("from_lua enforces an instruction budget", not budget_ok)
h.eq("from_lua still returns data", config.from_lua("return { value = 42 }"), { value = 42 })

-- ============================================================================
-- Project state: invalid reloads and external edits
-- ============================================================================
local root = h.tempdir()
require("orchlaunch").create_project(root)
state.setup(root)
state.add_configuration(config.native({ name = "Keep", target = "/bin/true" }))
local ok_save, save_err = state.save()
h.check("initial project save succeeds", ok_save == true, save_err)

local paths = state.get().paths
local run_path = paths.run_configurations
local original = h.read(run_path)

h.write(run_path, "{broken")
local reload_ok = pcall(state.reload)
h.check("invalid JSON makes reload fail", not reload_ok)
h.check(
    "invalid reload keeps the old in-memory state",
    state.configuration("Keep") ~= nil,
    vim.inspect(state.run_configurations().configurations)
)
h.write(run_path, original)
state.reload()

local hand = vim.json.decode(original)
hand["$schema"] = "https://example.invalid/orch.schema.json"
hand.extra = { owner = "hand" }
h.write(run_path, config.stringify(hand))

local saved, conflict = state.save()
h.check("save refuses to overwrite an external edit", saved == false, vim.inspect(saved))
h.check("conflict error names the file", conflict and conflict:find(run_path, 1, true) ~= nil, conflict)
h.contains("external edit is still on disk", h.read(run_path), '"owner": "hand"')

state.reload()
state.add_configuration(config.native({ name = "AfterReload", target = "/bin/true" }))
h.check("save after reload succeeds", state.save())
local reloaded_raw = h.read(run_path)
h.contains("unknown top-level keys survive save", reloaded_raw, '"extra"')
h.contains("$schema survives save", reloaded_raw, '"$schema"')
h.contains("new configuration is present", reloaded_raw, '"AfterReload"')

local before_noop = h.read(run_path)
h.check("semantic no-op save succeeds", state.save())
h.eq("semantic no-op save leaves the file byte-identical", h.read(run_path), before_noop)

-- ============================================================================
-- Preset conditions and inheritance validation
-- ============================================================================
h.eq("condition nil is visible", presets.condition(nil, {}), true)
h.eq("condition not(false) is true", presets.condition({ ["not"] = { ["const"] = false } }, {}), true)
h.eq("condition not(true) is false", presets.condition({ ["not"] = { ["const"] = true } }, {}), false)
h.eq(
    "condition and combines",
    presets.condition({ ["and"] = { { ["const"] = true }, { equals = { "$env{HOME}", "$env{HOME}" } } } }, { env = { HOME = "/h" } }),
    true
)
h.eq(
    "condition matches supports patterns",
    presets.condition({ matches = { "linux-x86_64", "^linux" } }, {}),
    true
)

local discovered = {
    configure = {
        { name = "A", condition = { ["const"] = false } },
        { name = "B", condition = { ["not"] = { ["const"] = false } } },
        { name = "C", hidden = true },
    },
    build = {
        { name = "X", inherits = "Y" },
        { name = "Y", inherits = "X" },
    },
}
local visible = presets.visible(discovered, "configure", {})
h.eq("visible applies conditions", #visible, 1)
h.eq("visible keeps the true preset", visible[1].name, "B")
local ctx = {}
presets.visible(discovered, "configure", ctx)
h.eq("visible does not mutate the caller context", ctx, {})

local cycle, cycle_err = presets.resolve(discovered, "build", "X")
h.check("inheritance cycle returns nil", cycle == nil, vim.inspect(cycle))
h.check("inheritance cycle reports an error", cycle_err and cycle_err:find("cycle", 1, true) ~= nil, cycle_err)

-- ============================================================================
-- Process and async cancellation
-- ============================================================================
local missing = process.run({ program = "/definitely/not/here/orchlaunch" })
h.eq("missing executable reports code 127", missing.code, 127)
h.check("missing executable reports stderr", (missing.stderr or ""):find("not/here", 1, true) ~= nil, missing.stderr)
h.check("signal termination is not success", not process.succeeded({ code = 0, signal = 15 }))
h.check("clean exit is success", process.succeeded({ code = 0, signal = 0 }))

local fake_dir = h.tempdir()
local fake_cmake = script(fake_dir .. "/cmake", "exec sleep 5")
local fake_ctest = script(fake_dir .. "/ctest", "exit 0")
state.add_toolchain(config.toolchain({
    name = "Fake",
    type = "unix",
    cmake = fake_cmake,
    c = "cc",
    cxx = "c++",
    debugger = "gdb",
}))
state.set_cmake_settings(config.cmake_settings({ toolchain = "Fake", build_dir = root .. "/build" }))
h.check("fake toolchain settings save", state.save())
h.eq("ctest is resolved next to cmake", require("orchlaunch.cmake").ctest_program(), fake_ctest)

local finished, finish_ok = false, nil
runner.build_async("demo", function(ok)
    finished, finish_ok = true, ok
end)
h.check("async build starts", runner.cancel())
h.check("async build completion is delivered", vim.wait(3000, function()
    return finished
end), "callback timed out")
h.eq("cancelled build reports failure", finish_ok, false)

-- ============================================================================
-- Fibrous augroup isolation
-- ============================================================================
local first = util.unique_augroup("OrchlaunchTest")
local second = util.unique_augroup("OrchlaunchTest")
h.check("unique augroup names differ", first ~= second, first .. " vs " .. second)
h.check("unique augroup names keep the prefix", first:find("OrchlaunchTest", 1, true) == 1, first)

h.done("hardening regression tests")
