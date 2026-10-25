-- Semantic validation: every rule, with exact line numbers, on pure text and
-- through real buffers. Regression: the old line-based scanner found no
-- configurations in a normally formatted file, so no diagnostic ever appeared.

local here = vim.fn.fnamemodify(debug.getinfo(1, "S").source:sub(2), ":p:h")
package.path = here .. "/?.lua;" .. package.path
local h = require("harness")

local validate = require("orchlaunch.validate")
local SEV = vim.diagnostic.severity

---@param diagnostics OrchDiagnostic[]
local function find(diagnostics, fragment, severity)
    for _, d in ipairs(diagnostics) do
        if d.message:find(fragment, 1, true) and (severity == nil or d.severity == severity) then
            return d
        end
    end
end

local function ctx(extra)
    return vim.tbl_extend("force", {
        targets = { app = true, lib = true },
        toolchains = { gcc = true },
        tools = { fmt = true },
    }, extra or {})
end

-- ---- run_configurations: one rule at a time --------------------------------
local doc = table.concat({
    "{",                                                                         -- 0
    '  "configurations": [',                                                     -- 1
    '    { "name": "Dup", "type": "native", "target": "app" },',                 -- 2
    '    { "name": "Dup", "type": "native", "target": "app" },',                 -- 3
    '    { "name": "Ghost", "type": "native", "target": "nope" },',              -- 4
    '    { "name": "Self", "type": "compound", "configurations": ["Self"] },',   -- 5
    '    { "name": "P", "type": "compound", "configurations": ["Q"] },',         -- 6
    '    { "name": "Q", "type": "compound", "configurations": ["P"] },',         -- 7
    '    { "name": "Missing", "type": "compound", "configurations": ["Nobody"] },', -- 8
    '    { "name": "Sudo", "type": "native", "target": "app", "sudo": true,',    -- 9
    '      "console": { "mode": "hidden" } },',                                  -- 10
    '    { "name": "Empty", "type": "native" },',                                -- 11
    '    { "name": "Remote", "type": "remote-debug" },',                         -- 12
    '    { "name": "Weird", "type": "teleport" },',                              -- 13
    '    { "name": "Steps", "type": "native", "target": "app", "before": {',     -- 14
    '        "tools": [ { "type": "external", "tool": "ghost-tool" },',          -- 15
    '                   { "type": "build", "target": "ghost-target" } ] } },',   -- 16
    '    { "name": "Path", "type": "native", "target": "/bin/echo" },',          -- 17
    "  ]",                                                                       -- 18 (trailing comma fixed below)
    "}",
}, "\n"):gsub('"/bin/echo" },\n  ]', '"/bin/echo" }\n  ]')

local d = validate.check("run_configurations", doc, ctx())

