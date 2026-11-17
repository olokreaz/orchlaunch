-- OrchLaunch — blink.cmp source for `${...}` macros inside `.orch/*.json`.
-- Logic lives in `orchlaunch.completion`; this file only adapts it to blink.

local completion = require("orchlaunch.completion")

local source = {}

function source.new(_, _)
    return setmetatable({}, { __index = source })
end

--- Only inside `.orch` JSON files, only after `${`.
function source:enabled()
    local name = vim.api.nvim_buf_get_name(0)
    return name:find("/%.orch/") ~= nil and name:match("%.json$") ~= nil
end

function source:get_trigger_characters()
    return { "{", ":" }
end

function source:get_completions(ctx, callback)
    local before = ctx.line:sub(1, ctx.cursor[2])
    local prefix = completion.prefix_at(before)
    if not prefix then
        callback({ items = {}, is_incomplete_backward = false, is_incomplete_forward = false })
        return function() end
    end

    local items = {}
    for _, item in ipairs(completion.items(prefix, ctx.bufnr)) do
        items[#items + 1] = {
            label = item.label,
            insertText = item.insert,
            kind = vim.lsp.protocol.CompletionItemKind.Variable,
            detail = item.detail,
            documentation = item.detail,
        }
    end

    callback({ items = items, is_incomplete_backward = false, is_incomplete_forward = false })
    return function() end
end

return source
