--- Small utilities shared by the specs.

local M = {}

--- Drive an async gitvim call to completion inside a synchronous test.
---
--- Every callback in gitvim is scheduled onto the main loop, so a plain
--- `:wait()` would deadlock; `vim.wait` keeps pumping it instead.
---@generic T
---@param fn fun(done: fun(...))  invoke `done` with whatever the callback got
---@param timeout? integer        milliseconds, default 10000
---@return any ... the values passed to `done`
function M.await(fn, timeout)
  local result, called = nil, false
  fn(function(...)
    result = table.pack(...)
    called = true
  end)
  local ok = vim.wait(timeout or 10000, function()
    return called
  end, 10)
  assert(ok, "timed out waiting for an async gitvim call")
  return unpack(result, 1, result.n)
end

--- Find the entry for a path in a parsed status result.
---@param result gitvim.status.Result
---@param path string
---@param group? gitvim.status.Group
---@return gitvim.status.Entry?
function M.entry(result, path, group)
  for _, e in ipairs(result.entries) do
    if e.path == path and (not group or e.group == group) then
      return e
    end
  end
  return nil
end

return M
