-- OrchLaunch debug types (internal contract)
local M = {}

-- Example public shapes (informative)
-- Thread: { id=number, name=string?, state="stopped"|"running"|"exited"?, selected=boolean }
-- Frame:  { id=number, thread_id=number, line=number, column=number?, name=string, source=table?, address=string? }
-- Scope:  { name=string, expensive=boolean?, variablesReference=number, frame_id=number }
-- Var:    { name=string, value=string, type=string?, variablesReference=number, indexedVariables=number?, namedVariables=number? }

return M
