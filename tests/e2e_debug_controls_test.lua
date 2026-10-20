-- Real debugger-panel *control* end-to-end test.
--
-- Drives the actual panel buttons the way a user does: it puts the cursor on a
-- button chip ("Step Over", "Step In", …) and sends <CR>. A real lldb-dap
-- session backs the panel, so every assertion reflects the genuine result of
-- the button's action on the debuggee. Skips cleanly without the toolchain.

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

local missing = {}
for _, tool in ipairs({ "clang++", "lldb-dap", "nvim-dap" }) do
    if tool == "nvim-dap" then
        if not dap_root then
            missing[#missing + 1] = tool
        end
    elseif vim.fn.exepath(tool) == "" then
        missing[#missing + 1] = tool
    end
end
if not (pcall(require, "fibrous")) then
    missing[#missing + 1] = "fibrous"
end

if #missing > 0 then
    print("SKIP  debugger controls e2e: missing " .. table.concat(missing, ", "))
    h.done("real debugger controls e2e (skipped)")
    return
end

vim.opt.rtp:append(dap_root)
require("dap")

vim.o.columns = 160
vim.o.lines = 44

local root = h.tempdir()
h.write(root .. "/prog.cpp", [[
#include <cstdio>
#include <unistd.h>

volatile int g;
int helper(int x) {
    g = x + 1;
    return g;
}

int main() {
    int a = 1;
    int b = helper(a);
    std::printf("b=%d\n", b);
    for (int i = 0; i < 100000; i++) {
        g = i;
        usleep(2000);
    }
    return 0;
}
]])

local lines = {}
for n, line in ipairs(vim.fn.readfile(root .. "/prog.cpp")) do
    lines[line:gsub("%s+$", "")] = n
end
local a_line = lines["    int a = 1;"]
local call_line = lines["    int b = helper(a);"]

local exe = root .. "/prog"
local compiled = vim.fn.system({ "clang++", "-g", "-O0", "-o", exe, root .. "/prog.cpp" })
h.eq("program compiles", vim.v.shell_error, 0, compiled)

local breakpoints = require("dap.breakpoints")
local bufnr = vim.fn.bufadd(root .. "/prog.cpp")
vim.fn.bufload(bufnr)
breakpoints.set({}, bufnr, a_line)

-- Show the source in a real window, like a user editing the file. nvim-dap then
-- reuses it to reveal the stopped line instead of touching the panel window.
vim.cmd("edit " .. vim.fn.fnameescape(root .. "/prog.cpp"))

local dbg = require("orchlaunch.debug")
dbg.start(nil, { type = "launch", name = "controls", program = exe, cwd = root })

local function wait_for(pred, ms)
    return vim.wait(ms or 20000, pred, 25)
end

h.check("real session stops at the breakpoint", wait_for(function()
    return dbg.status() == "stopped"
end), dbg.status())
wait_for(function()
    return #dbg.frames() > 0
end)

local panel = require("orchlaunch.ui.fibrous.debugger")
local handle = panel.open()
h.check("panel mounted", handle ~= nil and vim.api.nvim_win_is_valid(handle.winid))
if not handle then
    dbg.stop()
    h.done("real debugger controls e2e")
    return
end

local function screen()
    return table.concat(vim.api.nvim_buf_get_lines(handle.bufnr, 0, -1, false), "\n")
end

-- Press a panel button by placing the cursor on its chip and sending <CR>,
-- exactly like the user. The buttons row is above the footer, so the first
-- occurrence of the label is the button.
local function press(label)
    if not (handle and vim.api.nvim_win_is_valid(handle.winid)) then
        return false
    end
    local buf_lines = vim.api.nvim_buf_get_lines(handle.bufnr, 0, -1, false)
    for i, line in ipairs(buf_lines) do
        local col = line:find(label, 1, true)
        if col then
            vim.api.nvim_set_current_win(handle.winid)
            vim.api.nvim_win_set_cursor(handle.winid, { i, col - 1 })
            -- Let any pending fibrous re-render settle so the key lands on the
            -- button cell that is currently on screen.
            vim.wait(20)
            if not vim.api.nvim_win_is_valid(handle.winid) then
                return false
            end
            vim.api.nvim_set_current_win(handle.winid)
            vim.api.nvim_feedkeys(vim.api.nvim_replace_termcodes("<CR>", true, false, true), "x", false)
            return true
        end
    end
    return false
end

local function frame_line()
    local frame = dbg.current_frame()
    return frame and frame.line
end
local function frame_name()
    local frame = dbg.current_frame()
    return frame and frame.name
end

-- Press a button and wait for its effect; retry once or twice in case a single
-- keypress is swallowed by a panel re-render race.
local function press_until(label, pred, ms)
    for _ = 1, 5 do
        press(label)
        if wait_for(pred, ms or 8000) then
            return true
        end
        vim.wait(100)
    end
    return false
end

h.check("Step Over advances to the call line", press_until("Step Over", function()
    return dbg.status() == "stopped" and frame_line() == call_line
end), frame_line())

h.check("Step In enters helper()", press_until("Step In", function()
    return dbg.status() == "stopped" and (frame_name() or ""):find("helper", 1, true) ~= nil
end), frame_name())

h.check("Step Out returns to main", press_until("Step Out", function()
    return dbg.status() == "stopped" and frame_name() == "main"
end), frame_name())

h.check("Continue resumes the program", press_until("Continue", function()
    return dbg.status() == "running"
end), dbg.status())

h.check("Pause stops the running program", press_until("Pause", function()
    return dbg.status() == "stopped"
end, 8000), dbg.status())

h.check("Restart stops at the breakpoint again", press_until("Restart", function()
    return dbg.status() == "stopped" and frame_line() == a_line
end, 15000), frame_line())

h.check("Stop button found", press("Stop"))
h.check("Stop ends the session", wait_for(function()
    return dbg.status() == "idle"
end, 8000), dbg.status())

h.check("panel reflects the ended session", wait_for(function()
    return screen():find("no active session", 1, true) ~= nil
end, 3000), screen())

h.check("Close button found", press("Close"))
h.check("Close closes the panel", handle.winid == nil or not vim.api.nvim_win_is_valid(handle.winid))

h.done("real debugger controls e2e (lldb + clang++ + fibrous)")
