-- setup() must store and normalize user options; ui.* settings used to be
-- silently ignored because nothing assigned `require("orchlaunch").config`.

local here = vim.fn.fnamemodify(debug.getinfo(1, "S").source:sub(2), ":p:h")
package.path = here .. "/?.lua;" .. package.path
local h = require("harness")

local messages = {}
vim.notify = function(msg)
    messages[#messages + 1] = tostring(msg)
end

local orch = require("orchlaunch")
local options = require("orchlaunch.options")
local root = h.tempdir()

orch.setup({ root = root, silent = true })
h.eq("defaults: backend is buffer", options.get().ui.backend, "buffer")
h.eq("defaults: window is split", options.get().ui.edit.window, "split")
h.eq("defaults: virtual text on", options.get().ui.virtual_text, true)
h.eq("defaults: jsonls on", options.get().jsonls, true)
h.eq("defaults: write_schema_ref off", options.get().write_schema_ref, false)
h.check("setup exposes M.config", type(orch.config) == "table" and orch.config.ui.backend == "buffer")

orch.setup({
    root = root,
    silent = true,
    jsonls = false,
    write_schema_ref = true,
    ui = { backend = "fibrous", edit = { window = "vsplit", fold_others = true }, virtual_text = false },
})
local o = options.get()
h.eq("user backend is applied", o.ui.backend, "fibrous")
h.eq("user edit window is applied", o.ui.edit.window, "vsplit")
h.eq("user fold_others is applied", o.ui.edit.fold_others, true)
h.eq("user virtual_text is applied", o.ui.virtual_text, false)
h.eq("user jsonls=false is applied", o.jsonls, false)
h.eq("user write_schema_ref is applied", o.write_schema_ref, true)
h.eq("M.config mirrors the options", orch.config.ui.edit.window, "vsplit")

-- flat aliases from the documented spec
orch.setup({ root = root, silent = true, ui = { edit_window = "tab", fold_others = true } })
h.eq("alias ui.edit_window", options.get().ui.edit.window, "tab")
h.eq("alias ui.fold_others", options.get().ui.edit.fold_others, true)

-- invalid values fall back with a warning, never raise
messages = {}
h.ok("invalid options do not raise", function()
    orch.setup({ root = root, silent = true, ui = { backend = "nope", edit = { window = "sideways" } } })
end)
h.eq("invalid backend falls back", options.get().ui.backend, "buffer")
h.eq("invalid window falls back", options.get().ui.edit.window, "split")
local warned = 0
for _, m in ipairs(messages) do
    if m:find("unknown ui", 1, true) then
        warned = warned + 1
    end
end
h.eq("both invalid values were reported", warned, 2)

-- a setup() without arguments resets everything to defaults
orch.setup({ root = root, silent = true })
h.eq("reset: backend", options.get().ui.backend, "buffer")

h.done("setup options")
