-- Unit test: the macro vocabulary in config.expand resolves every documented
-- macro, leaves unknown ones untouched, and normalize rewrites only exact
-- absolute matches.
local here = vim.fn.fnamemodify(debug.getinfo(1, "S").source:sub(2), ":p:h")
package.path = here .. "/?.lua;" .. package.path
require("harness")
local config = require("orchlaunch.config")

local failures = 0
local function check(name, ok, detail)
    if ok then
        print("PASS  " .. name)
    else
        failures = failures + 1
        print("FAIL  " .. name .. "  " .. tostring(detail))
    end
end

local ctx = {
    workspace = "/ws/proj",
    orch_dir = "/ws/proj/.orch",
    build_dir = "/ws/proj/build/debug",
    source_dir = "/ws/proj",
    build_type = "Debug",
    toolchain = "Gcc",
    target = "hello",
    target_path = "/ws/proj/build/debug/hello",
}

local function expand(s) return config.expand(s, ctx) end

check("${workspace}", expand("${workspace}") == "/ws/proj")
check("${orch}", expand("${orch}") == "/ws/proj/.orch")
check("${buildDir}", expand("${buildDir}") == "/ws/proj/build/debug")
check("${sourceDir}", expand("${sourceDir}") == "/ws/proj")
check("${buildType}", expand("${buildType}") == "Debug")
check("${toolchain}", expand("${toolchain}") == "Gcc")
check("${target}", expand("${target}") == "hello")
check("${targetPath}", expand("${targetPath}") == "/ws/proj/build/debug/hello")
check("${projectName}", expand("${projectName}") == "proj")
check("unknown macro is kept", expand("${nope}") == "${nope}")
check("mixed text", expand("${buildDir}/${target}") == "/ws/proj/build/debug/hello")

vim.env.ORCH_TEST_VAR = "value42"
check("${env:NAME}", expand("${env:ORCH_TEST_VAR}") == "value42")
check("unset ${env:NAME} is empty", expand("${env:ORCH_UNSET_XYZ}") == "")

if failures > 0 then
    print(("=== %d FAILED ==="):format(failures))
    os.exit(1)
end
print("=== macros: all passed ===")
