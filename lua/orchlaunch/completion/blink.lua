-- OrchLaunch — blink.cmp source for `${...}` macros inside `.orch/*.json`.
-- Logic lives in `orchlaunch.completion`; this file adapts it to blink.
--
-- blink draws an item with `kind_icon` / `kind_hl` when they are set, and only
-- falls back to its own per-kind icons otherwise. Setting them here is what
-- makes macros, vars and env look different from one another.

local completion = require("orchlaunch.completion")

local source = {}

-- Define the highlight groups once. `default = true` lets a user override them
-- in their colourscheme without us clobbering it.
local function define_highlights()
    for group, link in pairs(completion.highlights()) do
        vim.api.nvim_set_hl(0, group, { link = link, default = true })
    end
end

function source.new(_, _)
    define_highlights()
    return setmetatable({}, { __index = source })
end

--- Only inside `.orch` JSON files.
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

    local CompletionItemKind = require("blink.cmp.types").CompletionItemKind
    local items = {}
    for _, item in ipairs(completion.items(prefix, ctx.bufnr)) do
        items[#items + 1] = {
            label = item.label,
            insertText = item.insert,
            -- Real LSP kind keeps blink's sorting sensible; the visuals come
            -- from kind_icon / kind_hl below.
            kind = CompletionItemKind.Variable,
            kind_name = item.kind.name,
            kind_icon = item.kind.icon,
            kind_hl = item.kind.hl,
            detail = item.detail,
            documentation = { kind = "markdown", value = item.detail },
            source_name = "OrchLaunch",
        }
    end

    callback({ items = items, is_incomplete_backward = false, is_incomplete_forward = false })
    return function() end
end

return source
