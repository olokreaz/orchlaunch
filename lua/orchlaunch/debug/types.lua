-- OrchLaunch debug types (internal contract).
--
-- The public shapes below are informative; the backend contract itself is
-- documented in `orchlaunch.debug.backend`.
--
-- Thread: { id=number, name=string?, state="stopped"|"running"|"exited"?, selected=boolean }
-- Frame:  { id=number, thread_id=number, line=number, column=number?, name=string, source=table?, address=string? }
-- Scope:  { name=string, expensive=boolean?, variablesReference=number, frame_id=number }
-- Var:    { name=string, value=string, type=string?, variablesReference=number, indexedVariables=number?, namedVariables=number? }
--
-- Request: backend-neutral input to a backend (see `OrchDebugRequest`).
-- Backend: adapter + launch/attach config producers (see `OrchDebugBackend`).

return {}
