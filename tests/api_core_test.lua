local here = vim.fn.fnamemodify(debug.getinfo(1, "S").source:sub(2), ":p:h")
package.path = here .. "/?.lua;" .. package.path
require("harness")

local function fail(msg)
    io.stderr:write("FAIL: " .. msg .. "\n")
    os.exit(1)
end

local function ok(msg)
    io.stdout:write("ok: " .. msg .. "\n")
end

local ws = vim.fn.tempname()
vim.fn.delete(ws, "rf")
vim.fn.mkdir(ws, "p")

local project = require("orchlaunch.project")
local state = require("orchlaunch.state")
local config = require("orchlaunch.config")
local process = require("orchlaunch.process")

-- 1. create project ---------------------------------------------------------
assert(project.create(ws) == true, "create returned false")
for _, f in ipairs({ "run_configurations.json", "external_tools.json", "toolchain.json", "cmake_settings.json" }) do
    assert(vim.fn.filereadable(ws .. "/.orch/" .. f) == 1, "missing " .. f)
    -- every scaffolded file is valid JSON
    local text = table.concat(vim.fn.readfile(ws .. "/.orch/" .. f), "\n")
    assert(type(vim.json.decode(text)) == "table", "invalid JSON in " .. f)
end
ok("project scaffolding")

-- 2. setup ----------------------------------------------------------------
local s = state.setup(ws)
assert(s.root == vim.fs.normalize(ws), "root mismatch: " .. s.root)
ok("state.setup")

-- 3. populate -------------------------------------------------------------
state.add_toolchain(config.toolchain({
    name = "Clang",
    type = "system",
    cmake = "cmake",
    c = "clang",
    cxx = "clang++",
    debugger = "lldb",
}))

state.add_external_tool(config.external_tool({
    name = "gen-assets",
    program = "${workspace}/tools/gen",
    args = { "--release" },
    cwd = "${workspace}",
}))

state.add_configuration(config.native({
    name = "Game",
    target = "game",
    cwd = "${workspace}",
    args = { "-dev", "-console" },
    environment = { GAME_DEBUG = "1" },
    console = config.console({ mode = "embedded", keep_open = true, clear_on_start = true }),
    before = config.before({ config.build(), config.external("gen-assets") }),
}))

state.add_configuration(config.remote_debug({
    name = "Remote",
    symbol = "game",
    connection = "localhost:1234",
    adapter = "lldb",
}))

state.add_configuration(config.compound({ name = "All", configurations = { "Game", "Remote" } }))

state.set_cmake_settings(config.cmake_settings({
    toolchain = "Clang",
    generator = "Ninja",
    build_type = "Debug",
    build_dir = "${workspace}/build",
    definitions = { CMAKE_EXPORT_COMPILE_COMMANDS = "ON" },
}))

-- runtime data must stay out of the files
state.set_runtime("targets", { "game", "engine" })

state.save()
ok("state.save")

-- 4. verify files -----------------------------------------------------------
local function read_json(rel)
    local text = table.concat(vim.fn.readfile(ws .. "/.orch/" .. rel), "\n")
    local ok, doc = pcall(vim.json.decode, text)
    assert(ok and type(doc) == "table", "invalid JSON in " .. rel .. ": " .. tostring(doc))
    return doc, text
end

local run, run_text = read_json("run_configurations.json")
local ext = read_json("external_tools.json")
local tc = read_json("toolchain.json")
local cm, cm_text = read_json("cmake_settings.json")

assert(type(run.configurations) == "table" and #run.configurations == 3, "run: expected 3 configurations")
local game_cfg = run.configurations[1]
assert(game_cfg.name == "Game", "run: Game missing")
assert(game_cfg.environment.GAME_DEBUG == "1", "run: env value missing")
assert(game_cfg.console.mode == "embedded", "run: console missing")
assert(game_cfg.before.tools[1] == "build", "run: before build missing")
assert(type(game_cfg.before.tools[2]) == "table" and game_cfg.before.tools[2].type == "external", "run: before external spec missing")
assert(run.configurations[2].type == "remote-debug", "run: remote-debug missing")
assert(type(ext.tools) == "table" and #ext.tools == 1, "ext: tools missing")
assert(type(tc.toolchains) == "table" and #tc.toolchains == 1, "tc: toolchains missing")
assert(type(cm.cmake) == "table", "cmake: cmake section missing")
assert(cm.cmake.profiles[1].definitions.CMAKE_EXPORT_COMPILE_COMMANDS == "ON", "cmake: definitions missing")
assert(not run_text:find("targets", 1, true), "run: runtime data leaked")
assert(not cm_text:find("targets", 1, true), "cmake: runtime targets leaked")
ok("serialized files")
io.stdout:write("\n----- run_configurations.json -----\n" .. run_text .. "\n----- cmake_settings.json -----\n" .. cm_text .. "\n")

-- 5. reload round-trip ------------------------------------------------------
state.reset()
state.setup(ws)
local game = state.require_configuration("Game")
assert(game.type == "native", "game type")
assert(game.args[1] == "-dev" and game.args[2] == "-console", "args round-trip")
assert(game.environment.GAME_DEBUG == "1", "env round-trip")
assert(game.console.mode == "embedded", "console round-trip")
assert(game.before.tools[1] == "build", "before string round-trip")
assert(type(game.before.tools[2]) == "table" and game.before.tools[2].tool == "gen-assets", "before table round-trip")
assert(#state.toolchains().toolchains == 1, "toolchain count")
assert(#state.external_tools().tools == 1, "tool count")
assert(state.cmake_settings().build_type == "Debug", "cmake round-trip")
assert(state.cmake_settings().definitions.CMAKE_EXPORT_COMPILE_COMMANDS == "ON", "cmake def round-trip")
ok("reload round-trip")

-- 6. process -----------------------------------------------------------------
local res = process.run({ program = "echo", args = { "hello" } })
assert(res.code == 0, "process code " .. tostring(res.code))
assert((res.stdout or ""):find("hello"), "process stdout: " .. tostring(res.stdout))
ok("process.run")

io.stdout:write("\nALL TESTS PASSED\n")
