vim.opt.rtp:append("/home/olokreaz/.config/nvim")
vim.opt.rtp:append("/home/olokreaz/.local/share/nvim/lazy/nui.nvim")
vim.opt.rtp:append("/home/olokreaz/.local/share/nvim/lazy/nui-components.nvim")
vim.opt.rtp:append("/home/olokreaz/.local/share/nvim/lazy/toml.nvim")
-- Headless smoke test for the OrchLaunch UI/commands layer.
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

-- 1. module loading ----------------------------------------------------------
local modules = {
    "orchlaunch",
    "orchlaunch.config",
    "orchlaunch.state",
    "orchlaunch.project",
    "orchlaunch.process",
    "orchlaunch.presets",
    "orchlaunch.cmake",
    "orchlaunch.active",
    "orchlaunch.runner",
    "orchlaunch.commands",
    "orchlaunch.ui",
    "orchlaunch.ui.editor",
    "orchlaunch.ui.browser",
    "orchlaunch.ui.list_dialog",
    "orchlaunch.ui.scratch",
}

for _, module in ipairs(modules) do
    local ok, err = pcall(require, module)
    check("require " .. module, ok, err)
end

-- 2. command registration ----------------------------------------------------
local ok, err = pcall(function()
    require("orchlaunch.commands").register()
end)
check("commands.register", ok, err)

for _, name in ipairs({
    "OrchLaunch",
    "OrchLaunchCreateProject",
    "OrchLaunchReload",
    "OrchLaunchSelect",
    "OrchLaunchRun",
    "OrchLaunchDebug",
    "OrchLaunchEdit",
    "OrchLaunchToolchains",
    "OrchLaunchExternalTools",
    "OrchLaunchCMake",
    "OrchLaunchImportCMakePresets",
    "OrchLaunchLoadCMake",
    "OrchLaunchExternalTool",
}) do
    check("command " .. name, vim.fn.exists(":" .. name) == 2)
end

-- 3. data layer round trip ---------------------------------------------------
local root = vim.fn.tempname()
vim.fn.mkdir(root, "p")

ok, err = pcall(function()
    local orch = require("orchlaunch")
    local state = require("orchlaunch.state")
    local config = require("orchlaunch.config")

    orch.create_project(root)
    assert(state.is_loaded(), "project not loaded")

    state.add_toolchain(config.toolchain({
        name = "Clang",
        type = "system",
        cmake = "cmake",
        c = "clang",
        cxx = "clang++",
        debugger = "lldb",
    }))
    state.add_external_tool(config.external_tool({ name = "gen", program = "${workspace}/tools/gen" }))
    state.add_configuration(config.native({
        name = "Game",
        target = "${workspace}/build/game",
        args = { "-dev", "-console" },
        environment = { LOG = "debug" },
        console = config.console({ mode = "embedded" }),
        before = config.before({ "build", config.external("gen") }),
    }))
    state.add_configuration(config.remote_debug({
        name = "Attach",
        symbol = "game",
        connection = "localhost:1234",
        adapter = "gdb",
    }))
    state.add_configuration(config.compound({ name = "All", configurations = { "Game", "Attach" } }))
    state.save()

    state.reload()
    assert(#state.run_configurations().configurations == 3, "expected 3 configurations")
    assert(state.require_configuration("Game").target == "${workspace}/build/game", "target mismatch")
    assert(state.require_toolchain("Clang").cxx == "clang++", "toolchain mismatch")
    assert(state.require_external_tool("gen").program == "${workspace}/tools/gen", "external tool mismatch")

    local active = require("orchlaunch.active")
    active.set(root, "Game")
    assert(active.get(root) == "Game", "active mismatch")
end)
check("data layer round trip", ok, err)

-- 4. details formatter does not crash ----------------------------------------
ok, err = pcall(function()
    local state = require("orchlaunch.state")
    -- reach the private formatter indirectly by opening nothing; just ensure
    -- the state is usable by commands' completion path
    local cfg = state.require_configuration("Game")
    assert(cfg.before.tools[1] == "build", "before build missing")
    assert(cfg.before.tools[2].tool == "gen", "before external missing")
end)
check("before-launch structure", ok, err)

print(failures == 0 and "\nALL PASS" or ("\n" .. failures .. " FAILURE(S)"))
if failures > 0 then
    os.exit(1)
end
