-- Unit test: output policy for before-step process steps.
local here = vim.fn.fnamemodify(debug.getinfo(1, "S").source:sub(2), ":p:h")
package.path = here .. "/?.lua;" .. package.path
local h = require("harness")
local output = require("orchlaunch.runner.output")

-- policy normalization
h.eq("default policy is showIfError", output.normalize_log(nil), "showIfError")
h.eq("none accepted", output.normalize_log("none"), "none")
h.eq("show accepted", output.normalize_log("show"), "show")
local _, err = output.normalize_log("loud")
h.check("unknown policy is rejected", err ~= nil, err)
h.eq("file policy keeps its path", output.normalize_log({ file = "/tmp/x.log" }).file, "/tmp/x.log")
local _, err2 = output.normalize_log({ file = "" })
h.check("empty file path is rejected", err2 ~= nil, err2)

-- before-level default, overridden by the step
h.eq("step wins over before", output.effective_log("show", "none"), "none")
h.eq("before applies when step is silent", output.effective_log("show", nil), "show")
h.eq("nothing set gives nil (then showIfError)", output.effective_log(nil, nil), nil)

-- captured values
h.eq("trailing newlines removed", output.capture_value("linux\n\n"), "linux")
h.eq("inner newline kept", output.capture_value("a\nb\n"), "a\nb")

-- tagged lines keep the stream
local lines = output.tagged_lines("exec uname", { stdout = "Linux\n", stderr = "warn\nmore" })
h.eq("header names the step", lines[1], "== exec uname ==")
h.eq("stdout lines tagged [out]", lines[2], "[out] Linux")
h.eq("stderr lines tagged [err]", lines[3], "[err] warn")
h.eq("second stderr line tagged", lines[4], "[err] more")

-- last line for the none policy
h.eq("last line prefers stderr", output.last_line({ stdout = "ok", stderr = "a\nboom" }), "boom")
h.eq("last line falls back to stdout", output.last_line({ stdout = "x\ny" }), "y")

-- decide: success
h.eq("none + success: nothing", output.decide("none", true, "s", {}).action, "none")
local ok_default = output.decide("showIfError", true, "s", { stdout = "out" })
h.eq("showIfError + success: window, not opened", ok_default.action, "window")
h.eq("showIfError + success keeps the output", ok_default.open, false)
h.eq("show + success: window, opened", output.decide("show", true, "s", {}).open, true)
h.eq("file: goes to the file", output.decide({ file = "/x" }, true, "s", {}).action, "file")

-- decide: failure
local failed = { stdout = "out", stderr = "boom" }
local err_default = output.decide("showIfError", false, "s", failed)
h.eq("showIfError + failure: window opened", err_default.open, true)
h.eq("showIfError + failure: output kept", #err_default.lines, 3)
local err_none = output.decide("none", false, "exec x", failed)
h.eq("none + failure: notify, not window", err_none.action, "notify")
h.eq("none + failure: last stderr line", err_none.text, "exec x failed: boom")
h.eq("file + failure: still filed", output.decide({ file = "/x" }, false, "s", failed).action, "file")

h.done("before-step output")
