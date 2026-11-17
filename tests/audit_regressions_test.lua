-- Regression guards for the stage-1 audit findings. Each check reproduces the
-- finding on a real .orch project; the fixed behaviour is what must hold.

local here = vim.fn.fnamemodify(debug.getinfo(1, "S").source:sub(2), ":p:h")
package.path = here .. "/?.lua;" .. package.path
local h = require("harness")

local messages = {}
vim.notify = function(msg)
    messages[#messages + 1] = tostring(msg)
end

local orch = require("orchlaunch")
local state = require("orchlaunch.state")
local config = require("orchlaunch.config")

local function new_project()
    local root = h.tempdir()
    vim.fn.mkdir(root .. "/.orch", "p")
    orch.setup({ root = root, silent = true })
    orch.create_project(root)
    return root
end

-- P2-1: a configurations object instead of a list must be rejected, not
-- silently replaced by an empty list on save.
do
    local root = h.tempdir()
    vim.fn.mkdir(root .. "/.orch", "p")
    local path = root .. "/.orch/run_configurations.json"
    vim.fn.writefile({ '{"configurations":{"Keep":{"name":"Keep"}}}' }, path)
    orch.setup({ root = root, silent = true })
    orch.create_project(root)
    h.check("P2-1: object instead of list is reported", table.concat(messages, "\n"):find("must be a list", 1, true) ~= nil, table.concat(messages, "\n"))
end

-- P2-2: a file that changed on disk since the last load is not overwritten.
do
    local root = new_project()
    local path = root .. "/.orch/run_configurations.json"
    state.add_configuration(config.native({ name = "Mine", target = "app" }))
    state.save()
    vim.fn.writefile({ '{"configurations":[{"name":"Hand","type":"native","target":"app"}]}' }, path)
    state.add_configuration(config.native({ name = "Second", target = "app" }))
    local ok = state.save()
    local text = table.concat(vim.fn.readfile(path), "\n")
    h.check("P2-2: a hand edit on disk is not overwritten", ok == false and text:find('"Hand"', 1, true) ~= nil, text)
end

-- P2-3: :OrchLaunchSelect <name> selects that configuration, not the picker.
do
    local root = new_project()
    state.add_configuration(config.native({ name = "Alpha", target = "app" }))
    state.add_configuration(config.native({ name = "Beta", target = "app" }))
    state.save()
    vim.cmd("OrchLaunchSelect Beta")
    local active = require("orchlaunch.active").get and require("orchlaunch.active").get(root)
    h.eq("P2-3: named select sets the active configuration", active, "Beta")
end

-- P2-5: an external breakpoint edit reaches nvim-dap after reload.
do
    local dap_root = (vim.env.ORCHLAUNCH_DEPS and vim.env.ORCHLAUNCH_DEPS ~= "" and vim.env.ORCHLAUNCH_DEPS
        or vim.fn.stdpath("data") .. "/lazy") .. "/nvim-dap"
    if vim.fn.isdirectory(dap_root) == 1 then
        vim.opt.rtp:append(dap_root)
    end
    local dapbp_ok, dapbp = pcall(require, "dap.breakpoints")
    if not dapbp_ok then
        h.check("P2-5: nvim-dap is available for the breakpoint check", false, "nvim-dap not found at " .. dap_root)
    else
        local root = new_project()
        local src = root .. "/a.cpp"
        vim.fn.writefile({ "int a;", "int b;", "int c;" }, src)
        local bp_path = root .. "/.orch/breakpoints.json"
        local function write_bp(line)
            vim.fn.writefile({ ('{"breakpoints":[{"file":"%s","line":%d}]}'):format(src, line) }, bp_path)
        end
        write_bp(1)
        require("orchlaunch.breakpoints").load()
        write_bp(3)
        vim.uv.sleep(1100)
        vim.cmd("doautocmd FocusGained")
        local live = {}
        for _, bps in pairs(dapbp.get()) do
            for _, bp in ipairs(bps) do
                live[#live + 1] = bp.line
            end
        end
        h.check("P2-5: live breakpoints follow the external edit", vim.tbl_contains(live, 3) and not vim.tbl_contains(live, 1), vim.inspect(live))
    end
end

-- P2-4: :OrchLaunchRunHere must not run a configuration from another project.
-- The loaded project is A; the buffer is B's run_configurations.json. Nothing
-- may run, even though both files share the same name.
do
    local runs = {}
    local runner = require("orchlaunch.runner")
    local original_run = runner.run
    runner.run = function(name)
        runs[#runs + 1] = name
    end

    local a = new_project()
    state.add_configuration(config.native({ name = "Same", target = "app" }))
    state.save()

    local b = h.tempdir()
    vim.fn.mkdir(b .. "/.orch", "p")
    vim.fn.writefile({ '{"configurations":[{"name":"Same","type":"native","target":"app"}]}' }, b .. "/.orch/run_configurations.json")
    vim.cmd("edit " .. vim.fn.fnameescape(b .. "/.orch/run_configurations.json"))
    vim.api.nvim_win_set_cursor(0, { 1, 0 })
    messages = {}
    vim.cmd("OrchLaunchRunHere")
    runner.run = original_run

    h.eq("P2-4: a foreign project's configuration is not run", #runs, 0, vim.inspect(runs) .. " " .. a)
end

h.done("stage-1 audit regressions")
