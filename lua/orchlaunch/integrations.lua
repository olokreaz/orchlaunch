-- OrchLaunch — optional integrations with the wider Neovim ecosystem.
--
-- Diagnostics and debugging surfaces are not reimplemented here: build output
-- is pushed into the standard quickfix list (read by trouble.nvim, snacks.nvim,
-- `:copen`, …) and the debugger UI is delegated to nvim-dap-view or nvim-dap-ui
-- when either is installed. The built-in fibrous panel remains the fallback.

local M = {}

-- GCC/Clang/Ninja style: `file:line:col: error: message` and friends.
local EFM = table.concat({
    "%f:%l:%c: %t%*[^:]: %m",
    "%f:%l: %t%*[^:]: %m",
    "%f:%l:%c: %m",
    "%f:%l: %m",
}, ",")

--- Parses compiler output into the quickfix list.
---
--- Only lines matched by the errorformat are kept, so raw build chatter never
--- pollutes the list. Relative file names are resolved against `cwd` (usually
--- the CMake binary directory, where the compiler ran).
--- @param title string
--- @param output? string Combined stdout/stderr of the build step.
--- @param cwd? string Directory the output paths are relative to.
--- @return integer count Number of parsed diagnostics.
--- @return integer errors Number of diagnostics with `error` type.
function M.quickfix(title, output, cwd)
    if type(output) ~= "string" or output == "" then
        return 0, 0
    end

    local lines = vim.split(output, "\n", { trimempty = true })
    if #lines == 0 then
        return 0, 0
    end

    local previous
    if cwd and cwd ~= "" and vim.fn.isdirectory(cwd) == 1 then
        previous = vim.fn.getcwd()
        pcall(vim.cmd, ("noautocmd lcd %s"):format(vim.fn.fnameescape(cwd)))
    end

    local ok = pcall(vim.fn.setqflist, {}, " ", {
        title = title,
        lines = lines,
        efm = EFM,
    })

    if previous then
        pcall(vim.cmd, ("noautocmd lcd %s"):format(vim.fn.fnameescape(previous)))
    end

    if not ok then
        return 0, 0
    end

    local parsed = vim.fn.getqflist()
    local diagnostics, errors = {}, 0
    for _, item in ipairs(parsed) do
        if item.valid == 1 then
            diagnostics[#diagnostics + 1] = item
            if item.type == "e" then
                errors = errors + 1
            end
        end
    end

    if #diagnostics == 0 then
        pcall(vim.fn.setqflist, {}, " ", { title = title })
        return 0, 0
    end

    pcall(vim.fn.setqflist, {}, " ", { title = title })
    pcall(vim.fn.setqflist, diagnostics, "a")
    return #diagnostics, errors
end

--- Opens the best available debugger UI. Returns false when neither
--- nvim-dap-view nor nvim-dap-ui is installed, letting the caller fall back to
--- the built-in fibrous panel.
--- @return boolean opened
function M.debugger_ui()
    if vim.fn.exists(":DapViewToggle") == 2 then
        if pcall(vim.cmd, "DapViewToggle") then
            return true
        end
    end

    local ok, dapui = pcall(require, "dapui")
    if ok and dapui and dapui.toggle then
        if pcall(dapui.toggle, {}) then
            return true
        end
    end

    return false
end

return M
