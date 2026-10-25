-- OrchLaunch — JSON parser that records source positions.
--
-- `vim.json.decode` gives no line/column information, and counting braces per
-- line breaks on strings containing `{`/`}`/quotes and on compact one-line
-- objects. This module is a small strict JSON parser whose nodes remember where
-- they start and end, so features like "jump to this entry" and diagnostics can
-- point at the exact line.
--
-- All positions are 0-indexed (line, byte column), matching `vim.diagnostic`
-- and `nvim_win_set_cursor` (after adding 1 to the line).

local M = {}

---@class OrchJsonMember
---@field key string
---@field key_line integer
---@field key_col integer
---@field key_end_col integer
---@field value OrchJsonNode

---@class OrchJsonNode
---@field kind "object" | "array" | "string" | "number" | "boolean" | "null"
---@field value any Decoded scalar (string / number / boolean); nil otherwise.
---@field line integer
---@field col integer
---@field end_line integer
---@field end_col integer Exclusive.
---@field members? OrchJsonMember[] Object members, in source order.
---@field items? OrchJsonNode[] Array items, in source order.

--- Parses `text`. Returns the root node, or nil plus an error message and the
--- 0-indexed line/column where parsing failed.
---@param text string
---@return OrchJsonNode? root
---@return string? err
---@return integer? err_line
---@return integer? err_col
function M.parse(text)
    local len = #text

    -- Offsets of the first byte of every line, for offset -> (line, col).
    local starts = { 1 }
    for p in text:gmatch("()\n") do
        starts[#starts + 1] = p + 1
    end

    local function pos(idx)
        local lo, hi = 1, #starts
        while lo < hi do
            local mid = math.floor((lo + hi + 1) / 2)
            if starts[mid] <= idx then
                lo = mid
            else
                hi = mid - 1
            end
        end
        return lo - 1, idx - starts[lo]
    end

    local i = 1

    local function fail(message, at)
        error({ jsonpos = true, message = message, at = at or i }, 0)
    end

    local function skip_ws()
        i = text:find("[^ \t\r\n]", i) or (len + 1)
    end

    local parse_value

    local function parse_string()
        local start = i
        local j = i + 1
        while true do
            local q = text:find('["\\\n]', j)
            if not q then
                fail("unterminated string", start)
            end
            local c = text:sub(q, q)
            if c == '"' then
                j = q
                break
            elseif c == "\n" then
                fail("unterminated string", start)
            else
                j = q + 2
            end
        end
        local raw = text:sub(start, j)
        local ok, decoded = pcall(vim.json.decode, raw)
        if not ok or type(decoded) ~= "string" then
            decoded = raw:sub(2, -2)
        end
        i = j + 1
        local line, col = pos(start)
        local end_line, end_col = pos(j + 1)
        return {
            kind = "string",
            value = decoded,
            line = line,
            col = col,
            end_line = end_line,
            end_col = end_col,
        }
    end

    local function parse_literal(word, kind, value)
        local start = i
        if text:sub(i, i + #word - 1) ~= word then
            fail(("unexpected token %q"):format(text:sub(i, i)), i)
        end
        i = i + #word
        local line, col = pos(start)
        local end_line, end_col = pos(i)
        return { kind = kind, value = value, line = line, col = col, end_line = end_line, end_col = end_col }
    end

    local function parse_number()
        local start = i
        local token = text:match("^-?%d+%.?%d*[eE]?[+-]?%d*", i)
        local number = token and tonumber(token)
        if not number then
            fail("invalid number", start)
        end
        i = i + #token
        local line, col = pos(start)
        local end_line, end_col = pos(i)
        return { kind = "number", value = number, line = line, col = col, end_line = end_line, end_col = end_col }
    end

    local function parse_object()
        local start = i
        i = i + 1
        local members = {}
        skip_ws()
        if text:sub(i, i) == "}" then
            i = i + 1
        else
            while true do
                skip_ws()
                if text:sub(i, i) ~= '"' then
                    fail("expected a string key", i)
                end
                local key_node = parse_string()
                skip_ws()
                if text:sub(i, i) ~= ":" then
                    fail("expected ':' after key", i)
                end
                i = i + 1
                skip_ws()
                local value = parse_value()
                members[#members + 1] = {
                    key = key_node.value,
                    key_line = key_node.line,
                    key_col = key_node.col,
                    key_end_col = key_node.end_col,
                    value = value,
                }
                skip_ws()
                local c = text:sub(i, i)
                if c == "," then
                    i = i + 1
                elseif c == "}" then
                    i = i + 1
                    break
                else
                    fail("expected ',' or '}'", i)
                end
            end
        end
        local line, col = pos(start)
        local end_line, end_col = pos(i)
        return {
            kind = "object",
            members = members,
            line = line,
            col = col,
            end_line = end_line,
            end_col = end_col,
        }
    end

    local function parse_array()
        local start = i
        i = i + 1
        local items = {}
        skip_ws()
        if text:sub(i, i) == "]" then
            i = i + 1
        else
            while true do
                skip_ws()
                items[#items + 1] = parse_value()
                skip_ws()
                local c = text:sub(i, i)
                if c == "," then
                    i = i + 1
                elseif c == "]" then
                    i = i + 1
                    break
                else
                    fail("expected ',' or ']'", i)
                end
            end
        end
        local line, col = pos(start)
        local end_line, end_col = pos(i)
        return { kind = "array", items = items, line = line, col = col, end_line = end_line, end_col = end_col }
    end

    parse_value = function()
        skip_ws()
        local c = text:sub(i, i)
        if c == "{" then
            return parse_object()
        elseif c == "[" then
            return parse_array()
        elseif c == '"' then
            return parse_string()
        elseif c == "t" then
            return parse_literal("true", "boolean", true)
        elseif c == "f" then
            return parse_literal("false", "boolean", false)
        elseif c == "n" then
            return parse_literal("null", "null", nil)
        elseif c == "-" or c:match("%d") then
            return parse_number()
        elseif c == "" then
            fail("unexpected end of input", i)
        end
        fail(("unexpected character %q"):format(c), i)
    end

    local ok, result = pcall(function()
        local root = parse_value()
        skip_ws()
        if i <= len then
            fail("unexpected trailing content", i)
        end
        return root
    end)

    if ok then
        return result
    end
    if type(result) == "table" and result.jsonpos then
        local line, col = pos(math.min(result.at, len + 1))
        return nil, result.message, line, col
    end
    return nil, tostring(result), 0, 0
end

--- Parses the contents of a buffer.
---@param bufnr integer
---@return OrchJsonNode? root
---@return string? err
---@return integer? err_line
---@return integer? err_col
function M.parse_buffer(bufnr)
    local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
    return M.parse(table.concat(lines, "\n"))
end

--- Returns the member record of an object node, or nil.
---@param node? OrchJsonNode
---@param key string
---@return OrchJsonMember?
function M.member(node, key)
    if not node or node.kind ~= "object" then
        return nil
    end
    for _, member in ipairs(node.members) do
        if member.key == key then
            return member
        end
    end
    return nil
end

--- Returns the value node stored under `key` in an object node.
---@param node? OrchJsonNode
---@param key string
---@return OrchJsonNode?
function M.get(node, key)
    local member = M.member(node, key)
    return member and member.value or nil
end

--- Follows a key path (`{"cmake", "profiles"}`) through nested objects.
---@param node? OrchJsonNode
---@param path string[]
---@return OrchJsonNode?
function M.get_path(node, path)
    local current = node
    for _, key in ipairs(path) do
        current = M.get(current, key)
        if not current then
            return nil
        end
    end
    return current
end

--- Returns the string stored under `key`, or nil when absent / not a string.
---@param node? OrchJsonNode
---@param key string
---@return string?
function M.get_string(node, key)
    local value = M.get(node, key)
    if value and value.kind == "string" then
        return value.value
    end
    return nil
end

--- Converts a node back to a plain Lua value (`null` becomes `vim.NIL`).
---@param node OrchJsonNode
---@return any
function M.to_lua(node)
    if node.kind == "object" then
        local out = {}
        for _, member in ipairs(node.members) do
            out[member.key] = M.to_lua(member.value)
        end
        return out
    elseif node.kind == "array" then
        local out = {}
        for index, item in ipairs(node.items) do
            out[index] = M.to_lua(item)
        end
        return out
    elseif node.kind == "null" then
        return vim.NIL
    end
    return node.value
end

return M
