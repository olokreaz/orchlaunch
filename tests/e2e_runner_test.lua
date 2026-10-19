-- End-to-end test: the run/debug dispatch layer.
--
-- Exercises every launch path of `orchlaunch.runner`:
--   * native run with resolved args / environment / working directory
--   * `inherit_env` handling
--   * console modes (none, hidden, embedded)
--   * native debug + remote-debug dispatch into the debug layer
--   * compound configurations
--   * before-launch external tools and ordering
--   * before-launch build of a real CMake target
--   * active-configuration dispatch and external tool execution
--
-- These tests assert the behaviour the plugin promises; a failure is either a
-- wrong contract here or a broken implementation.

local here = vim.fn.fnamemodify(debug.getinfo(1, "S").source:sub(2), ":p:h")
package.path = here .. "/?.lua;" .. package.path
local h = require("harness")

-- Capture notifications instead of printing them.
local messages = {}
vim.notify = function(msg)
    messages[#messages + 1] = tostring(msg)
end

local function clear_msgs()
    messages = {}
end

local function saw(fragment)
    for _, msg in ipairs(messages) do
        if msg:find(fragment, 1, true) then
            return true
        end
    end
    return false
end

local function wait_for(cond, timeout)
    return vim.wait(timeout or 5000, cond, 20)
end

local function script(path, body)
    h.write(path, "#!/bin/sh\n" .. body .. "\n")
    vim.fn.setfperm(path, "rwxr-xr-x")
    return path
end

local root = h.tempdir()
local work = root .. "/work"
vim.fn.mkdir(work, "p")

local orch = require("orchlaunch")
local state = require("orchlaunch.state")
local config = require("orchlaunch.config")
local runner = require("orchlaunch.runner")

orch.create_project(root)

-- A program that records its execution context.
local runme = script(root .. "/runme.sh", [[
{
  echo "cwd=$PWD"
  echo "args=$*"
  echo "FOO=$FOO"
  echo "HOME_SET=${HOME:+yes}"
  echo "ONLY=${ONLY:-}"
} > "$OUT"
]])
local append = script(root .. "/append.sh", 'echo run >> "$LOG"')

-- ============================================================================
-- 1. native run: args / env / cwd
-- ============================================================================
local out1 = root .. "/out1.txt"
state.add_configuration(config.native({
    name = "Ctx",
    target = runme,
    cwd = work,
    args = { "alpha", "beta" },
    environment = { OUT = out1, FOO = "bar" },
    console = config.console({ mode = "none" }),
}))
state.save()

runner.run("Ctx", { mode = "run" })
wait_for(function()
    return vim.fn.filereadable(out1) == 1
end)

local recorded = vim.fn.filereadable(out1) == 1 and h.read(out1) or ""
h.contains("native run executed", recorded, "cwd=" .. vim.fs.normalize(work))
h.contains("args passed verbatim", recorded, "args=alpha beta")
h.contains("environment applied", recorded, "FOO=bar")
h.contains("environment inherited", recorded, "HOME_SET=yes")

-- ============================================================================
-- 2. inherit_env = false clears the environment
-- ============================================================================
local out2 = root .. "/out2.txt"
state.add_configuration(config.native({
    name = "Isolated",
    target = runme,
    cwd = work,
    environment = { OUT = out2, FOO = "baz" },
    inherit_env = false,
    console = config.console({ mode = "none" }),
}))
state.save()
runner.run("Isolated")
wait_for(function()
    return vim.fn.filereadable(out2) == 1
end)
local isolated = vim.fn.filereadable(out2) == 1 and h.read(out2) or ""
h.contains("explicit env still applied", isolated, "FOO=baz")
h.contains("inherited env cleared", isolated, "HOME_SET=")
h.check("inherited HOME absent", not isolated:find("HOME_SET=yes", 1, true))

-- ============================================================================
-- 3. console modes
-- ============================================================================
-- hidden -> asynchronous completion notification
clear_msgs()
local out3 = root .. "/out3.txt"
state.add_configuration(config.native({
    name = "Hidden", target = runme, cwd = work,
    environment = { OUT = out3 }, console = config.console({ mode = "hidden" }),
}))
state.save()
runner.run("Hidden")
wait_for(function()
    return saw("finished with code 0")
end)
h.check("hidden console reports completion", saw("finished with code 0"), vim.inspect(messages))

-- none -> no completion notification
clear_msgs()
local out4 = root .. "/out4.txt"
state.add_configuration(config.native({
    name = "Silent", target = runme, cwd = work,
    environment = { OUT = out4 }, console = config.console({ mode = "none" }),
}))
state.save()
runner.run("Silent")
wait_for(function()
    return vim.fn.filereadable(out4) == 1
end)
vim.wait(200)
h.check("none console stays silent", not saw("finished with code"), vim.inspect(messages))

-- embedded -> opens a terminal buffer
local out5 = root .. "/out5.txt"
state.add_configuration(config.native({
    name = "Embedded", target = runme, cwd = work,
    environment = { OUT = out5 }, console = config.console({ mode = "embedded" }),
}))
state.save()
local embedded_ok, embedded_err = pcall(function()
    runner.run("Embedded")
end)
h.check("embedded console launches without error", embedded_ok, embedded_err)
wait_for(function()
    return vim.fn.filereadable(out5) == 1
end)
h.check("embedded console ran the program", vim.fn.filereadable(out5) == 1)

-- ============================================================================
-- 4. debug + remote-debug guidance
-- ============================================================================
clear_msgs()
state.add_configuration(config.remote_debug({
    name = "Attach", symbol = "hello", connection = "localhost:1234", adapter = "gdb",
}))
state.save()

runner.run("Ctx", { mode = "debug" })
h.check("native debug triggers debug path", saw("nvim-dap is not installed") or #messages > 0, vim.inspect(messages))

clear_msgs()
runner.run("Attach", { mode = "run" })
h.check("remote-debug refuses run mode", saw("only available in debug mode"), vim.inspect(messages))

clear_msgs()
runner.run("Attach", { mode = "debug" })
h.check("remote-debug debug triggers debug path", saw("nvim-dap is not installed") or #messages > 0, vim.inspect(messages))

-- ============================================================================
-- 5. compound configurations
-- ============================================================================
local out6 = root .. "/out6.txt"
local out7 = root .. "/out7.txt"
state.add_configuration(config.native({
    name = "One", target = runme, cwd = work, environment = { OUT = out6, FOO = "1" }, console = config.console({ mode = "none" }),
}))
state.add_configuration(config.native({
    name = "Two", target = runme, cwd = work, environment = { OUT = out7, FOO = "2" }, console = config.console({ mode = "none" }),
}))
state.add_configuration(config.compound({ name = "Both", configurations = { "One", "Two" } }))
state.save()

runner.run("Both")
wait_for(function()
    return vim.fn.filereadable(out6) == 1 and vim.fn.filereadable(out7) == 1
end)
h.check("compound ran first child", vim.fn.filereadable(out6) == 1)
h.check("compound ran second child", vim.fn.filereadable(out7) == 1)

-- ============================================================================
-- 6. before-launch external tools + ordering
-- ============================================================================
local log = root .. "/order.log"
local ext = root .. "/ext.sh"
state.add_external_tool(config.external_tool({
    name = "mark", program = ext, environment = { LOG = log },
}))
h.write(ext, "#!/bin/sh\necho ext >> \"$LOG\"\n")
vim.fn.setfperm(ext, "rwxr-xr-x")

state.add_configuration(config.native({
    name = "Ordered",
    target = append,
    cwd = work,
    environment = { LOG = log },
    console = config.console({ mode = "none" }),
    before = config.before({ config.external("mark") }),
}))
state.save()

runner.run("Ordered")
wait_for(function()
    return vim.fn.filereadable(log) == 1 and h.read(log):find("run", 1, true) ~= nil
end)
h.eq("before-launch external ran before the program", vim.fn.filereadable(log) == 1 and h.read(log) or "", "ext\nrun\n")

-- remote-debug runs before-launch actions before attaching
local remote_log = root .. "/remote.log"
local ext2 = root .. "/ext2.sh"
state.add_external_tool(config.external_tool({ name = "mark2", program = ext2, environment = { LOG = remote_log } }))
h.write(ext2, "#!/bin/sh\necho ext >> \"$LOG\"\n")
vim.fn.setfperm(ext2, "rwxr-xr-x")
state.add_configuration(config.remote_debug({
    name = "AttachBefore",
    connection = "localhost:1234",
    adapter = "gdb",
    before = config.before({ config.external("mark2") }),
}))
state.save()

clear_msgs()
runner.run("AttachBefore", { mode = "debug" })
h.check(
    "remote-debug ran before-launch actions",
    vim.fn.filereadable(remote_log) == 1 and h.read(remote_log) == "ext\n",
    vim.inspect(messages)
)

-- unknown external tool aborts before running the program
local log2 = root .. "/order2.log"
h.write(log2, "")
state.add_configuration(config.native({
    name = "BadBefore",
    target = append,
    cwd = work,
    environment = { LOG = log2 },
    console = config.console({ mode = "none" }),
    before = config.before({ config.external("does-not-exist") }),
}))
state.save()
clear_msgs()
runner.run("BadBefore")
vim.wait(200)
h.check("unknown before-launch tool reports an error", saw("unknown external tool"), vim.inspect(messages))
h.eq("program did not run after a failed before-launch step", vim.fn.filereadable(log2) == 1 and h.read(log2) or "", "")

-- ============================================================================
-- 7. before-launch build of a real CMake target
-- ============================================================================
local proj = h.tempdir()
h.write(proj .. "/CMakeLists.txt", [[
cmake_minimum_required(VERSION 3.16)
project(bl C)
add_executable(hello main.c)
]])
h.write(proj .. "/main.c", [[
#include <stdio.h>
#include <stdlib.h>
int main(void) {
  const char *out = getenv("OUT");
  if (out) { FILE *f = fopen(out, "w"); if (f) { fputs("ran\n", f); fclose(f); } }
  return 0;
}
]])
orch.create_project(proj)
state.add_toolchain(config.toolchain({
    name = "Gcc", type = "system", cmake = "cmake", c = "gcc", cxx = "g++", debugger = "gdb",
}))
state.add_cmake_profile(config.cmake_settings({
    name = "Default", toolchain = "Gcc", generator = "Ninja", build_dir = "${workspace}/build",
}))
state.set_active_cmake_profile("Default")
local marker = proj .. "/ran.txt"
state.add_configuration(config.native({
    name = "hello",
    target = "hello",
    environment = { OUT = marker },
    console = config.console({ mode = "none" }),
    before = config.before({ config.build() }),
}))
state.save()

clear_msgs()
runner.run("hello")
wait_for(function()
    return vim.fn.filereadable(marker) == 1
end, 60000)
h.check("before-launch build configured & built the CMake target", vim.fn.filereadable(marker) == 1, vim.inspect(messages))
h.check("built target artifact resolvable", require("orchlaunch.cmake").find_target("hello") ~= nil)

-- ============================================================================
-- 8. active configuration + external tool execution
-- ============================================================================
state.setup(root)
local active = require("orchlaunch.active")
active.set(state.root(), "Ctx")
local dispatched = runner.run_active({ mode = "run" })
h.eq("run_active dispatches the active configuration", dispatched, "Ctx")

clear_msgs()
local tool = runner.run_external_tool("mark")
h.check("run_external_tool returns a result", tool ~= nil and tool.code == 0, tool and tool.stderr)

clear_msgs()
h.eq("run_external_tool unknown returns nil", runner.run_external_tool("nope"), nil)
h.check("unknown external tool reports an error", saw("external tool not found"), vim.inspect(messages))

-- ============================================================================
-- 9. error paths
-- ============================================================================
clear_msgs()
runner.run("NoSuchConfiguration")
h.check("missing configuration reports an error", saw("configuration not found"), vim.inspect(messages))

state.reset()
clear_msgs()
runner.run("Ctx")
h.check("run without a project reports an error", saw("no .orch project loaded"), vim.inspect(messages))

h.done("runner end-to-end")
