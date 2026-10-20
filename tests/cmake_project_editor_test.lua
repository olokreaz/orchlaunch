-- CMake project directory editor (fibrous).

local here = vim.fn.fnamemodify(debug.getinfo(1, "S").source:sub(2), ":p:h")
package.path = here .. "/?.lua;" .. package.path
local h = require("harness")

if not (pcall(require, "fibrous")) then
    print("SKIP  fibrous is not installed")
    h.done("CMake project editor (skipped)")
    return
end

local root = h.tempdir()
vim.fn.mkdir(root .. "/boo", "p")

local orch = require("orchlaunch")
local state = require("orchlaunch.state")
local editor = require("orchlaunch.ui.fibrous.editors.cmake_project")

orch.create_project(root)

local saved = false
local handle = editor.open(function()
    saved = true
end)
vim.wait(150)
h.check("editor renders", handle ~= nil and handle.orch ~= nil)
h.check("has source_dir field", handle.orch.values.source_dir ~= nil)

handle.orch.set("source_dir", "${workspace}/boo")
handle.orch.save()
vim.wait(100)

h.check("on_saved fired", saved)
h.eq("raw source dir persisted", state.cmake_source_dir_raw(), "${workspace}/boo")
h.eq("resolved source dir", state.cmake_source_dir(), root .. "/boo")

h.done("CMake project editor")
