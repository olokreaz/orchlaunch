-- A small JSON Schema (draft-07 subset) validator for the tests.
--
-- It covers exactly the keywords the OrchLaunch schemas use, so the schema
-- check runs everywhere without Python or luarocks: $ref, type, required,
-- properties, additionalProperties, items, enum, const, minLength, minItems,
-- pattern, allOf, anyOf, oneOf, if/then/else, not.
--
-- Documents are validated as `orchlaunch.jsonpos` nodes, which (unlike
-- `vim.json.decode`) keep the difference between `[]` and `{}`.

local jsonpos = require("orchlaunch.jsonpos")

local M = {}

local TYPES = {
    string = true,
    number = true,
    integer = true,
    boolean = true,
    null = true,
    object = true,
    array = true,
}

--- Resolves a local `$ref` ("#/definitions/x") inside `root`.
local function resolve(root, ref)
    if ref:sub(1, 2) ~= "#/" then
        return nil
    end
    local node = root
    for part in ref:sub(3):gmatch("[^/]+") do
        part = part:gsub("~1", "/"):gsub("~0", "~")
        if type(node) ~= "table" then
            return nil
        end
        node = node[part]
    end
    return node
end

local function type_matches(kind, node)
    if kind == "integer" then
        return node.kind == "number" and node.value == math.floor(node.value)
    end
    return node.kind == kind
end

local function same_scalar(node, value)
    if node.kind == "object" or node.kind == "array" then
        return false
    end
    if node.kind == "null" then
        return value == vim.NIL or value == nil
    end
    return node.value == value
end

local validate

--- Number of errors `schema` reports for `node` (used by oneOf/anyOf/if).
local function count_errors(schema, node, root)
    local errors = {}
    validate(schema, node, "", root, errors)
    return #errors
end

