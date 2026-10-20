-- OrchLaunch — fibrous form editor scaffolding.
--
-- Every fibrous editor is a small spec over this module: an initial value
-- table, a layout callback that composes the body from the builders below, and
-- a collect/save pair. The scaffolding owns the shared plumbing — the value
-- state, the save/close keymaps, the mount/size/resize lifecycle, and the field
-- navigation + flash jump (`orchlaunch.ui.fibrous.fields`).

local util = require("orchlaunch.ui.fibrous.util")
local fields = require("orchlaunch.ui.fibrous.fields")

local ERROR = vim.log.levels.ERROR
local WARN = vim.log.levels.WARN

local M = {}

--- Sentinel shown for the free-form target path option.
M.CUSTOM_TARGET = "(executable path…)"

--- @class OrchFibrousFormOpts
--- @field initial table id -> string|boolean
--- @field render fun(ctx: table, api: table): table Node tree body.
--- @field collect? fun(values: table): any Returns the value to save (may error to abort).
--- @field save? fun(value: any) Persists the collected value.
--- @field title? string|fun(values: table): string
--- @field readonly? boolean
--- @field size? table|fun(mount_opts: table)
--- @field zindex? integer
--- @field augroup? string
--- @field on_saved? fun()
--- @field extra_keymaps? { { mode: string, lhs: string, fn: function } }[]
--- @field footer? string

