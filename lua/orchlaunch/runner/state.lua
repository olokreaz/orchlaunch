-- OrchLaunch — the one cancellable step that may be running (a CMake step, a
-- native launch, or the CMake load). Shared by every runner part so that
-- `cancel` and the finish handlers always see the same job.

local M = {}

local active_job = nil
local active_label = nil

--- Returns the running job and its label, if any.
---@return vim.SystemObj? job
---@return string? label
function M.get()
    return active_job, active_label
end

--- Records `job` as the running step.
---@param job vim.SystemObj
---@param label string
function M.set(job, label)
    active_job = job
    active_label = label
end

--- Forgets the running step (without killing it).
function M.clear()
    active_job = nil
    active_label = nil
end

--- Clears the running step only if it is still `job`. A finished older job
--- must not erase a newer one that has taken over.
---@param job vim.SystemObj
function M.clear_if(job)
    if active_job == job then
        M.clear()
    end
end

return M
