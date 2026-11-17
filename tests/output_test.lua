-- Unit test: before-step output policy and captured values.
local here = vim.fn.fnamemodify(debug.getinfo(1, "S").source:sub(2), ":p:h")
package.path = here .. "/?.lua;" .. package.path
local h = require("harness")
local output = require("orchlaunch.runner.output")

-- log normalization
h.eq("default log is none", output.normalize_log(nil), "none")
h.eq("errorsOnly accepted", output.normalize_log("errorsOnly"), "errorsOnly")
h.eq("console accepted", output.normalize_log("console"), "console")
local _, err = output.normalize_log("loud")
h.check("unknown mode is rejected", err ~= nil, err)
local file_log = output.normalize_log({ file = "/tmp/x.log" })
h.eq("file log keeps its path", file_log and file_log.file, "/tmp/x.log")
local _, err2 = output.normalize_log({ file = "" })
h.check("empty file path is rejected", err2 ~= nil, err2)

-- captured values
h.eq("trailing newline removed", output.capture_value("linux\n"), "linux")
h.eq("several trailing newlines removed", output.capture_value("a\r\n\n"), "a")
h.eq("inner newline kept", output.capture_value("a\nb\n"), "a\nb")
h.eq("nil capture is empty", output.capture_value(nil), "")

-- tail
local twenty = {}
for i = 1, 25 do twenty[#twenty + 1] = "line" .. i end
local tail = output.tail(table.concat(twenty, "\n"), 3)
h.eq("tail keeps the last lines", tail, "line23\nline24\nline25")
h.eq("tail of short text is the whole text", output.tail("only"), "only")

-- plan: success
h.eq("none: success is silent", output.plan("none", { code = 0, stdout = "ok" }, true).level, "none")
h.eq("errorsOnly: success is silent", output.plan("errorsOnly", { code = 0, stdout = "ok" }, true).level, "none")
h.eq("console: success shows text", output.plan("console", { code = 0, stdout = "ok" }, true).text, "ok")
h.eq("file: success goes to file", output.plan({ file = "f" }, { code = 0, stdout = "ok" }, true).file_text, "ok")

-- plan: failure
local failed = { code = 2, stdout = "out", stderr = "boom" }
h.eq("none: failure shows stderr tail", output.plan("none", failed, false).text, "boom")
h.eq("errorsOnly: failure shows everything", output.plan("errorsOnly", failed, false).text, "out\nboom")
h.eq("console: failure shows everything", output.plan("console", failed, false).text, "out\nboom")
h.eq("failure level is error", output.plan("none", failed, false).level, "error")

h.done("before-step output")
