-- Schema drift test.
--
-- Guards the JSON Schemas in `schemas/` against drifting away from the plugin:
--   1. the schemas are structurally sound;
--   2. the example documents in tests/fixtures validate;
--   3. the validator really rejects wrong documents (so (2) means something);
--   4. every file the plugin itself writes validates (fresh project, after
--      :OrchLaunchNew, after a save/load cycle, after loading CMake);
--   5. enums and list keys in the schemas match what the code accepts.
--
-- Uses tests/jsonschema_lite.lua, so nothing is skipped when Python's
-- `jsonschema` is missing. When it is installed it is used as an independent
-- second opinion on the same documents.

local here = vim.fn.fnamemodify(debug.getinfo(1, "S").source:sub(2), ":p:h")
package.path = here .. "/?.lua;" .. package.path
local h = require("harness")
local lite = require("jsonschema_lite")
local jsonpos = require("orchlaunch.jsonpos")
local config = require("orchlaunch.config")

local root_dir = vim.fs.normalize(here .. "/..")
local NAMES = { "run_configurations", "external_tools", "toolchain", "cmake_settings" }

local schemas = {}
for _, name in ipairs(NAMES) do
    local text = h.read(root_dir .. "/schemas/" .. name .. ".schema.json")
    schemas[name] = vim.json.decode(text)
end

local function errors_for(name, text)
    return lite.validate_text(schemas[name], text)
end

