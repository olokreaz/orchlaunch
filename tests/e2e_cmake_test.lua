-- End-to-end test: a real CMake project driven through every OrchLaunch layer.
--
--   CMakeLists.txt + CMakePresets.json
--     -> preset discovery
--     -> import into CMake profiles
--     -> configure_spec / real configure
--     -> File API target discovery
--     -> build_spec / real build
--     -> run the produced executable
--     -> test_spec / real ctest
--     -> install_spec / real install
--     -> auto-created run configurations
--
-- Any failure here means either the test contract below is wrong or the plugin
-- broke somewhere along the chain.

local here = vim.fn.fnamemodify(debug.getinfo(1, "S").source:sub(2), ":p:h")
package.path = here .. "/?.lua;" .. package.path
local h = require("harness")

local root = h.tempdir()

h.write(root .. "/CMakeLists.txt", [[
cmake_minimum_required(VERSION 3.16)
project(orch_e2e C)
enable_testing()
add_executable(hello main.c)
add_library(greet STATIC greet.c)
add_library(util STATIC greet.c)
add_library(shared SHARED greet.c)
add_test(NAME hello_runs COMMAND hello)
install(TARGETS hello RUNTIME DESTINATION bin)
install(TARGETS greet ARCHIVE DESTINATION lib)
]])
h.write(root .. "/main.c", [[
#include <stdio.h>
int main(void) { printf("hello from orch\n"); return 0; }
]])
h.write(root .. "/greet.c", "int greet(void) { return 42; }\n")

h.write(root .. "/CMakePresets.json", [[
{
  "version": 6,
  "configurePresets": [
    { "name": "base", "hidden": true, "generator": "Ninja",
      "cacheVariables": { "CMAKE_EXPORT_COMPILE_COMMANDS": "ON" } },
    { "name": "e2e-debug", "displayName": "E2E Debug", "inherits": "base",
      "binaryDir": "${sourceDir}/build/debug",
      "cacheVariables": { "CMAKE_BUILD_TYPE": "Debug" } },
    { "name": "e2e-compilers", "inherits": "base",
      "binaryDir": "${sourceDir}/build/compilers",
      "cacheVariables": { "CMAKE_C_COMPILER": "gcc" } }
  ],
  "buildPresets": [ { "name": "e2e-build", "configurePreset": "e2e-debug" } ],
  "testPresets": [ { "name": "e2e-test", "configurePreset": "e2e-debug" } ]
}
]])

local orch = require("orchlaunch")
local state = require("orchlaunch.state")
local config = require("orchlaunch.config")
local cmake = require("orchlaunch.cmake")
local presets = require("orchlaunch.presets")
local process = require("orchlaunch.process")
local runner = require("orchlaunch.runner")

-- 1. project scaffolding -----------------------------------------------------
h.check("project scaffolded", orch.create_project(root) ~= nil, "create_project returned nil")
for _, file in ipairs({ "run_configurations.json", "external_tools.json", "toolchain.json", "cmake_settings.json" }) do
    h.check("scaffold " .. file, vim.fn.filereadable(root .. "/.orch/" .. file) == 1)
end
h.check("state loaded", state.is_loaded())
h.eq("project root", state.root(), vim.fs.normalize(root))

state.add_toolchain(config.toolchain({
    name = "Gcc", type = "system", cmake = "cmake", c = "gcc", cxx = "g++", debugger = "gdb",
}))

