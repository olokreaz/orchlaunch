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
for _, f in ipairs({ "run_configurations.toml", "external_tools.toml", "toolchain.toml", "cmake_settings.toml" }) do
    assert(vim.fn.filereadable(ws .. "/.orch/" .. f) == 1, "missing " .. f)
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
state.set_runtime("resolved", config.runtime_target("game", ws .. "/build/game"))

state.save()
ok("state.save")

-- 4. verify files -----------------------------------------------------------
local run_text = table.concat(vim.fn.readfile(ws .. "/.orch/run_configurations.toml"), "\n")
local ext_text = table.concat(vim.fn.readfile(ws .. "/.orch/external_tools.toml"), "\n")
local tc_text = table.concat(vim.fn.readfile(ws .. "/.orch/toolchain.toml"), "\n")
local cm_text = table.concat(vim.fn.readfile(ws .. "/.orch/cmake_settings.toml"), "\n")

if not run_text:find("%[%[configurations%]%]") then fail("run: no [[configurations]]\n" .. run_text) end
if not run_text:find('name = "Game"') then fail("run: Game missing\n" .. run_text) end
if not run_text:find("%[configurations%.environment%]") then fail("run: environment section missing\n" .. run_text) end
if not run_text:find('GAME_DEBUG = "1"') then fail("run: env value missing\n" .. run_text) end
if not run_text:find("%[configurations%.console%]") then fail("run: console section missing\n" .. run_text) end
if not run_text:find('type = "remote%-debug"') then fail("run: remote-debug missing\n" .. run_text) end
if not run_text:find('type = "external"') then fail("run: before external spec missing\n" .. run_text) end
if not ext_text:find("%[%[tools%]%]") then fail("ext: no [[tools]]\n" .. ext_text) end
if not tc_text:find("%[%[toolchains%]%]") then fail("tc: no [[toolchains]]\n" .. tc_text) end
if not cm_text:find("%[cmake%]") then fail("cmake: no [cmake]\n" .. cm_text) end
if not cm_text:find("definitions") then fail("cmake: definitions missing\n" .. cm_text) end
if run_text:find("_runtime") then fail("run: leaked _runtime") end
if cm_text:find("targets") then fail("cmake: runtime targets leaked") end
ok("serialized files")
io.stdout:write("\n----- run_configurations.toml -----\n" .. run_text .. "\n----- cmake_settings.toml -----\n" .. cm_text .. "\n")

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

-- 6. runtime marker ---------------------------------------------------------
local doc = { a = 1, rt = config.runtime({ x = 2 }), nested = { _runtime = false, y = 3 } }
local text = config.stringify(doc)
assert(text:find("a = 1"), "runtime: a missing")
assert(text:find("y = 3"), "runtime: nested y missing")
assert(not text:find("x = 2"), "runtime: hidden table leaked")
assert(not text:find("_runtime"), "runtime: key leaked")
ok("runtime marker")

-- 7. process -----------------------------------------------------------------
local res = process.run({ program = "echo", args = { "hello" } })
assert(res.code == 0, "process code " .. tostring(res.code))
assert((res.stdout or ""):find("hello"), "process stdout: " .. tostring(res.stdout))
ok("process.run")

io.stdout:write("\nALL TESTS PASSED\n")