--- Opens a fibrous form editor.
--- @param opts OrchFibrousFormOpts
--- @return table handle
function M.open(opts)
    local nr = require("fibrous")
    local ui = nr.ui
    local state = require("orchlaunch.state")

    opts.initial = opts.initial or {}
    local readonly = opts.readonly or false

    local form --- state handle, assigned on first render
    local handle
    local closed = false

    local function value(id)
        return form and (form.get() or {})[id]
    end

    --- @param id string
    --- @param v any
    local function set(id, v)
        if form then
            form.set(vim.tbl_extend("force", form.get() or {}, { [id] = v }))
        end
    end

    local function dlog(line)
        util.dlog("module", line)
    end

    local function cleanup()
        pcall(vim.api.nvim_del_augroup_by_name, opts.augroup or "OrchlaunchFibrousForm")
    end

    local function close()
        cleanup()
        if not closed and handle then
            closed = true
            handle.unmount()
        end
    end

    local function save()
        if readonly then
            vim.notify("[orchlaunch] read-only — nothing to save", WARN)
            return
        end
        local ok, result = pcall(opts.collect, form.get() or {})
        if not ok then
            vim.notify("[orchlaunch] " .. tostring(result), ERROR)
            if handle then
                handle.focus()
            end
            return
        end
        if opts.save then
            opts.save(result)
        end
        state.save()
        close()
    end

    -- ---- builders ---------------------------------------------------------

    local api = {
        value = value,
        set = set,
        readonly = readonly,
    }

    --- @param id string
    --- @param o? { label?: string, value?: string, height?: integer, singleline?: boolean, width?: integer, grow?: integer }
    function api.text(id, o)
        o = o or {}
        return {
            comp = ui.text_input,
            props = {
                value = o.value ~= nil and o.value or opts.initial[id],
                height = o.height or 3,
                singleline = o.singleline or false,
                width = o.width,
                grow = o.grow,
                style = { border = "rounded" },
                on_change = function(v)
                    set(id, v)
                end,
            },
        }
    end

    --- @param id string
    --- @param options string[]
    --- @param o? { width?: integer, grow?: integer }
    function api.select(id, options, o)
        o = o or {}
        -- The dropdown itself is one row tall; a 3-row wrapper keeps two
        -- columns' heading baselines aligned with bordered text fields.
        return {
            comp = ui.col,
            props = { grow = o.grow or 1, height = 3, align = "start", justify = "start" },
            children = {
                {
                    comp = ui.dropdown,
                    props = {
                        options = options,
                        value = opts.initial[id],
                        width = o.width or 24,
                        on_select = function(v)
                            set(id, v)
                        end,
                    },
                },
            },
        }
    end

    --- @param id string
    --- @param o? { label?: string }
    function api.check(id, o)
        o = o or {}
        return {
            comp = ui.checkbox,
            props = {
                label = " " .. (o.label or id),
                checked = value(id) == true,
                on_toggle = function(checked)
                    set(id, checked)
                end,
            },
        }
    end

    --- @param text string
    function api.heading(text)
        return { comp = ui.label, props = { text = " " .. text, style = { text_hl = "Title" } } }
    end

    --- @param text string
    --- @param node table
    function api.field_label(text, node)
        return {
            comp = ui.row,
            props = { gap = 1, align = "start" },
            children = {
                { comp = ui.label, props = { text = text, width = 16, style = { text_hl = "Comment" } } },
                node,
            },
        }
    end

    --- @param text string
    function api.centered(text)
        return { comp = ui.label, props = { text = text, align_self = "center", style = { text_hl = "Title" } } }
    end

    --- @param text string
    function api.footer(text)
        return {
            comp = ui.label,
            props = { text = "  " .. text .. "  ", align_self = "center", style = { text_hl = "Comment" } },
        }
    end

    --- @return string
    function api.title()
        if type(opts.title) == "function" then
            return opts.title(form.get() or {})
        end
        return opts.title or ""
    end

    --- Builds the shared "before launch" block (build/install toggles plus the
    --- external-tools list). The collect side reads it back with
    --- `M.collect_before`.
    --- @return table
    function api.before_fields()        return {
            comp = ui.col,
            props = { grow = 1, gap = 1 },
            children = {
                api.check("before_build", { label = "Build before launch" }),
                api.check("before_install", { label = "Install before launch" }),
                api.field_label("External", api.text("before_external", { height = 3, grow = 1 })),
            },
        }
    end

    --- Builds a CMake-target picker: a target select plus a free-form path
    --- input when targets are known, or a plain input otherwise. The editor
    --- seeds `initial[select_id]` with the matched target (or the custom marker).
    --- Read it back with `M.read_target`.
    --- @param o { input_id: string, select_id: string, targets: table[]?, label?: string }
    --- @return table
    function api.target_field(o)
        local input = api.field_label(o.label or "Target", api.text(o.input_id, { singleline = true, grow = 1 }))
        if not o.targets or #o.targets == 0 then
            return input
        end
        local options = { M.CUSTOM_TARGET }
        for _, target in ipairs(o.targets) do
            options[#options + 1] = target.name
        end
        return {
            comp = ui.col,
            props = { grow = 1, gap = 1 },
            children = {
                api.field_label("Target", api.select(o.select_id, options)),
                input,
            },
        }
    end

    -- ---- mount ------------------------------------------------------------

    local function editor(ctx)
        form = form or ctx.use_state(opts.initial)
        return opts.render(ctx, api)
    end

    local mount_opts = { zindex = opts.zindex or 50 }
    local function apply_size()
        if type(opts.size) == "function" then
            opts.size(mount_opts)
        elseif type(opts.size) == "table" then
            mount_opts.width, mount_opts.height = opts.size.width, opts.size.height
        else
            util.apply_size(mount_opts, 0.75, 0.85, 80, 120, 20, 36)
        end
    end

    apply_size()
    -- A float does not restore the window that was focused before it opened
    -- (the list/browser dialog is a float too). Remember it and hand focus back
    -- on close, otherwise it falls through to the underlying editor.
    local origin_winid = vim.api.nvim_get_current_win()
    mount_opts.on_unmount = function()
        cleanup()
        if opts.on_saved then
            opts.on_saved()
        end
        if origin_winid and vim.api.nvim_win_is_valid(origin_winid)
            and vim.api.nvim_get_current_win() ~= origin_winid then
            pcall(vim.api.nvim_set_current_win, origin_winid)
        end
    end

    handle = nr.mount(editor, {}, mount_opts)
    handle.focus()

    vim.keymap.set("n", "q", close, { buffer = handle.bufnr, nowait = true, silent = true })
    vim.keymap.set({ "n", "i" }, "<C-s>", save, { buffer = handle.bufnr, nowait = true, silent = true })
    vim.keymap.set("n", "<Esc>", close, { buffer = handle.bufnr, nowait = true, silent = true })

    if opts.extra_keymaps then
        for _, m in ipairs(opts.extra_keymaps) do
            vim.keymap.set(m.mode, m.lhs, m.fn, { buffer = handle.bufnr, nowait = true, silent = true })
        end
    end

    handle._fields = fields.attach(handle)
    util.watch_resize(opts.augroup or "OrchlaunchFibrousForm", mount_opts, apply_size, function()
        return handle
    end)

    if opts.attach then
        local store = form
        local proxy = setmetatable({}, {
            __index = function(_, k)
                return (store and store.get() or {})[k]
            end,
        })
        opts.attach(handle, {
            store = store,
            values = proxy,
            set = set,
            save = save,
            close = function()
                close()
            end,
            cells = function()
                return handle._fields.cells()
            end,
        })
    end

    -- Generic test/inspection hooks, mirroring the CMake profile editor's
    -- `.orch` API. Editors with custom hooks (attach) keep theirs.
    if not handle.orch then
        local store = form
        local ids = {}
        for id in pairs(opts.initial) do
            ids[#ids + 1] = id
        end
        table.sort(ids)
        local fields_meta = {}
        for _, id in ipairs(ids) do
            fields_meta[#fields_meta + 1] = { id = id }
        end
        handle.orch = {
            readonly = readonly,
            fields = fields_meta,
            values = setmetatable({}, {
                __index = function(_, k)
                    return (store and store.get() or {})[k]
                end,
            }),
            set = set,
            save = save,
            close = function()
                close()
            end,
            _field_cells = function()
                return handle._fields.cells()
            end,
        }
    end

    return handle
end

--- @param before? OrchBefore
--- @return boolean build
--- @return boolean install
--- @return string external
function M.before_flags(before)
    local build, install = false, false
    local external = {}
    for _, item in ipairs(before and before.tools or {}) do
        local kind = type(item) == "table" and item.type or item
        if kind == "build" then
            build = true
        elseif kind == "install" then
            install = true
        elseif kind == "external" then
            external[#external + 1] = (type(item) == "table" and item.tool) or ""
        end
    end
    return build, install, table.concat(external, "\n")
end

--- Reads the "before launch" block produced by `api.before_fields`.
--- @param values table
--- @return OrchBefore
function M.collect_before(values)
    local UI = require("orchlaunch.ui")
    local tools = {}
    if values.before_build then
        tools[#tools + 1] = "build"
    end
    if values.before_install then
        tools[#tools + 1] = "install"
    end
    for _, name in ipairs(UI.lines(values.before_external)) do
        tools[#tools + 1] = { type = "external", tool = name }
    end
    return { tools = tools }
end

--- Reads a target value produced by `api.target_field`.
--- @param values table
--- @param targets table[]?
--- @param input_id string
--- @param select_id string
--- @return string?
function M.read_target(values, targets, input_id, select_id)
    local UI = require("orchlaunch.ui")
    if targets and #targets > 0 then
        local choice = values[select_id]
        if choice and choice ~= M.CUSTOM_TARGET then
            return choice
        end
    end
    return UI.trimmed(values[input_id])
end

--- Adds or updates `value` in the run-configuration collection, tracking the
--- active configuration across a rename.
--- @param state table
--- @param existing_name? string
--- @param value table
function M.upsert_configuration(state, existing_name, value)
    if existing_name then
        state.update_configuration(existing_name, value)
        if existing_name ~= value.name then
            local active = require("orchlaunch.active")
            if active.get(state.root()) == existing_name then
                active.set(state.root(), value.name)
            end
        end
    else
        state.add_configuration(value)
    end
end

return M
