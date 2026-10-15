local here = vim.fn.fnamemodify(debug.getinfo(1, "S").source:sub(2), ":p:h")
package.path = here .. "/?.lua;" .. package.path
require("harness")

local root = vim.fn.tempname(); vim.fn.mkdir(root, "p")
vim.cmd("cd " .. root)
local orch = require("orchlaunch"); local state = require("orchlaunch.state"); local config = require("orchlaunch.config")
orch.create_project(root)
state.add_toolchain(config.toolchain({ name="Clang", type="system", cmake="cmake", c="clang", cxx="clang++", debugger="lldb" }))
state.set_cmake_settings(config.cmake_settings({
  toolchain="Clang", generator="Ninja", build_type="Debug", build_dir="${workspace}/build",
  configure_args={"-DFOO=1"}, definitions={ CMAKE_EXPORT_COMPILE_COMMANDS="ON" }, environment={ CC="clang" },
}))
state.add_configuration(config.native({ name="Game", target="/bin/echo", before=config.before({ config.external("gen") }) }))
state.save()
-- idempotency: load -> save -> compare
state.reload(); state.save()
local file = io.open(root.."/.orch/cmake_settings.json"):read("*a")
print(file)
state.reload()
assert(state.cmake_settings().generator == "Ninja", "generator lost")
assert(state.cmake_settings().definitions.CMAKE_EXPORT_COMPILE_COMMANDS == "ON", "definition lost")
assert(state.require_configuration("Game").before.tools[1].tool == "gen", "before lost")
print("CMake round trip: OK")
