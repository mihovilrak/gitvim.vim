--- The sole adapter between gitvim and gitsigns.nvim.
---
--- Keeping every `require("gitsigns")` in this module makes the dependency
--- boundary explicit and, importantly, lets the rest of the buffer layer stay
--- inert when gitsigns is not installed.

local M = {}

---@type table?
local injected

---@return table?
local function adapter()
  if injected ~= nil then
    return injected or nil
  end
  local ok, gitsigns = pcall(require, "gitsigns")
  return ok and gitsigns or nil
end

---@param name string
---@param ... any
---@return boolean ok
---@return any result
local function call(name, ...)
  local gitsigns = adapter()
  local fn = gitsigns and gitsigns[name]
  if type(fn) ~= "function" then
    return false, "gitsigns.nvim is unavailable"
  end
  local ok, result = pcall(fn, ...)
  return ok, result
end

---@param opts? table
---@return boolean
function M.setup(opts)
  return call("setup", opts) == true
end

---@return boolean
function M.available()
  return adapter() ~= nil
end

---@param bufnr? integer
---@return table[]
function M.get_hunks(bufnr)
  local ok, hunks = call("get_hunks", bufnr or 0)
  return ok and hunks or {}
end

---@param bufnr? integer
---@param lnum? integer
---@return string
function M.statuscolumn(bufnr, lnum)
  local ok, value = call("statuscolumn", bufnr or 0, lnum)
  return ok and type(value) == "string" and value or ""
end

---@param range? [integer, integer]
---@return boolean
function M.stage_hunk(range)
  return call("stage_hunk", range) == true
end

---@param range? [integer, integer]
---@return boolean
function M.reset_hunk(range)
  return call("reset_hunk", range) == true
end

---@return boolean
function M.undo_stage_hunk()
  return call("undo_stage_hunk") == true
end

---@return boolean
function M.preview_hunk_inline()
  return call("preview_hunk_inline") == true
end

---@return boolean
function M.blame_line()
  return call("blame_line") == true
end

---@param value? boolean
---@return boolean? enabled
function M.toggle_blame(value)
  local ok, enabled = call("toggle_current_line_blame", value)
  return ok and enabled or nil
end

---@param direction "next"|"prev"
---@return boolean
function M.nav_hunk(direction)
  return call("nav_hunk", direction) == true
end

---@param bufnr? integer
---@return table?
function M.blame_info(bufnr)
  bufnr = bufnr or 0
  local ok, info = pcall(function()
    return vim.b[bufnr].gitsigns_blame_line_dict
  end)
  return ok and type(info) == "table" and info or nil
end

--- Test seam; `false` represents an unavailable dependency.
---@param value table|false|nil
function M._set_adapter(value)
  injected = value
end

return M