local dup = {}
for _, x in ipairs(d) do
    if x.message:find("Duplicate configuration name: Dup", 1, true) then
        dup[#dup + 1] = x.lnum
    end
end
table.sort(dup)
h.eq("duplicate name is reported on both entries", vim.inspect(dup), vim.inspect({ 2, 3 }))
h.eq("duplicate is an ERROR", find(d, "Duplicate configuration name", SEV.ERROR) ~= nil, true)

local ghost = find(d, "CMake target not found: nope", SEV.WARN)
h.check("unknown target is a WARN", ghost ~= nil, vim.inspect(d))
h.eq("unknown target points at its line", ghost and ghost.lnum, 4)
h.check("unknown target points at the value", ghost and ghost.col > 30, ghost and ghost.col)

local self_cycle = find(d, "cycle: Self -> Self", SEV.ERROR)
h.check("self reference is a cycle", self_cycle ~= nil, vim.inspect(d))
h.eq("self cycle line", self_cycle and self_cycle.lnum, 5)
local p_cycle = find(d, "cycle: P -> Q -> P", SEV.ERROR)
h.check("two-step cycle is reported with its chain", p_cycle ~= nil, vim.inspect(d))
h.eq("two-step cycle line", p_cycle and p_cycle.lnum, 6)
h.check("the other side of the cycle too", find(d, "cycle: Q -> P -> Q", SEV.ERROR) ~= nil)

local missing = find(d, "unknown configuration: Nobody", SEV.ERROR)
h.check("compound with an unknown child is an ERROR", missing ~= nil)
h.eq("unknown child line", missing and missing.lnum, 8)

local sudo = find(d, "sudo is incompatible", SEV.WARN)
h.check("sudo + hidden console warns", sudo ~= nil)
h.eq("sudo diagnostic is on the sudo line", sudo and sudo.lnum, 9)

local empty = find(d, "has no target, no runtime", SEV.INFO)
h.check("empty native is an INFO", empty ~= nil)
h.eq("empty native line", empty and empty.lnum, 11)

local remote = find(d, "requires 'connection'", SEV.ERROR)
h.check("remote-debug without connection is an ERROR", remote ~= nil)
h.eq("remote-debug line", remote and remote.lnum, 12)

local weird = find(d, "Unknown configuration type: teleport", SEV.WARN)
h.check("unknown type warns", weird ~= nil)
h.eq("unknown type line", weird and weird.lnum, 13)

local tool = find(d, "unknown external tool: ghost-tool", SEV.WARN)
h.check("before-launch unknown external tool warns", tool ~= nil)
h.eq("unknown tool line", tool and tool.lnum, 15)
local step_target = find(d, "unknown CMake target: ghost-target", SEV.WARN)
h.check("before-launch unknown build target warns", step_target ~= nil)
h.eq("unknown build target line", step_target and step_target.lnum, 16)

h.eq("path-like targets are accepted", find(d, "/bin/echo"), nil)
h.eq("known targets are accepted", find(d, "target not found: app"), nil)

-- targets unknown (no CMake model yet): HINT, never an error or warning
local d_unknown = validate.check("run_configurations", doc, ctx({ targets = vim.NIL }) and { targets = nil, toolchains = {}, tools = { fmt = true } })
local hint = find(d_unknown, "Cannot verify target", SEV.HINT)
h.check("unloaded CMake model gives a HINT", hint ~= nil, vim.inspect(d_unknown))
h.eq("no 'not found' warning without a model", find(d_unknown, "CMake target not found"), nil)

-- ---- no false positives on valid documents -------------------------------
local clean = [[{
  "configurations": [
    { "name": "A", "type": "native", "target": "app" },
    { "name": "B", "type": "native", "target": "lib", "console": { "mode": "embedded" } },
    { "name": "All", "type": "compound", "configurations": ["A", "B"] },
    { "name": "Nested", "type": "compound", "configurations": ["All", "A"] },
    { "name": "Rem", "type": "remote-debug", "connection": "localhost:1234" },
    { "name": "Steps", "type": "native", "target": "app",
      "before": { "tools": [ { "type": "build", "target": "app" }, { "type": "external", "tool": "fmt" } ] } }
  ]
}]]
h.eq("a valid document has no diagnostics", #validate.check("run_configurations", clean, ctx()), 0)

local diamond = [[{ "configurations": [
  { "name": "Leaf", "type": "native", "target": "app" },
  { "name": "L", "type": "compound", "configurations": ["Leaf"] },
  { "name": "R", "type": "compound", "configurations": ["Leaf"] },
  { "name": "Top", "type": "compound", "configurations": ["L", "R"] } ] }]]
h.eq("a diamond is not a cycle", #validate.check("run_configurations", diamond, ctx()), 0)

for _, name in ipairs({ "run_configurations", "external_tools", "toolchain", "cmake_settings" }) do
    local path = here .. "/fixtures/" .. name .. ".json"
    if vim.fn.filereadable(path) == 1 then
        local result = validate.check(name, h.read(path), {
            targets = nil,
            toolchains = setmetatable({}, { __index = function() return true end }),
            tools = setmetatable({}, { __index = function() return true end }),
        })
        local serious = vim.tbl_filter(function(x)
            return x.severity <= SEV.WARN
        end, result)
        h.eq("fixture " .. name .. " has no errors or warnings", #serious, 0)
    end
end

-- ---- syntax errors -----------------------------------------------------------
local bad = validate.check("run_configurations", '{\n  "configurations": [\n    { "name": }\n  ]\n}', ctx())
h.eq("syntax error gives exactly one diagnostic", #bad, 1)
h.eq("syntax error is an ERROR", bad[1].severity, SEV.ERROR)
h.eq("syntax error points at the offending line", bad[1].lnum, 2)
h.check("syntax error message", bad[1].message:find("JSON syntax error", 1, true) ~= nil)
h.eq("top-level array is rejected", #validate.check("toolchain", "[]", ctx()), 1)

-- ---- external tools / toolchains / cmake settings ---------------------------
local tools = validate.check("external_tools", [[{
  "tools": [
    { "name": "a", "program": "x" },
    { "name": "a", "program": "y" },
    { "name": "np" }
  ]
}]], ctx())
h.check("duplicate tool names", find(tools, "Duplicate external tool name: a", SEV.ERROR) ~= nil, vim.inspect(tools))
local noprog = find(tools, "requires 'program'", SEV.ERROR)
h.check("tool without program", noprog ~= nil)
h.eq("tool without program line", noprog and noprog.lnum, 4)

local tcs = validate.check("toolchain", [[{
  "toolchains": [
    { "name": "g", "type": "unix", "cmake": "cmake", "c": "gcc", "cxx": "g++", "debugger": "gdb" },
    { "name": "g", "type": "weird", "cmake": "cmake", "c": "gcc", "cxx": "g++" }
  ]
}]], ctx())
h.check("duplicate toolchain names", find(tcs, "Duplicate toolchain name: g", SEV.ERROR) ~= nil, vim.inspect(tcs))
local nodbg = find(tcs, "requires 'debugger'", SEV.ERROR)
h.check("toolchain missing a required field", nodbg ~= nil)
h.eq("toolchain missing field line", nodbg and nodbg.lnum, 3)
h.check("unknown toolchain type", find(tcs, "Unknown toolchain type: weird", SEV.WARN) ~= nil)

local cm = validate.check("cmake_settings", [[{
  "cmake": {
    "active": "ghost",
    "profiles": [
      { "name": "dbg", "toolchain": "gcc" },
      { "name": "rel", "toolchain": "clang" },
      { "name": "rel" }
    ]
  }
}]], ctx())
local tcref = find(cm, "references unknown toolchain: clang", SEV.WARN)
h.check("profile with unknown toolchain", tcref ~= nil, vim.inspect(cm))
h.eq("unknown toolchain points at the value line", tcref and tcref.lnum, 5)
h.check("duplicate profile names", find(cm, "Duplicate CMake profile name: rel", SEV.ERROR) ~= nil)
h.check("unknown active profile", find(cm, "Active profile does not exist: ghost", SEV.WARN) ~= nil)
h.eq("known toolchain is accepted", find(cm, "unknown toolchain: gcc"), nil)

-- ---- through real buffers ------------------------------------------------------
local messages = {}
vim.notify = function(msg)
    messages[#messages + 1] = tostring(msg)
end

local orch = require("orchlaunch")
local root = h.tempdir()
orch.setup({ root = root, silent = true })
orch.create_project(root)

-- validation must never spawn CMake
local runner = require("orchlaunch.runner")
local spawned = false
runner.load_cmake = function()
    spawned = true
end
runner.load_cmake_async = function()
    spawned = true
end

local path = root .. "/.orch/run_configurations.json"
h.write(path, doc)
vim.cmd("OrchLaunchReload")
vim.cmd("silent! %bwipeout!")
vim.cmd("edit " .. vim.fn.fnameescape(path))
local bufnr = vim.api.nvim_get_current_buf()

local shown = validate.validate_buffer(bufnr)
h.check("validate_buffer returns the diagnostics", type(shown) == "table" and #shown > 0)
h.eq("diagnostics are published on the buffer", #vim.diagnostic.get(bufnr), #shown)
h.eq("validation did not spawn CMake", spawned, false)

-- a document that is valid in a project without CMake model / tools
local clean_buf = [[{
  "configurations": [
    { "name": "A", "type": "native", "target": "/bin/echo" },
    { "name": "All", "type": "compound", "configurations": ["A"] }
  ]
}]]

-- it validates the live buffer, not the file on disk
vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, vim.split(clean_buf, "\n"))
validate.validate_buffer(bufnr)
h.eq("unsaved buffer content is what gets validated", #vim.diagnostic.get(bufnr), 0)

-- :write -> BufWritePost -> diagnostics (and a reload of the project state)
vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, vim.split(doc, "\n"))
vim.cmd("silent write")
vim.wait(500, function()
    return #vim.diagnostic.get(bufnr) > 0
end, 20)
h.check("writing the buffer publishes diagnostics", #vim.diagnostic.get(bufnr) > 0)
local on_buffer = {}
for _, x in ipairs(vim.diagnostic.get(bufnr)) do
    if x.message:find("cycle: Self -> Self", 1, true) then
        on_buffer[#on_buffer + 1] = x.lnum
    end
end
h.eq("buffer diagnostic carries the right line", on_buffer[1], 5)
h.eq("diagnostics use the orchlaunch source", vim.diagnostic.get(bufnr)[1].source, "orchlaunch")

-- fixing the file and saving clears them
vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, vim.split(clean_buf, "\n"))
vim.cmd("silent write")
vim.wait(500, function()
    return #vim.diagnostic.get(bufnr) == 0
end, 20)
h.eq("saving a fixed file clears the diagnostics", #vim.diagnostic.get(bufnr), 0)

-- typing triggers the debounced validation
vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, vim.split(doc, "\n"))
vim.api.nvim_exec_autocmds("TextChanged", { buffer = bufnr })
vim.wait(1500, function()
    return #vim.diagnostic.get(bufnr) > 0
end, 20)
h.check("TextChanged triggers debounced validation", #vim.diagnostic.get(bufnr) > 0)

-- broken JSON in the buffer: one syntax diagnostic, no raise
vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, { "{", '  "configurations": [', "  oops", "}" })
h.ok("validating broken JSON does not raise", function()
    validate.validate_buffer(bufnr)
end)
h.eq("broken JSON gives one diagnostic", #vim.diagnostic.get(bufnr), 1)

-- unrelated buffers are left alone
vim.cmd("enew")
h.eq("non-orch buffers are ignored", validate.validate_buffer(vim.api.nvim_get_current_buf()), nil)

validate.clear_diagnostics(bufnr)
h.eq("clear_diagnostics empties the buffer", #vim.diagnostic.get(bufnr), 0)

h.done("semantic validation")
