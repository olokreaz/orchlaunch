-- Unit test: the CLion-style macros added with exec steps resolve as documented.
local here = vim.fn.fnamemodify(debug.getinfo(1, "S").source:sub(2), ":p:h")
package.path = here .. "/?.lua;" .. package.path
local h = require("harness")
local config = require("orchlaunch.config")

local ctx = {
    workspace = "/ws/proj",
    orch_dir = "/ws/proj/.orch",
    source_dir = "/ws/proj/src",
    target_name = "mylib",
    target_path = "/ws/proj/build/libmylib.a",
}

h.eq("${targetName} resolves for a library", config.expand("${targetName}", ctx), "mylib")
h.eq("${targetDir} is the artifact's directory", config.expand("${targetDir}", ctx), "/ws/proj/build")
h.eq("${sourceParentDir} is the parent of the source dir", config.expand("${sourceParentDir}", ctx), "/ws/proj")
h.eq("${projectDir} aliases the workspace", config.expand("${projectDir}", ctx), "/ws/proj")
h.eq("${userHome} is HOME", config.expand("${userHome}", ctx), vim.env.HOME or "")
h.eq("${tempDir} is the OS temp dir", config.expand("${tempDir}", ctx), vim.uv.os_tmpdir())
h.eq("${osName} is the OS name", config.expand("${osName}", ctx), vim.uv.os_uname().sysname)
h.eq("${tmp} is an alias of ${tempDir}", config.expand("${tmp}", ctx), vim.uv.os_tmpdir())
h.eq("${targetDir} is empty before the artifact exists", config.expand("${targetDir}", { target_path = "" }), "")

h.done("extra macros")