validate = function(schema, node, path, root, errors)
    local function fail(message)
        errors[#errors + 1] = { path = path == "" and "$" or path, message = message }
    end

    if schema == true or schema == nil then
        return
    end
    if schema == false then
        return fail("value is not allowed here")
    end

    if schema["$ref"] then
        local target = resolve(root, schema["$ref"])
        if not target then
            return fail("unresolvable $ref " .. schema["$ref"])
        end
        return validate(target, node, path, root, errors)
    end

    if schema.type then
        local wanted = type(schema.type) == "table" and schema.type or { schema.type }
        local ok = false
        for _, kind in ipairs(wanted) do
            ok = ok or type_matches(kind, node)
        end
        if not ok then
            return fail(("expected %s, got %s"):format(table.concat(wanted, "|"), node.kind))
        end
    end

    if schema.const ~= nil and not same_scalar(node, schema.const) then
        fail(("expected constant %s"):format(vim.inspect(schema.const)))
    end
    if schema.enum then
        local found = false
        for _, value in ipairs(schema.enum) do
            found = found or same_scalar(node, value)
        end
        if not found then
            fail(("value is not one of %s"):format(table.concat(vim.tbl_map(tostring, schema.enum), ", ")))
        end
    end

    if node.kind == "string" then
        if schema.minLength and #node.value < schema.minLength then
            fail("string is shorter than minLength")
        end
        if schema.pattern then
            local ok, re = pcall(vim.regex, "\\v" .. schema.pattern:gsub("\\d", "[0-9]"))
            if ok and re and not re:match_str(node.value) then
                fail("string does not match pattern " .. schema.pattern)
            end
        end
    end

    if node.kind == "array" then
        if schema.minItems and #node.items < schema.minItems then
            fail("array has fewer than minItems items")
        end
        if type(schema.items) == "table" then
            for index, item in ipairs(node.items) do
                validate(schema.items, item, ("%s[%d]"):format(path, index - 1), root, errors)
            end
        end
    end

    if node.kind == "object" then
        for _, key in ipairs(schema.required or {}) do
            if not jsonpos.member(node, key) then
                fail(("missing required property %q"):format(key))
            end
        end
        local props = schema.properties or {}
        for _, member in ipairs(node.members) do
            local sub = props[member.key]
            local child_path = path == "" and member.key or (path .. "." .. member.key)
            if sub ~= nil then
                validate(sub, member.value, child_path, root, errors)
            elseif schema.additionalProperties == false then
                errors[#errors + 1] = { path = child_path, message = "additional property not allowed" }
            elseif type(schema.additionalProperties) == "table" then
                validate(schema.additionalProperties, member.value, child_path, root, errors)
            end
        end
    end

    for _, sub in ipairs(schema.allOf or {}) do
        validate(sub, node, path, root, errors)
    end
    if schema.anyOf then
        local any = false
        for _, sub in ipairs(schema.anyOf) do
            any = any or count_errors(sub, node, root) == 0
        end
        if not any then
            fail("does not match any of the anyOf alternatives")
        end
    end
    if schema.oneOf then
        local matches = 0
        for _, sub in ipairs(schema.oneOf) do
            if count_errors(sub, node, root) == 0 then
                matches = matches + 1
            end
        end
        if matches ~= 1 then
            fail(("matches %d of the oneOf alternatives (expected exactly 1)"):format(matches))
        end
    end
    if schema["not"] and count_errors(schema["not"], node, root) == 0 then
        fail("matches a schema it must not match")
    end
    if schema["if"] then
        local branch = count_errors(schema["if"], node, root) == 0 and schema["then"] or schema["else"]
        if branch then
            validate(branch, node, path, root, errors)
        end
    end
end

--- Validates JSON text against a decoded schema.
---@param schema table
---@param text string
---@return { path: string, message: string }[] errors
function M.validate_text(schema, text)
    local root, err = jsonpos.parse(text)
    if not root then
        return { { path = "$", message = "invalid JSON: " .. tostring(err) } }
    end
    local errors = {}
    validate(schema, root, "", schema, errors)
    return errors
end

--- Formats the first errors for a test failure message.
---@param errors { path: string, message: string }[]
---@return string
function M.format(errors)
    local parts = {}
    for i = 1, math.min(#errors, 4) do
        parts[#parts + 1] = errors[i].path .. ": " .. errors[i].message
    end
    return table.concat(parts, "; ")
end

--- Structural sanity check of a schema document (a light meta-schema): known
--- keywords have the right shape and every local $ref resolves. Returns a list
--- of problems.
---@param schema table
---@return string[] problems
function M.check_schema(schema)
    local problems = {}
    local function walk(node, path)
        if type(node) ~= "table" then
            return
        end
        if node["$ref"] ~= nil and resolve(schema, node["$ref"]) == nil then
            problems[#problems + 1] = path .. ": $ref does not resolve: " .. tostring(node["$ref"])
        end
        if node.type ~= nil then
            local kinds = type(node.type) == "table" and node.type or { node.type }
            for _, kind in ipairs(kinds) do
                if not TYPES[kind] then
                    problems[#problems + 1] = path .. ": unknown type " .. tostring(kind)
                end
            end
        end
        if node.required ~= nil then
            if type(node.required) ~= "table" then
                problems[#problems + 1] = path .. ": required must be an array"
            else
                for _, key in ipairs(node.required) do
                    if type(key) ~= "string" then
                        problems[#problems + 1] = path .. ": required entries must be strings"
                    end
                end
            end
        end
        if node.enum ~= nil and (type(node.enum) ~= "table" or #node.enum == 0) then
            problems[#problems + 1] = path .. ": enum must be a non-empty array"
        end
        if node.properties ~= nil and type(node.properties) ~= "table" then
            problems[#problems + 1] = path .. ": properties must be an object"
        end
        for _, key in ipairs({ "allOf", "anyOf", "oneOf" }) do
            if node[key] ~= nil and (type(node[key]) ~= "table" or #node[key] == 0) then
                problems[#problems + 1] = ("%s: %s must be a non-empty array"):format(path, key)
            end
        end
        local MAPS = { properties = true, definitions = true, ["$defs"] = true, patternProperties = true }
        for key, value in pairs(node) do
            if MAPS[key] and type(value) == "table" then
                -- maps of name -> schema: the names are not keywords
                for name, child in pairs(value) do
                    walk(child, ("%s.%s.%s"):format(path, key, tostring(name)))
                end
            elseif key ~= "enum" and key ~= "const" and key ~= "default" and key ~= "examples" then
                walk(value, path .. "." .. tostring(key))
            end
        end
    end
    walk(schema, "$")
    return problems
end

return M
