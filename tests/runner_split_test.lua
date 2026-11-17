-- The runner is split into modules, but its public API must not change. Every
-- function the commands and tests use is still reachable from
-- `require("orchlaunch.runner")`, and the shared active-job state lives in one
-- module that all parts use.

local here = vim.fn.fnamemodify(debug.getinfo(1, "S").source:sub(2), ":p:h")
package.path = here .. "/?.lua;" .. package.path
local h = require("harness")

local runner = require("orchlaunch.runner")

local PUBLIC = {
    "cancel", "configure", "build", "clean", "rebuild", "install", "test",
    "configure_async", "build_async", "clean_async", "rebuild_async",
    "install_async", "test_async", "run", "run_active", "load_cmake",
    "load_cmake_async", "refresh_cmake", "run_external_tool",
    "run_external_tool_async", "launch_environment", "launch_adapter",
}
for _, name in ipairs(PUBLIC) do
    h.check("public runner." .. name .. " is still exported", type(runner[name]) == "function")
end

local ok, shared = pcall(require, "orchlaunch.runner.state")
h.check("shared active-job state module exists", ok, tostring(shared))
if ok then
    h.check("shared state exposes get/set/clear", type(shared.get) == "function" and type(shared.set) == "function" and type(shared.clear) == "function")
    shared.set("job-a", "label-a")
    local job, label = shared.get()
    h.eq("set then get returns the same job", job, "job-a")
    h.eq("set then get returns the same label", label, "label-a")
    shared.clear()
    local job2 = shared.get()
    h.eq("clear empties the active job", job2, nil)
end

h.done("runner split keeps the public API")

-- The target-loading part lives in runner/targets.lua and is re-exported by
-- the runner, so commands and tests keep calling `runner.load_cmake(...)`.
do
    local targets_ok, targets = pcall(require, "orchlaunch.runner.targets")
    h.check("runner/targets module exists", targets_ok, tostring(targets))
    if targets_ok then
        for _, name in ipairs({ "load_cmake", "load_cmake_async", "refresh_cmake" }) do
            h.check("targets." .. name .. " is defined there", type(targets[name]) == "function")
            h.check("runner." .. name .. " is the same function", runner[name] == targets[name])
        end
    end
end
h.done("runner targets module")

-- CMake steps live in runner/cmake.lua; the runner re-exports the same functions.
do
    local cmake_ok, cmake_steps = pcall(require, "orchlaunch.runner.cmake")
    h.check("runner/cmake module exists", cmake_ok, tostring(cmake_steps))
    if cmake_ok then
        for _, name in ipairs({ "cancel", "configure", "build", "clean", "rebuild", "install", "test",
            "configure_async", "build_async", "clean_async", "rebuild_async", "install_async", "test_async" }) do
            h.check("cmake." .. name .. " is defined there", type(cmake_steps[name]) == "function")
            h.check("runner." .. name .. " is the same function", runner[name] == cmake_steps[name])
        end
    end
end
h.done("runner cmake steps module")

-- Launching (native, compound, remote-debug, dispatch) lives in runner/launch.lua.
do
    local launch_ok, launch = pcall(require, "orchlaunch.runner.launch")
    h.check("runner/launch module exists", launch_ok, tostring(launch))
    if launch_ok then
        for _, name in ipairs({ "run", "run_active", "launch_environment", "launch_adapter" }) do
            h.check("launch." .. name .. " is defined there", type(launch[name]) == "function")
            h.check("runner." .. name .. " is the same function", runner[name] == launch[name])
        end
    end
end
h.done("runner launch module")

-- Cross-module contract: each part must export what the others call. Luacheck
-- cannot see across files, so this list is what keeps a split from breaking
-- silently (a missing export only fails at runtime).
do
    local expected = {
        ["orchlaunch.runner.before"] = { "run_before", "run_before_async", "run_tool", "run_tool_async" },
        ["orchlaunch.runner.cmake"] = { "run_cmake_step", "run_cmake_step_async", "start_async", "cancel" },
        ["orchlaunch.runner.state"] = { "get", "set", "clear", "clear_if" },
        ["orchlaunch.runner.persist"] = { "before_action" },
        ["orchlaunch.runner.launch"] = { "run", "run_active", "launch_environment", "launch_adapter" },
        ["orchlaunch.runner.targets"] = { "load_cmake", "load_cmake_async", "refresh_cmake" },
    }
    for mod, names in pairs(expected) do
        local m = require(mod)
        for _, n in ipairs(names) do
            h.check(mod .. "." .. n .. " is exported", m[n] ~= nil)
        end
    end
end
h.done("runner cross-module exports")
