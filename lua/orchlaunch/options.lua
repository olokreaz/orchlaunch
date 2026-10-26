-- OrchLaunch — setup options.
--
-- Holds the normalized options passed to `require("orchlaunch").setup()`.
-- Other modules read them through `options.get()` so user settings such as
-- `ui.backend` or `ui.edit.window` actually take effect.

local M = {}

---@class OrchUiEditOptions
---@field window "split" | "vsplit" | "float" | "tab"
---@field fold_others boolean
---@field close_on_write boolean

---@class OrchUiOptions
---@field backend "buffer" | "fibrous"
---@field edit OrchUiEditOptions
---@field virtual_text boolean

---@class OrchOptions
---@field root? string
---@field silent? boolean
---@field jsonls boolean
---@field write_schema_ref boolean
---@field ui OrchUiOptions

---@return OrchOptions
local function defaults()
    return {
        jsonls = true,
        write_schema_ref = false,
        ui = {
            backend = "buffer",
            edit = { window = "float", fold_others = false, close_on_write = true },
            virtual_text = true,
        },
    }
end

local WINDOWS = { split = true, vsplit = true, float = true, tab = true }
local BACKENDS = { buffer = true, fibrous = true }

---@type OrchOptions
local current = defaults()

--- Normalizes user options (also accepts the flat aliases `ui.edit_window` and
--- `ui.fold_others`) and stores them.
---@param opts? table
---@return OrchOptions
function M.setup(opts)
    opts = type(opts) == "table" and opts or {}
    local merged = vim.tbl_deep_extend("force", defaults(), opts)

    local ui = type(merged.ui) == "table" and merged.ui or defaults().ui
    if type(ui.edit) ~= "table" then
        ui.edit = defaults().ui.edit
    end
    if type(opts.ui) == "table" then
        if opts.ui.edit_window ~= nil then
            ui.edit.window = opts.ui.edit_window
        end
        if opts.ui.fold_others ~= nil then
            ui.edit.fold_others = opts.ui.fold_others
        end
    end

    if not BACKENDS[ui.backend] then
        vim.notify(
            ("[orchlaunch] unknown ui.backend %q; using \"buffer\""):format(tostring(ui.backend)),
            vim.log.levels.WARN
        )
        ui.backend = "buffer"
    end
    if not WINDOWS[ui.edit.window] then
        vim.notify(
            ("[orchlaunch] unknown ui.edit window %q; using \"float\""):format(tostring(ui.edit.window)),
            vim.log.levels.WARN
        )
        ui.edit.window = "float"
    end
    ui.edit.fold_others = ui.edit.fold_others == true
    ui.edit.close_on_write = ui.edit.close_on_write ~= false
    ui.virtual_text = ui.virtual_text ~= false
    merged.ui = ui
    merged.jsonls = merged.jsonls ~= false
    merged.write_schema_ref = merged.write_schema_ref == true

    current = merged
    return current
end

---@return OrchOptions
function M.get()
    return current
end

return M
