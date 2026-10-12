vim.opt.rtp:append("/home/olokreaz/.config/nvim")
vim.opt.rtp:append("/home/olokreaz/.local/share/nvim/lazy/nui.nvim")
vim.opt.rtp:append("/home/olokreaz/.local/share/nvim/lazy/nui-components.nvim")
vim.opt.rtp:append("/home/olokreaz/.local/share/nvim/lazy/toml.nvim")
-- Headless test for OrchLaunch CMakePresets integration.
vim.opt.rtp:append("/home/olokreaz/.local/share/nvim/lazy/toml.nvim")

local function add(rtp)
    vim.opt.rtp:append(rtp)
end

add("/home/olokreaz/.config/nvim")
add("/home/olokreaz/.local/share/nvim/lazy/nui.nvim")
add("/home/olokreaz/.local/share/nvim/lazy/nui-components.nvim")
add("/home/olokreaz/.local/share/nvim/lazy/toml.nvim")

local failures = 0
local function check(name, ok, err)
    if ok then
        print("PASS  " .. name)
    else
        failures = failures + 1
        print("FAIL  " .. name .. "  " .. tostring(err))
    end
end

local root = vim.fn.tempname()
vim.fn.mkdir(root, "p")

local cmake_presets = [[
{
  "version": 6,
  "include": ["shared.json"],
  "configurePresets": [
    {
      "name": "base",
      "hidden": true,
      "cacheVariables": { "COMMON": "1" },
      "environment": { "BASE": "b" }
    },
    {
      "name": "debug",
      "displayName": "Debug (Ninja)",
      "inherits": ["base"],
      "generator": "Ninja",
      "binaryDir": "${sourceDir}/build/debug",
      "cacheVariables": { "CMAKE_BUILD_TYPE": "Debug", "COMMON": "2" },
      "environment": { "CHILD": "c" }
    }
  ],
  "buildPresets": [
    { "name": "debug-build", "configurePreset": "debug" }
  ],
  "testPresets": [
    { "name": "tests", "configurePreset": "debug" }
  ]
}
]]

local shared = [[
{
  "version": 6,
  "configurePresets": [
    {
      "name": "included",
      "hidden": true,
      "cacheVariables": { "FROM_INCLUDE": "yes" }
    },
    {
      "name": "with-compiler",
      "cacheVariables": { "CMAKE_C_COMPILER": "/usr/bin/gcc" }
    }
  ]
}
]]

local f = assert(io.open(vim.fs.joinpath(root, "CMakePresets.json"), "w"))
f:write(cmake_presets)
f:close()
f = assert(io.open(vim.fs.joinpath(root, "shared.json"), "w"))
f:write(shared)
f:close()

local presets = require("orchlaunch.presets")
local cmake = require("orchlaunch.cmake")
local config = require("orchlaunch.config")
local state = require("orchlaunch.state")

-- 1. discovery --------------------------------------------------------------
local discovered
check("discover", pcall(function()
    discovered = presets.discover(root)
end))

check("sources merged", discovered and #discovered.sources == 2, discovered and #discovered.sources)
check("configure count", discovered and #discovered.configure == 4, discovered and #discovered.configure)

-- 2. visible hides hidden ----------------------------------------------------
check("visible hides hidden", (function()
    local names = {}
    for _, p in ipairs(presets.visible(discovered, "configure")) do
        names[p.name] = true
    end
    return names.debug == true and names.base == nil and names.included == nil
end)())

-- 3. inheritance resolution --------------------------------------------------
local resolved
check("resolve", pcall(function()
    resolved = presets.resolve(discovered, "configure", "debug")
end))

check("inherited cache merged", resolved and resolved.cacheVariables.COMMON == "2", resolved and resolved.cacheVariables.COMMON)
check("inherited env merged", resolved and resolved.environment.BASE == "b" and resolved.environment.CHILD == "c")
check("inherits stripped", resolved and resolved.inherits == nil)

-- 4. macro expansion ---------------------------------------------------------
check("expand sourceDir", presets.expand("${sourceDir}/build", { source_dir = root }) == root .. "/build")
check("expand env", presets.expand("$env{HOME}", { env = { HOME = "/home/x" } }) == "/home/x")

-- 5. has_compilers -----------------------------------------------------------
check("has_compilers false", presets.has_compilers(resolved) == false)
check("has_compilers true", (function()
    local with_compiler = presets.resolve(discovered, "configure", "with-compiler")
    return presets.has_compilers(with_compiler) == true
end)())

-- 6. toolchain args ----------------------------------------------------------
check("toolchain args injected", (function()
    local args = presets.toolchain_args(resolved, { c = "clang", cxx = "clang++" })
    return #args == 2 and args[1] == "-DCMAKE_C_COMPILER=clang" and args[2] == "-DCMAKE_CXX_COMPILER=clang++"
end)())

check("toolchain args skipped when preset defines compiler", (function()
    local with_compiler = presets.resolve(discovered, "configure", "with-compiler")
    local args = presets.toolchain_args(with_compiler, { c = "clang", cxx = "clang++" })
    return #args == 0
end)())

-- 7. cmake argv builders -----------------------------------------------------
local orch = require("orchlaunch")
orch.create_project(root)
state.add_toolchain(config.toolchain({
    name = "Clang",
    type = "system",
    cmake = "cmake",
    c = "clang",
    cxx = "clang++",
    debugger = "lldb",
}))
state.set_cmake_settings(config.cmake_settings({
    configure_preset = "debug",
    build_preset = "debug-build",
    test_preset = "tests",
    toolchain = "Clang",
}))

check("binary_dir from preset", cmake.binary_dir() == root .. "/build/debug", cmake.binary_dir())

check("configure uses --preset + compiler", (function()
    local spec = cmake.configure_spec()
    local args = table.concat(spec.args, " ")
    return args:find("--preset debug", 1, true) ~= nil
        and args:find("CMAKE_C_COMPILER=clang", 1, true) ~= nil
end)(), table.concat(cmake.configure_spec().args, " "))

check("build uses --build --preset", (function()
    local args = table.concat(cmake.build_spec().args, " ")
    return args:find("--build --preset debug-build", 1, true) ~= nil
end)(), table.concat(cmake.build_spec().args, " "))

check("build forwards target", (function()
    local args = cmake.build_spec("game").args
    return args[#args - 1] == "--target" and args[#args] == "game"
end)())

check("test uses ctest --preset", (function()
    return cmake.test_spec().program == "ctest"
        and cmake.test_spec().args[1] == "--preset"
        and cmake.test_spec().args[2] == "tests"
end)())

-- 8. find_target -------------------------------------------------------------
vim.fn.mkdir(root .. "/build/debug", "p")
local exe = io.open(root .. "/build/debug/game", "w")
exe:write("#!/bin/sh\n")
exe:close()

check("find_target", cmake.find_target("game") == root .. "/build/debug/game", cmake.find_target("game"))
check("find_target missing", cmake.find_target("nope") == nil)

print(failures == 0 and "\nALL PASS" or ("\n" .. failures .. " FAILURE(S)"))
if failures > 0 then
    os.exit(1)
end
