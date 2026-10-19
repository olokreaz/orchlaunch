-- Breakpoints: toggle/set/remove, conditions, and project persistence.
--
-- Uses the real nvim-dap breakpoint store (signs + conditions) but needs no
-- debug adapter or session. Persistence is checked by writing a throwaway
-- `.orch` project and reloading it.

local here = vim.fn.fnamemodify(debug.getinfo(1, "S").source:sub(2), ":p:h")
package.path = here .. "/?.lua;" .. package.path
local h = require("harness")

local dap_root
do
    local roots = {}
    if vim.env.ORCHLAUNCH_DEPS and vim.env.ORCHLAUNCH_DEPS ~= "" then
        roots[#roots + 1] = vim.env.ORCHLAUNCH_DEPS
    end
    roots[#roots + 1] = vim.fn.stdpath("data") .. "/lazy"
    roots[#roots + 1] = vim.fn.stdpath("data") .. "/site/pack/deps/start"
    roots[#roots + 1] = vim.fn.stdpath("data") .. "/site/pack/core/opt"
    for _, root in ipairs(roots) do
        if vim.fn.isdirectory(root .. "/nvim-dap") == 1 then
            dap_root = root .. "/nvim-dap"
            break
        end
    end
end

if not dap_root then
    print("SKIP  breakpoints: need nvim-dap")
    h.done("breakpoints (skipped)")
    return
end

vim.opt.rtp:append(dap_root)
require("dap")

local root = h.tempdir()
h.write(root .. "/prog.cpp", [[
int compute(int i) {
    int doubled = i * 2;
    return doubled;
}
int main() {
    return compute(3);
}
]])

local orch = require("orchlaunch")
orch.create_project(root)

local breakpoints = require("orchlaunch.breakpoints")

-- 1. toggle --------------------------------------------------------------------
breakpoints.toggle_at("prog.cpp", 2)
h.check("toggle set a breakpoint", breakpoints.has(vim.fn.bufadd(root .. "/prog.cpp"), 2))
h.eq("one breakpoint listed", #breakpoints.list(), 1)
h.eq("breakpoint is project-relative", breakpoints.list()[1].file, "prog.cpp")

breakpoints.toggle_at("prog.cpp", 2)
h.check("toggle removed the breakpoint", not breakpoints.has(vim.fn.bufadd(root .. "/prog.cpp"), 2))
h.eq("no breakpoints after toggle off", #breakpoints.list(), 0)

-- 2. conditions ----------------------------------------------------------------
breakpoints.set_at("prog.cpp", 3, { condition = "i == 3" })
local conditioned = breakpoints.list()[1]
h.check("conditional breakpoint listed", conditioned ~= nil)
h.eq("condition stored", conditioned and conditioned.condition, "i == 3")
h.contains("label shows the condition", breakpoints.label(conditioned), "if i == 3")

breakpoints.set_at("prog.cpp", 4, { log_message = "i is {i}" })
local logged = nil
for _, bp in ipairs(breakpoints.list()) do
    if bp.line == 4 then
        logged = bp
    end
end
h.eq("log message stored", logged and logged.log_message, "i is {i}")

-- 3. remove --------------------------------------------------------------------
h.check("remove_at removes a line", breakpoints.remove_at("prog.cpp", 4))
for _, bp in ipairs(breakpoints.list()) do
    h.check("removed breakpoint is gone", bp.line ~= 4)
end

-- 4. persistence ---------------------------------------------------------------
local record_file = root .. "/.orch/breakpoints.json"
h.eq("breakpoints file written", vim.fn.filereadable(record_file), 1)
local raw = require("orchlaunch.config").load(record_file)
h.eq("one persisted record", #(raw.breakpoints or {}), 1)
h.eq("persisted condition", raw.breakpoints and raw.breakpoints[1].condition, "i == 3")
h.eq("persisted file is relative", raw.breakpoints and raw.breakpoints[1].file, "prog.cpp")

-- Simulate a fresh editor: drop in-memory breakpoints, reload the project, and
-- let the module restore them from disk.
require("dap.breakpoints").clear()
h.eq("breakpoints cleared in memory", #breakpoints.list(), 0)

require("orchlaunch.state").reset()
orch.create_project(root)
local applied = breakpoints.load()
h.eq("persisted breakpoint re-applied", applied, 1)
local restored = breakpoints.list()[1]
h.eq("restored line", restored and restored.line, 3)
h.eq("restored condition", restored and restored.condition, "i == 3")

-- 5. clear ---------------------------------------------------------------------
breakpoints.clear()
h.eq("clear empties memory", #breakpoints.list(), 0)
local after = require("orchlaunch.config").load(record_file)
h.eq("clear empties the file", #(after.breakpoints or {}), 0)

h.done("breakpoints")
