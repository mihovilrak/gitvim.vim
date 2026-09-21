--- Read-only SOURCE CONTROL section.
---
--- Status data is fetched asynchronously and kept in the repo-keyed store.
--- This module only turns that data into rows, which keeps rendering
--- deterministic and makes every porcelain group testable without a window.

local config = require("gitvim.config")
local hl = require("gitvim.ui.hl")
local icons = require("gitvim.ui.icons")
local tabs = require("gitvim.ui.tabs")

local M = {}

local LABELS = {
  merge = "Merge Changes",
  staged = "Staged",
  changes = "Changes",
  untracked = "Untracked",
  ignored = "Ignored",
}

---@param store gitvim.Store
---@param group string
---@return boolean
local function collapsed(store, group)
  local value = store.collapsed[group]
  if value == nil then
    return vim.tbl_contains(config.options.scm.collapsed, group)
  end
  return value == true
end

--- Append a repository-relative path as a dim directory and bright basename.
---@param row gitvim.render.Row
---@param path string
---@param file_hl string
local function append_path(row, path, file_hl)
  local dir, base = path:match("^(.*[/])([^/]*)$")
  if dir then
    row[#row + 1] = { text = dir, hl = "GitVimDir" }
    row[#row + 1] = { text = base, hl = file_hl }
  else
    row[#row + 1] = { text = path, hl = file_hl }
  end
end

---@param entry gitvim.status.Entry
---@return gitvim.render.Row
local function entry_row(entry)
  local kind_hl = hl.kind[entry.kind] or "GitVimFile"
  local icon, icon_hl = icons.file(entry.path, false)
  ---@type gitvim.render.Row
  local row = {
    { text = "  " },
    { text = icons.status(entry.kind), hl = kind_hl },
    { text = " " },
  }

  if icon ~= "" then
    row[#row + 1] = { text = icon, hl = icon_hl }
    row[#row + 1] = { text = " " }
  end

  if entry.orig_path and (entry.kind == "renamed" or entry.kind == "copied") then
    append_path(row, entry.orig_path, kind_hl)
    row[#row + 1] = { text = " → ", hl = "GitVimDir" }
  end
  append_path(row, entry.path, kind_hl)
  row.data = entry
  return row
end

---@param ctx gitvim.ui.TabCtx
---@return gitvim.render.Row[]
function M.rows(ctx)
  if not ctx.store then
    return tabs.no_repo()
  end
  if not ctx.store.status then
    return { tabs.hint("Loading status...") }
  end

  local groups = ctx.store:groups()
  local rows = {}
  for _, group in ipairs(config.options.scm.groups) do
    local entries = groups[group] or {}
    if #entries > 0 then
      local open = not collapsed(ctx.store, group)
      local header = tabs.header({
        text = LABELS[group] or group,
        open = open,
        action = "toggle_group",
        arg = group,
        count = #entries,
        hl = "GitVimGroup",
      })
      header.data = { type = "scm_group", group = group }
      rows[#rows + 1] = header

      if open then
        for _, entry in ipairs(entries) do
          rows[#rows + 1] = entry_row(entry)
        end
      end
    end
  end

  if #rows == 0 then
    rows[1] = tabs.hint("No changes.")
  end
  return rows
end

M.actions = {
  ---@param ctx gitvim.ui.TabCtx
  ---@param group string
  toggle_group = function(ctx, group)
    if ctx.store and group then
      ctx.store.collapsed[group] = not collapsed(ctx.store, group)
    end
  end,
}

return M
