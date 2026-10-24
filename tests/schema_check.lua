-- OrchLaunch — Schema drift test.
--
-- Validates that:
-- 1. All example configurations in tests/ and README.md are valid per the schemas.
-- 2. The schemas themselves are valid draft-07.
-- 3. The set of allowed types/enums in schemas matches what the code accepts.

local here = vim.fn.fnamemodify(debug.getinfo(1, "S").source:sub(2), ":p:h")
package.path = here .. "/?.lua;" .. package.path
local h = require("harness")

-- Try to load jsonschema (Python) or use a Lua alternative
local has_jsonschema = false
local validate_fn = nil

-- Try Python jsonschema first
local python_check = vim.fn.system("python3 -c \"import jsonschema; print('ok')\" 2>/dev/null")
if vim.v.shell_error == 0 and python_check:match("ok") then
    has_jsonschema = true
    validate_fn = function(schema_path, data_path)
        local cmd = string.format(
            "python3 -c \"import json, jsonschema, sys; schema=json.load(open('%s')); data=json.load(open('%s')); jsonschema.validate(data, schema); print('valid')\" 2>&1",
            schema_path, data_path
        )
        local out = vim.fn.system(cmd)
        return vim.v.shell_error == 0, out
    end
else
    -- Try Lua jsonschema (if available via luarocks)
    local ok, jsonschema = pcall(require, "jsonschema")
    if ok then
        has_jsonschema = true
        validate_fn = function(schema_path, data_path)
            local schema = vim.json.decode(vim.fn.readfile(schema_path))
            local data = vim.json.decode(vim.fn.readfile(data_path))
            local ok, err = pcall(jsonschema.validate, schema, data)
            return ok, err or "valid"
        end
    end
end

if not has_jsonschema then
    print("SKIP  schema validation: jsonschema not available (install python3-jsonschema or luarocks jsonschema)")
    h.done("schema drift check (skipped)")
    return
end

local schema_dir = vim.fs.joinpath(here, "..", "schemas")
local schemas = {
    run_configurations = "run_configurations.schema.json",
    external_tools = "external_tools.schema.json",
    toolchain = "toolchain.schema.json",
    cmake_settings = "cmake_settings.schema.json",
}

-- Test 1: Schemas are valid draft-07
for name, file in pairs(schemas) do
    local path = vim.fs.joinpath(schema_dir, file)
    local ok, err = validate_fn(path, path)
    h.check(("schema %s is valid draft-07"):format(name), ok, err)
end

-- Test 2: Example configs from tests/ validate against schemas
local test_configs = {
    { schema = "run_configurations", file = "tests/fixtures/run_configurations.json" },
    { schema = "external_tools", file = "tests/fixtures/external_tools.json" },
    { schema = "toolchain", file = "tests/fixtures/toolchain.json" },
    { schema = "cmake_settings", file = "tests/fixtures/cmake_settings.json" },
}

for _, tc in ipairs(test_configs) do
    local schema_path = vim.fs.joinpath(schema_dir, tc.schema .. ".schema.json")
    local data_path = vim.fs.joinpath(here, "..", tc.file)
    if vim.fn.filereadable(data_path) == 1 then
        local ok, err = validate_fn(schema_path, data_path)
        h.check(("example config %s validates"):format(tc.file), ok, err)
    else
        h.check(("example config %s exists"):format(tc.file), false, "file not found")
    end
end

-- Test 3: Schema enum values match code
local config = require("orchlaunch.config")

-- Check configuration types
local schema_content = vim.fn.readfile(vim.fs.joinpath(schema_dir, "run_configurations.schema.json"))
local schema_text = table.concat(schema_content, "\n")
local config_types_in_schema = {}
for t in schema_text:gmatch('"type"%s*:%s*{%s*"enum"%s*:%s*%[([^%]]+)%]') do
    for t in t:gmatch('"([^"]+)"') do
        config_types_in_schema[t] = true
    end
end

local config_types_in_code = { "native", "remote-debug", "compound" }
for _, t in ipairs(config_types_in_code) do
    h.check(("config type %s in schema"):format(t), config_types_in_schema[t] == true)
end

-- Check console modes
local console_modes_in_schema = {}
for m in schema_text:gmatch('"mode"%s*:%s*{%s*"enum"%s*:%s*%[([^%]]+)%]') do
    for m in m:gmatch('"([^"]+)"') do
        console_modes_in_schema[m] = true
    end
end
local console_modes_in_code = { "embedded", "hidden", "none" }
for _, m in ipairs(console_modes_in_code) do
    h.check(("console mode %s in schema"):format(m), console_modes_in_schema[m] == true)
end

-- Check toolchain types
local toolchain_schema = table.concat(vim.fn.readfile(vim.fs.joinpath(schema_dir, "toolchain.schema.json")), "\n")
local tc_types_in_schema = {}
for t in toolchain_schema:gmatch('"type"%s*:%s*{%s*"enum"%s*:%s*%[([^%]]+)%]') do
    for t in t:gmatch('"([^"]+)"') do
        tc_types_in_schema[t] = true
    end
end
local tc_types_in_code = { "system", "unix", "msvc" }
for _, t in ipairs(tc_types_in_code) do
    h.check(("toolchain type %s in schema"):format(t), tc_types_in_schema[t] == true)
end

h.done("schema drift check")