-- 2. preset discovery --------------------------------------------------------
local discovered = state.presets()
h.check("presets discovered", discovered ~= nil)
h.check("preset sources", discovered ~= nil and #discovered.sources >= 1, discovered and #discovered.sources)
h.check("configure presets collected", discovered ~= nil and #discovered.configure == 3, discovered and #discovered.configure)
h.check("build presets collected", discovered ~= nil and #discovered.build == 1)
h.check("test presets collected", discovered ~= nil and #discovered.test == 1)

h.check("visible hides hidden base", (function()
    local names = {}
    for _, preset in ipairs(presets.visible(discovered, "configure")) do
        names[preset.name] = true
    end
    return names.base == nil and names["e2e-debug"] == true and names["e2e-compilers"] == true
end)())

-- 3. import presets into profiles -------------------------------------------
h.eq("sync imports configure+build profiles", state.sync_cmake_profiles(), 3)
h.eq("import is idempotent", state.sync_cmake_profiles(), 0)
h.check("imported configure profile", state.cmake_profile("e2e-debug") ~= nil)
h.eq("imported profile kind", state.cmake_profile("e2e-debug").kind, "configure")
h.eq("imported profiles inert", state.active_cmake_profile(), nil)
h.eq("imported build profile configurePreset", state.cmake_profile("e2e-build").configure_preset, "e2e-debug")

-- Active profile wiring all three presets (as a user would build manually).
state.add_cmake_profile(config.cmake_settings({
    name = "E2E", toolchain = "Gcc",
    configure_preset = "e2e-debug", build_preset = "e2e-build", test_preset = "e2e-test",
}))
state.set_active_cmake_profile("E2E")
state.save()

-- 4. effective directories + specs ------------------------------------------
h.eq("binary_dir from configure preset", cmake.binary_dir(), vim.fs.normalize(root .. "/build/debug"))
h.eq("source_dir", cmake.source_dir(), vim.fs.normalize(root))

local cspec = cmake.configure_spec()
h.eq("configure program", cspec.program, "cmake")
h.eq("configure cwd", cspec.cwd, vim.fs.normalize(root))
h.contains("configure uses --preset", table.concat(cspec.args, " "), "--preset e2e-debug")
h.contains("configure injects C compiler", table.concat(cspec.args, " "), "CMAKE_C_COMPILER=gcc")

local bspec = cmake.build_spec()
h.contains("build uses --build --preset", table.concat(bspec.args, " "), "--build --preset e2e-build")

local bspec_target = cmake.build_spec("hello")
h.check("build forwards --target", (function()
    local args = bspec_target.args
    return args[#args - 1] == "--target" and args[#args] == "hello"
end)())

-- 5. real configure + File API target discovery ------------------------------
local targets = cmake.load_targets()
h.check("real configure + discovery succeeds", targets ~= nil, "load_targets returned nil")
h.check("targets are a table", type(targets) == "table")

h.check("hello discovered as EXECUTABLE", (function()
    local target = cmake.target("hello")
    return target ~= nil and target.type == "EXECUTABLE" and type(target.artifact) == "string"
end)())
h.check("greet discovered as STATIC_LIBRARY", (function()
    local target = cmake.target("greet")
    return target ~= nil and target.type == "STATIC_LIBRARY"
end)())
h.check("util discovered as STATIC_LIBRARY", (function()
    local target = cmake.target("util")
    return target ~= nil and target.type == "STATIC_LIBRARY"
end)())
h.check("shared discovered as SHARED_LIBRARY", (function()
    local target = cmake.target("shared")
    return target ~= nil and target.type == "SHARED_LIBRARY"
end)())
h.check("targets sorted by name", (function()
    local list = cmake.targets()
    local names = vim.tbl_map(function(t) return t.name end, list)
    return table.concat(names, ",") == "greet,hello,shared,util"
end)(), vim.inspect(cmake.targets()))

-- 6. real build --------------------------------------------------------------
local built = process.run(bspec_target)
h.eq("real build succeeds", built.code, 0, built.stderr)

local exe = cmake.find_target("hello")
h.check("find_target resolves built executable", exe ~= nil and vim.fn.filereadable(exe) == 1, exe)

local launched = process.run({ program = exe, cwd = root })
h.eq("built executable runs", launched.code, 0, launched.stderr)
h.contains("built executable output", launched.stdout, "hello from orch")

-- 7. real ctest --------------------------------------------------------------
local tspec = cmake.test_spec()
h.eq("test program is ctest", tspec.program, "ctest")
h.eq("test uses --preset", tspec.args[1], "--preset")
h.eq("test preset name", tspec.args[2], "e2e-test")

local tested = process.run(tspec)
h.check("ctest succeeds", tested.code == 0, tested.stderr)
local ctest_out = (tested.stdout or "") .. (tested.stderr or "")
h.contains("ctest ran hello_runs", ctest_out, "hello_runs")

-- 8. real install ------------------------------------------------------------
local all_built = process.run(cmake.build_spec())
h.eq("build all targets succeeds", all_built.code, 0, all_built.stderr)

state.cmake_settings().install_dir = root .. "/install"
local ispec = cmake.install_spec()
h.contains("install uses --prefix", table.concat(ispec.args, " "), "--prefix")
local installed = process.run(ispec)
h.check("install succeeds", installed.code == 0, installed.stderr)
h.check("installed binary exists", vim.fn.filereadable(root .. "/install/bin/hello") == 1)

-- 9. toolchain injection skipped when preset defines a compiler --------------
state.add_cmake_profile(config.cmake_settings({
    name = "Compilers", toolchain = "Gcc", configure_preset = "e2e-compilers",
}))
state.set_active_cmake_profile("Compilers")
h.eq("binary_dir of compilers preset", cmake.binary_dir(), vim.fs.normalize(root .. "/build/compilers"))
h.check("no toolchain flags when preset sets compiler", (function()
    return table.concat(cmake.configure_spec().args, " "):find("CMAKE_C_COMPILER", 1, true) == nil
end)())

-- 10. auto-created run configurations ---------------------------------------
state.set_active_cmake_profile("E2E")

-- A configuration created by hand before the File API is parsed keeps its
-- runtime and executable exactly as the user set them.
state.add_configuration(config.native({ name = "greet", target = "", runtime = "shared" }))
state.save()

local before = #state.run_configurations().configurations
local loaded = runner.load_cmake()
h.check("load_cmake returns targets", loaded ~= nil)

h.check("executable target got a run configuration", state.configuration("hello") ~= nil)
h.eq("auto configuration is native", state.configuration("hello").type, "native")
h.eq("executable runtime", state.configuration("hello").runtime, "executable")
h.eq("auto configuration targets the target", state.configuration("hello").target, "hello")
h.eq("auto configuration cwd is build dir", state.configuration("hello").cwd, cmake.binary_dir())

local static = state.configuration("util")
h.check("static library got a run configuration", static ~= nil)
h.eq("static runtime", static and static.runtime, "static")
h.eq("static has no executable", static and static.target, nil)

local shared = state.configuration("shared")
h.check("shared library got a run configuration", shared ~= nil)
h.eq("shared runtime", shared and shared.runtime, "shared")
h.eq("shared has no executable", shared and shared.target, nil)

local manual = state.configuration("greet")
h.eq("manual runtime preserved", manual and manual.runtime, "shared")
h.eq("manual executable preserved", manual and manual.target, "")

h.eq("three configurations added", #state.run_configurations().configurations, before + 3)
runner.load_cmake()
h.eq("reloading does not duplicate", #state.run_configurations().configurations, before + 3)

-- 11. persistence of the whole selection -------------------------------------
state.reload()
h.eq("active profile persisted", state.active_cmake_profile(), "E2E")
h.eq("configure preset persisted", state.cmake_settings().configure_preset, "e2e-debug")
h.eq("build preset persisted", state.cmake_settings().build_preset, "e2e-build")
h.eq("test preset persisted", state.cmake_settings().test_preset, "e2e-test")
h.check("auto configuration persisted", state.configuration("hello") ~= nil)
h.eq("auto runtime persisted", state.configuration("shared") and state.configuration("shared").runtime, "shared")
h.eq("manual runtime survives reload", state.configuration("greet") and state.configuration("greet").runtime, "shared")

h.done("CMake end-to-end")