local function valid(label, name, text)
    local errors = errors_for(name, text)
    h.check(label, #errors == 0, lite.format(errors))
end

local function invalid(label, name, text)
    h.check(label, #errors_for(name, text) > 0, "the document was accepted")
end

-- Python's jsonschema, when available, as a cross-check.
local has_python = vim.fn.executable("python3") == 1
    and vim.fn.system({ "python3", "-c", "import jsonschema" }) == "" and vim.v.shell_error == 0
local function python_valid(name, path)
    local out = vim.fn.system({
        "python3",
        "-c",
        "import json,sys,jsonschema;"
            .. "s=json.load(open(sys.argv[1]));"
            .. "jsonschema.Draft7Validator.check_schema(s);"
            .. "jsonschema.validate(json.load(open(sys.argv[2])),s)",
        root_dir .. "/schemas/" .. name .. ".schema.json",
        path,
    })
    return vim.v.shell_error == 0, out
end
if not has_python then
    print("NOTE  python3 jsonschema not found: skipping only the optional cross-check")
end

-- ---- 1. schemas are sound ------------------------------------------------------
for _, name in ipairs(NAMES) do
    local problems = lite.check_schema(schemas[name])
    h.check(("schema %s is structurally sound"):format(name), #problems == 0, table.concat(problems, "; "))
end

-- ---- 2. fixtures validate ------------------------------------------------------
for _, name in ipairs(NAMES) do
    local path = here .. "/fixtures/" .. name .. ".json"
    h.check(("fixture %s exists"):format(name), vim.fn.filereadable(path) == 1)
    valid(("fixture %s validates"):format(name), name, h.read(path))
    if has_python then
        local ok, out = python_valid(name, path)
        h.check(("fixture %s validates (python jsonschema)"):format(name), ok, out)
    end
end

-- ---- 3. the validator has teeth --------------------------------------------------
invalid("tools as an object is rejected", "external_tools", '{ "tools": {} }')
invalid("toolchains as an object is rejected", "toolchain", '{ "toolchains": {} }')
invalid("configurations as an object is rejected", "run_configurations", '{ "configurations": {} }')
invalid("profiles as an object is rejected", "cmake_settings", '{ "cmake": { "profiles": {} } }')
invalid("unknown configuration type", "run_configurations", '{ "configurations": [ { "name": "x", "type": "bogus" } ] }')
invalid("missing name", "run_configurations", '{ "configurations": [ { "type": "native" } ] }')
invalid("wrong console mode", "run_configurations",
    '{ "configurations": [ { "name": "x", "type": "native", "console": { "mode": "popup" } } ] }')
invalid("non-array args", "run_configurations",
    '{ "configurations": [ { "name": "x", "type": "native", "args": "-x" } ] }')
invalid("missing top-level list", "external_tools", "{}")
invalid("broken JSON is rejected", "toolchain", '{ "toolchains": [ ')
valid("empty lists are valid", "run_configurations", '{ "configurations": [] }')
valid("a $schema key is allowed", "toolchain", '{ "$schema": "x", "toolchains": [] }')
valid("unknown keys are preserved/allowed", "cmake_settings", '{ "cmake": { "profiles": [], "future": 1 }, "extra": true }')

-- ---- 4. files written by the plugin validate -------------------------------------
local messages = {}
vim.notify = function(msg)
    messages[#messages + 1] = tostring(msg)
end
vim.ui.input = function(opts, cb)
    cb(table.remove(h.inputs or {}, 1))
end
h.inputs = {}

local orch = require("orchlaunch")
local state = require("orchlaunch.state")
local project = h.tempdir()
orch.setup({ root = project, silent = true })
orch.create_project(project)

local function check_project(label)
    for _, name in ipairs(NAMES) do
        local path = project .. "/.orch/" .. name .. ".json"
        if vim.fn.filereadable(path) == 1 then
            local text = h.read(path)
            valid(("%s: %s validates"):format(label, name), name, text)
            if has_python then
                local ok, out = python_valid(name, path)
                h.check(("%s: %s validates (python jsonschema)"):format(label, name), ok, out)
            end
        end
    end
end

check_project("fresh project")
h.check("fresh project writes [] for empty lists",
    h.read(project .. "/.orch/external_tools.json"):find('"tools": []', 1, true) ~= nil,
    h.read(project .. "/.orch/external_tools.json"))

-- every kind of entry created through the UI
local created = {
    { "native", { "N1" } },
    { "remote-debug", { "R1", "localhost:1234" } },
    { "external_tool", { "T1", "clang-format" } },
    { "toolchain", { "TC1" } },
    { "cmake_profile", { "P1" } },
}
vim.ui.select = function(items, _, cb)
    cb(items[1], 1)
end
for _, case in ipairs(created) do
    h.inputs = vim.deepcopy(case[2])
    vim.cmd("silent! %bwipeout!")
    vim.cmd("OrchLaunchNew " .. case[1])
end
vim.cmd("silent! %bwipeout!")
h.inputs = { "Combo" }
vim.cmd("OrchLaunchNew compound")
check_project("after OrchLaunchNew")

-- save -> reload -> save keeps the files valid and stable
state.save()
local before_text = h.read(project .. "/.orch/run_configurations.json")
vim.cmd("OrchLaunchReload")
state.save()
check_project("after save/load/save")
h.eq("save/load/save is stable", h.read(project .. "/.orch/run_configurations.json"), before_text)

-- an old file with `{}` for empty lists still loads and is migrated to []
h.write(project .. "/.orch/external_tools.json", '{ "tools": {} }\n')
vim.cmd("OrchLaunchReload")
h.check("legacy {} lists still load", state.is_loaded() and #state.external_tools().tools == 0)
h.ok("legacy {} lists can be saved again", function()
    state.add_external_tool(config.external_tool({ name = "later", program = "x" }))
    state.save()
end)
check_project("after migrating legacy files")

-- with a real CMake project
if vim.fn.executable("cmake") == 1 and vim.fn.executable("c++") == 1 then
    local proj2 = h.tempdir()
    h.write(proj2 .. "/CMakeLists.txt", "cmake_minimum_required(VERSION 3.20)\nproject(d CXX)\nadd_executable(hello main.cpp)\n")
    h.write(proj2 .. "/main.cpp", "int main(){return 0;}\n")
    project = proj2
    orch.setup({ root = proj2, silent = true })
    orch.create_project(proj2)
    vim.cmd("OrchLaunchLoadCMake")
    vim.wait(30000, function()
        return h.read(proj2 .. "/.orch/run_configurations.json"):find("hello", 1, true) ~= nil
    end, 50)
    check_project("after loading CMake")
else
    print("NOTE  cmake/c++ not found: skipping the 'after loading CMake' case")
end

-- ---- 5. enums and list keys match the code ------------------------------------------
--- Collects the enum/const values of every property called `prop`.
local function schema_values(prop)
    local found = {}
    local function walk(node)
        if type(node) ~= "table" then
            return
        end
        local p = type(node.properties) == "table" and node.properties[prop]
        if type(p) == "table" then
            if p.const ~= nil then
                found[p.const] = true
            end
            for _, value in ipairs(p.enum or {}) do
                found[value] = true
            end
        end
        for key, value in pairs(node) do
            if key ~= "enum" then
                walk(value)
            end
        end
    end
    for _, name in ipairs(NAMES) do
        walk(schemas[name])
    end
    return found
end

local function set_equals(label, got, want)
    local missing, extra = {}, {}
    for _, value in ipairs(want) do
        if not got[value] then
            missing[#missing + 1] = value
        end
    end
    local lookup = {}
    for _, value in ipairs(want) do
        lookup[value] = true
    end
    for value in pairs(got) do
        if not lookup[value] then
            extra[#extra + 1] = tostring(value)
        end
    end
    h.check(label, #missing == 0 and #extra == 0,
        ("missing in schema: [%s]; unknown to the code: [%s]"):format(table.concat(missing, ","), table.concat(extra, ",")))
end

-- configuration types: exactly what config.lua has factories for
local types = schema_values("type")
for _, kind in ipairs({ "native", "remote-debug", "compound" }) do
    h.check("config type " .. kind .. " is in the schema", types[kind] == true)
    h.check("config." .. kind:gsub("%-", "_") .. " factory exists", type(config[(kind:gsub("%-", "_"))]) == "function")
end
set_equals("console modes match", schema_values("mode"), { "embedded", "hidden", "none" })
for _, kind in ipairs({ "system", "unix", "msvc" }) do
    h.check("toolchain type " .. kind .. " is in the schema", types[kind] == true)
end

-- every array-typed property in the schemas is a LIST_KEY and vice versa
local array_props = {}
local function find_arrays(node)
    if type(node) ~= "table" then
        return
    end
    if type(node.properties) == "table" then
        for key, sub in pairs(node.properties) do
            if type(sub) == "table" and sub.type == "array" then
                array_props[key] = true
            end
        end
    end
    for key, value in pairs(node) do
        if key ~= "enum" then
            find_arrays(value)
        end
    end
end
for _, name in ipairs(NAMES) do
    find_arrays(schemas[name])
end
for key in pairs(array_props) do
    h.check(("array property %q is in config.LIST_KEYS"):format(key), config.LIST_KEYS[key] == true)
end
for key in pairs(config.LIST_KEYS) do
    h.check(("LIST_KEYS entry %q is an array in the schemas"):format(key), array_props[key] == true)
end

-- the schemas' own $id/$schema point at this repository
for _, name in ipairs(NAMES) do
    h.check(("schema %s has a draft-07 $schema"):format(name),
        schemas[name]["$schema"] == "http://json-schema.org/draft-07/schema#")
end
local _ = jsonpos

h.done("schema drift check")
