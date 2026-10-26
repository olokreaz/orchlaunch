-- :OrchLaunchEdit / :OrchLaunchNew behaviour with scripted pickers.
--
-- Regressions covered:
--   * the file picker and the "Open whole file" entry used to re-open the
--     same picker forever (infinite recursion);
--   * unknown subcommands were ignored, names with spaces were cut;
--   * entry lookup broke on braces inside strings / one-line objects;
--   * :OrchLaunchNew raised on duplicate names.

local here = vim.fn.fnamemodify(debug.getinfo(1, "S").source:sub(2), ":p:h")
package.path = here .. "/?.lua;" .. package.path
local h = require("harness")

local messages = {}
vim.notify = function(msg, level)
    messages[#messages + 1] = { text = tostring(msg), level = level }
end
local function saw(fragment, level)
    for _, m in ipairs(messages) do
        if m.text:find(fragment, 1, true) and (level == nil or m.level == level) then
            return true
        end
    end
    return false
end

-- ---- scripted pickers ------------------------------------------------------
local picker_calls = {}
local picker_script = {} -- list of functions(items) -> index | nil
vim.ui.select = function(items, opts, cb)
    picker_calls[#picker_calls + 1] = { items = items, prompt = opts and opts.prompt, format_item = opts and opts.format_item }
    if #picker_calls > 8 then
        return -- break runaway recursion, the test then fails on the call count
    end
    local step = table.remove(picker_script, 1)
    local index = step and step(items) or nil
    if index then
        cb(items[index], index)
    else
        cb(nil, nil)
    end
end
local input_script = {}
vim.ui.input = function(opts, cb)
    cb(table.remove(input_script, 1))
end

local function label_of(call, index)
    local item = call.items[index]
    return call.format_item and call.format_item(item) or tostring(item)
end

local function index_by_label(call, wanted)
    for i = 1, #call.items do
        if label_of(call, i) == wanted or label_of(call, i):find(wanted, 1, true) == 1 then
            return i
        end
    end
end

local function reset()
    picker_calls, picker_script, input_script, messages = {}, {}, {}, {}
    vim.cmd("silent! %bwipeout!")
    vim.cmd("silent! tabonly")
    vim.cmd("silent! only")
end

local function cursor_line()
    return vim.api.nvim_win_get_cursor(0)[1]
end

local function line_of(text, from)
    local lines = vim.api.nvim_buf_get_lines(0, 0, -1, false)
    for i = from or 1, #lines do
        if lines[i]:find(text, 1, true) then
            return i
        end
    end
end

-- ---- fixture project -------------------------------------------------------
local orch = require("orchlaunch")
local root = h.tempdir()
local function setup(opts)
    opts = vim.tbl_extend("force", { root = root, silent = true }, opts or {})
    orch.setup(opts)
end
setup()
orch.create_project(root)

local runs = table.concat({
    "{",
    '  "configurations": [',
    "    {",
    '      "name": "Alpha {x} \\"q\\"",',
    '      "type": "native",',
    '      "target": "/bin/echo",',
    '      "args": ["}", "]"]',
    "    },",
    '    { "name": "Compact", "type": "native", "target": "nope-target" },',
    "    {",
    '      "name": "With Spaces",',
    '      "type": "native",',
    '      "target": "also-nope"',
    "    }",
    "  ]",
    "}",
}, "\n")
local runs_path = root .. "/.orch/run_configurations.json"
h.write(runs_path, runs)
vim.cmd("OrchLaunchReload")
local original = h.read(runs_path)

-- ---- 1. whole file: the picker appears exactly once -----------------------
reset()
picker_script = { function(items) return 1 end } -- "Open whole file"
h.ok(":OrchLaunchEdit configs does not raise", function()
    vim.cmd("OrchLaunchEdit configs")
end)
h.eq("entry picker shown once", #picker_calls, 1)
h.eq("picker offers whole file first", label_of(picker_calls[1], 1), "Open whole file")
h.eq("entries are listed with their type", label_of(picker_calls[1], 3), "Compact (native)")
h.eq("whole file opened", vim.fs.basename(vim.api.nvim_buf_get_name(0)), "run_configurations.json")
h.eq("buffer filetype is json", vim.bo.filetype, "json")

-- ---- 2. choosing an entry jumps to its name line --------------------------
for _, case in ipairs({
    { label = 'Alpha {x} "q" (native)', needle = '"name": "Alpha' },
    { label = "Compact (native)", needle = '"name": "Compact"' },
    { label = "With Spaces (native)", needle = '"name": "With Spaces"' },
}) do
    reset()
    picker_script = {
        function(items)
            return index_by_label(picker_calls[1], case.label)
        end,
    }
    vim.cmd("OrchLaunchEdit configs")
    h.eq("picker shown once for " .. case.label, #picker_calls, 1)
    h.eq("cursor on " .. case.label, cursor_line(), line_of(case.needle))
end

-- ---- 3. entry given on the command line: no picker, spaces allowed --------
reset()
vim.cmd("OrchLaunchEdit configs With Spaces")
h.eq("no picker when the entry is named", #picker_calls, 0)
h.eq("name with spaces jumps correctly", cursor_line(), line_of('"name": "With Spaces"'))

reset()
vim.cmd("OrchLaunchEdit configs Compact")
h.eq("one-line entry is found", cursor_line(), line_of('"name": "Compact"'))

reset()
vim.cmd("OrchLaunchEdit configs Missing")
h.check("unknown entry warns", saw('entry "Missing" not found', vim.log.levels.WARN), vim.inspect(messages))
h.eq("file still opens for an unknown entry", vim.fs.basename(vim.api.nvim_buf_get_name(0)), "run_configurations.json")

-- ---- 4. no arguments: file picker, then entry picker ----------------------
reset()
picker_script = {
    function(items) -- which file
        return index_by_label(picker_calls[1], "toolchain.json")
    end,
    function(items) -- whole file (or the only entry list)
        return 1
    end,
}
h.ok(":OrchLaunchEdit without arguments does not raise", function()
    vim.cmd("OrchLaunchEdit")
end)
h.check("file picker is shown", #picker_calls >= 1 and picker_calls[1].prompt:find("which configuration file", 1, true) ~= nil)
h.check("picker is not shown in a loop", #picker_calls <= 2, #picker_calls)
h.eq("chosen file opened", vim.fs.basename(vim.api.nvim_buf_get_name(0)), "toolchain.json")

reset()
picker_script = { function() return nil end }
vim.cmd("OrchLaunchEdit")
h.eq("cancelling the file picker opens nothing", vim.api.nvim_buf_get_name(0), "")

-- ---- 5. unknown subcommand warns and shows no picker ----------------------
reset()
vim.cmd("OrchLaunchEdit bogus")
h.eq("unknown subcommand shows no picker", #picker_calls, 0)
h.check("unknown subcommand warns", saw("unknown file", vim.log.levels.WARN), vim.inspect(messages))
h.eq("unknown subcommand opens nothing", vim.api.nvim_buf_get_name(0), "")

-- ---- 6. missing file is reported, never created with wrong content --------
reset()
vim.fn.delete(root .. "/.orch/breakpoints.json")
vim.cmd("OrchLaunchEdit breakpoints")
h.check("missing breakpoints file is reported", saw("does not exist yet", vim.log.levels.WARN), vim.inspect(messages))
h.eq("missing file was not created", vim.fn.filereadable(root .. "/.orch/breakpoints.json"), 0)

-- ---- 7. fold_others is window-local and does not touch the file -----------
reset()
setup({ ui = { edit = { fold_others = true } } })
vim.cmd("OrchLaunchEdit configs Compact")
local alpha = line_of('"name": "Alpha')
local compact = line_of('"name": "Compact"')
h.eq("target entry is not folded", vim.fn.foldclosed(compact), -1)
h.check("other entries are folded", vim.fn.foldclosed(alpha) ~= -1, vim.fn.foldclosed(alpha))
h.eq("folding does not modify the file", h.read(runs_path), original)
h.eq("buffer is not modified by folding", vim.bo.modified, false)

-- ---- 8. window styles ------------------------------------------------------
reset()
setup({ ui = { edit = { window = "vsplit" } } })
vim.cmd("OrchLaunchEdit configs Compact")
h.eq("vsplit opens a side-by-side window", vim.fn.winlayout()[1], "row")

reset()
setup({ ui = { edit = { window = "tab" } } })
vim.cmd("OrchLaunchEdit configs Compact")
h.eq("tab opens a new tab page", vim.fn.tabpagenr("$"), 2)

reset()
setup({ ui = { edit = { window = "float" } } })
vim.cmd("OrchLaunchEdit configs Compact")
h.check("float opens a floating window", vim.api.nvim_win_get_config(0).relative ~= "")
h.eq("float jumps to the entry", cursor_line(), line_of('"name": "Compact"'))
setup()

-- ---- 9. virtual text -------------------------------------------------------
reset()
vim.cmd("OrchLaunchEdit configs Compact")
local ns = vim.api.nvim_create_namespace("orchlaunch_virtual")
local marks = vim.api.nvim_buf_get_extmarks(0, ns, 0, -1, { details = true })
local texts = {}
for _, mark in ipairs(marks) do
    texts[#texts + 1] = mark[4].virt_text[1][1]
end
h.eq("one virtual text per native entry", #texts, 3)
h.check("path-like target shows the file", vim.tbl_contains(texts, "   /bin/echo"), vim.inspect(texts))
h.check("unknown target says so", vim.tbl_contains(texts, "   target not found"), vim.inspect(texts))
setup({ ui = { virtual_text = false } })
vim.cmd("OrchLaunchEdit configs Compact")
h.eq("virtual_text = false disables it", #vim.api.nvim_buf_get_extmarks(0, ns, 0, -1, {}), 0)
setup()

-- ---- 10. :OrchLaunchNew ----------------------------------------------------
reset()
input_script = { "Brand New" }
h.ok(":OrchLaunchNew native does not raise", function()
    vim.cmd("OrchLaunchNew native")
end)
h.check("new native config is on disk", h.read(runs_path):find('"Brand New"', 1, true) ~= nil)
h.eq("new entry opened with the cursor on it", cursor_line(), line_of('"name": "Brand New"'))

reset()
input_script = { "Brand New" }
h.ok("duplicate name does not raise", function()
    vim.cmd("OrchLaunchNew native")
end)
h.check("duplicate name is reported", saw("already exists", vim.log.levels.ERROR), vim.inspect(messages))

reset()
input_script = { "   " }
h.ok("blank name is ignored", function()
    vim.cmd("OrchLaunchNew native")
end)

-- the file is already open in a window: the new entry must show up
reset()
vim.cmd("OrchLaunchEdit configs Compact")
input_script = { "Seen Live" }
vim.cmd("OrchLaunchNew native")
h.check("already-open buffer shows the new entry", line_of('"name": "Seen Live"') ~= nil)

-- compound: pick children one by one, then <done>
reset()
input_script = { "Combo" }
picker_script = {
    function(items) return 1 end, -- first child
    function(items) return #items end, -- <done>
}
vim.cmd("OrchLaunchNew compound")
local saved = vim.json.decode(h.read(runs_path))
local combo
for _, c in ipairs(saved.configurations) do
    if c.name == "Combo" then
        combo = c
    end
end
h.check("compound was created", combo ~= nil)
h.eq("compound has the chosen child", combo and #combo.configurations, 1)

-- external tool and toolchain
reset()
input_script = { "fmt", "clang-format" }
vim.cmd("OrchLaunchNew external_tool")
h.check("external tool was created", h.read(root .. "/.orch/external_tools.json"):find('"fmt"', 1, true) ~= nil)
h.eq("external tools file is opened", vim.fs.basename(vim.api.nvim_buf_get_name(0)), "external_tools.json")

reset()
input_script = { "tc" }
vim.cmd("OrchLaunchNew toolchain")
h.check("toolchain was created", h.read(root .. "/.orch/toolchain.json"):find('"tc"', 1, true) ~= nil)

reset()
vim.cmd("OrchLaunchNew bogus")
h.check("unknown type warns", saw("unknown type", vim.log.levels.WARN), vim.inspect(messages))

-- ---- 11. floating editor closes itself on write ----------------------------
reset()
setup()
vim.cmd("OrchLaunchEdit configs Compact")
local float_win = vim.api.nvim_get_current_win()
h.check("default window is a float", vim.api.nvim_win_get_config(float_win).relative ~= "")
local q_map = vim.fn.maparg("q", "n", false, true)
h.check("q is a buffer-local close key", q_map.buffer == 1 and q_map.expr == 1)
vim.api.nvim_feedkeys("q", "x", false)
vim.wait(1000, function()
    return not vim.api.nvim_win_is_valid(float_win)
end, 20)
h.check("q closes the float", not vim.api.nvim_win_is_valid(float_win))

reset()
setup()
vim.cmd("OrchLaunchEdit configs Compact")
float_win = vim.api.nvim_get_current_win()
vim.cmd("write")
vim.wait(1000, function()
    return not vim.api.nvim_win_is_valid(float_win)
end, 20)
h.check("float closes after :w", not vim.api.nvim_win_is_valid(float_win))

reset()
setup({ ui = { edit = { close_on_write = false } } })
vim.cmd("OrchLaunchEdit configs Compact")
local keep_win = vim.api.nvim_get_current_win()
vim.cmd("write")
vim.wait(300, function()
    return false
end, 20)
h.check("close_on_write = false keeps the float open", vim.api.nvim_win_is_valid(keep_win))
vim.api.nvim_buf_set_lines(0, 0, 0, false, { "// dirty" })
h.check("close_float refuses to drop unsaved edits", require("orchlaunch.edit").close_float() == false)
setup()

h.done("buffer editing commands")
