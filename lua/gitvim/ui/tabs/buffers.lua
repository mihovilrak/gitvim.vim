--- The Buffers tab: what is open, right now.
---
--- Neovim's buffer list is the source of truth -- there is no separate model
--- to keep in sync -- so this tab is a projection of `nvim_list_bufs()` plus
--- the sort the user asked for.

local config = require("gitvim.config")
local icons = require("gitvim.ui.icons")
local tabs = require("gitvim.ui.tabs")

local M = {
  name = "buffers",
  title = "Buffers",
}

--- Last-used time per buffer, so `sort = "mru"` means something. Neovim does
--- not expose one, so we keep our own; a buffer we have never seen entered
--- sorts by its number, which is creation order.
---@type table<integer, integer>
local seen = {}

--- Bump the timestamp for a buffer. Wired up by the sidebar's `BufEnter`.
---@param buf integer
function M.touch(buf)
  seen[buf] = vim.uv.hrtime()
end

--- Drop remembered timestamps. Tests only.
function M.reset()
  seen = {}
end

--- Every buffer the tab should show.
---@return integer[]
local function list()
  local show_unlisted = config.options.buffers.show_unlisted
  local out = {}
  for _, buf in ipairs(vim.api.nvim_list_bufs()) do
    if vim.api.nvim_buf_is_valid(buf) then
      local listed = vim.bo[buf].buflisted
      -- The sidebar's own scratch buffer is never a thing you can switch to.
      local ours = vim.bo[buf].filetype == "gitvim"
      if not ours and (listed or show_unlisted) then
        out[#out + 1] = buf
      end
    end
  end

  if config.options.buffers.sort == "mru" then
    table.sort(out, function(a, b)
      local sa, sb = seen[a], seen[b]
      if sa and sb then
        return sa > sb
      end
      -- A buffer we have timestamps for was used more recently than one we
      -- have never seen entered, by definition.
      if sa or sb then
        return sa ~= nil
      end
      return a < b
    end)
  elseif config.options.buffers.sort == "name" then
    table.sort(out, function(a, b)
      local na = vim.fs.basename(vim.api.nvim_buf_get_name(a)):lower()
      local nb = vim.fs.basename(vim.api.nvim_buf_get_name(b)):lower()
      if na ~= nb then
        return na < nb
      end
      return a < b
    end)
  else -- "number": the `:ls` order
    table.sort(out)
  end

  return out
end

--- Display name for a buffer: its basename, or something honest for the
--- unnamed and the special.
---@param buf integer
---@return string name
---@return string? dir  parent directory, relative to the repo when inside it
local function label(buf, root)
  local path = vim.api.nvim_buf_get_name(buf)
  if path == "" then
    return "[No Name]", nil
  end

  local buftype = vim.bo[buf].buftype
  if buftype ~= "" and buftype ~= "acwrite" then
    return ("[%s]"):format(buftype), nil
  end

  local name = vim.fs.basename(path)
  local dir = vim.fs.dirname(path)
  if root and dir:sub(1, #root) == root then
    dir = dir:sub(#root + 2)
  else
    dir = vim.fn.fnamemodify(dir, ":~")
  end
  return name, dir ~= "" and dir or nil
end

---@param buf integer
---@param current integer  the buffer the editor window is showing
---@param root string?
---@return gitvim.render.Row
local function buffer_row(buf, current, root)
  local name, dir = label(buf, root)
  local icon, icon_hl = icons.file(vim.api.nvim_buf_get_name(buf), false)
  local modified = vim.bo[buf].modified

  ---@type gitvim.render.Row
  local row = {
    -- A marker column, so the current buffer is findable without colour.
    { text = buf == current and " " .. icons.get("current") .. " " or "   " },
  }
  if icon ~= "" then
    row[#row + 1] = { text = icon .. " ", hl = icon_hl }
  end
  row[#row + 1] = {
    text = name,
    hl = buf == current and "GitVimBufferCurrent" or "GitVimFile",
  }
  if modified then
    row[#row + 1] = { text = " " .. icons.get("modified"), hl = "GitVimModified" }
  end
  if dir and not config.options.buffers.group_by_dir then
    row[#row + 1] = { text = "  " .. dir, hl = "GitVimHint" }
  end

  row.action = "open"
  row.arg = buf
  row.data = { buf = buf }
  return row
end

---@param ctx gitvim.ui.TabCtx
---@return gitvim.render.Row[]
function M.rows(ctx)
  local bufs = list()
  local root = ctx.store and ctx.store.root or nil
  local current = vim.api.nvim_get_current_buf()

  local rows = { tabs.title("OPEN EDITORS", #bufs > 0 and tostring(#bufs) or nil) }

  if #bufs == 0 then
    rows[#rows + 1] = tabs.blank()
    rows[#rows + 1] = tabs.hint("No open buffers.")
    return rows
  end

  if not config.options.buffers.group_by_dir then
    for _, buf in ipairs(bufs) do
      rows[#rows + 1] = buffer_row(buf, current, root)
    end
    return rows
  end

  -- Grouped: one header per directory, buffers under it.
  local order, groups = {}, {}
  for _, buf in ipairs(bufs) do
    local _, dir = label(buf, root)
    dir = dir or "."
    if not groups[dir] then
      groups[dir] = {}
      order[#order + 1] = dir
    end
    table.insert(groups[dir], buf)
  end
  table.sort(order)

  for _, dir in ipairs(order) do
    rows[#rows + 1] = tabs.blank()
    rows[#rows + 1] = {
      { text = " " .. dir, hl = "GitVimDir" },
      { text = " " .. #groups[dir], hl = "GitVimCount" },
    }
    for _, buf in ipairs(groups[dir]) do
      rows[#rows + 1] = buffer_row(buf, current, root)
    end
  end

  return rows
end

M.actions = {
  --- Show a buffer in the editor window.
  ---@param buf integer
  open = function(_, buf)
    if buf and vim.api.nvim_buf_is_valid(buf) then
      require("gitvim.ui.sidebar").open_buf(buf)
    end
  end,

  --- Close a buffer without disturbing the window layout. A modified buffer
  --- is never discarded silently -- losing edits to a stray keypress in a
  --- sidebar is not a trade anyone would take.
  ---@param buf integer
  close = function(_, buf)
    if not buf or not vim.api.nvim_buf_is_valid(buf) then
      return
    end
    if vim.bo[buf].modified then
      vim.notify(
        ("gitvim: %s has unsaved changes"):format(vim.fs.basename(vim.api.nvim_buf_get_name(buf))),
        vim.log.levels.WARN
      )
      return
    end
    seen[buf] = nil
    pcall(vim.api.nvim_buf_delete, buf, {})
  end,

  ---@param buf integer
  save = function(_, buf)
    if buf and vim.api.nvim_buf_is_valid(buf) and vim.bo[buf].modified then
      vim.api.nvim_buf_call(buf, function()
        vim.cmd("silent write")
      end)
    end
  end,
}

M.keys = {
  ["d"] = "close",
  ["<C-x>"] = "close",
  ["s"] = "save",
}

return M
