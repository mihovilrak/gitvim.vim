--- The chunk builder: rows of `{ text, hl, action }` -> buffer lines + extmarks.
---
--- Every tab describes what it wants as a plain Lua table and hands it to a
--- `Renderer`. Nothing above this file touches `nvim_buf_set_lines` or
--- `nvim_buf_set_extmark`, which means a tab's output can be asserted in a
--- test as data, without a window ever existing.
---
--- Redraws are incremental: the longest unchanged prefix and suffix are left
--- alone, so a status refresh that only moves one file between groups rewrites
--- one line rather than the whole sidebar. That matters for the cursor, which
--- `nvim_buf_set_lines` would otherwise yank back to the top on every refresh.

local M = {}

---@class gitvim.render.Chunk
---@field text string
---@field hl? string       highlight group for this chunk only
---@field action? string   dispatched when this chunk is clicked
---@field arg? any         payload handed to the action

---@class gitvim.render.Row
---@field [integer] gitvim.render.Chunk
---@field hl? string       highlight for the whole line, including past the end
---@field action? string   fallback action for clicks that miss every chunk
---@field arg? any
---@field data? any        the domain object this row stands for
---@field virt? gitvim.render.Chunk[]  right-aligned virtual text (never virt_lines)

--- Click handlers reachable from `'winbar'` / `'statusline'` `%@` items, which
--- can only call a global. Keyed by name; `register()` owns the table.
---@type table<string, function>
_G._GitVim = _G._GitVim or {}

--- Expose a function to statusline-format `%@` click items.
---
--- Returns the expression `'winbar'` needs, so callers never hand-write the
--- `v:lua.` prefix and the name can never drift from the table key.
---@param name string
---@param fn function
---@return string  e.g. "v:lua._GitVim.gitvim_tab_click"
function M.register(name, fn)
  _G._GitVim[name] = fn
  return "v:lua._GitVim." .. name
end

---@class gitvim.render.Renderer
---@field buf integer
---@field ns integer
---@field private _rows gitvim.render.Row[]
---@field private _lines string[]
---@field private _keys string[]
local Renderer = {}
Renderer.__index = Renderer

--- Namespaces are per tab, so one tab's redraw can never clear another's marks
--- in a shared buffer.
---@type table<string, integer>
local namespaces = {}

---@param name string
---@return integer
function M.namespace(name)
  if not namespaces[name] then
    namespaces[name] = vim.api.nvim_create_namespace("gitvim_" .. name)
  end
  return namespaces[name]
end

--- A renderer bound to a buffer and a namespace.
---@param buf integer
---@param ns_name string
---@return gitvim.render.Renderer
function M.new(buf, ns_name)
  return setmetatable({
    buf = buf,
    ns = M.namespace(ns_name),
    _rows = {},
    _lines = {},
    _keys = {},
  }, Renderer)
end

--- Flatten a row to its text, and record each chunk's byte span.
---
--- Spans are byte offsets because that is what `getmousepos()` reports and
--- what extmark columns take; converting to characters here would make every
--- non-ASCII path mis-hit.
---@param row gitvim.render.Row
---@return string line, integer[] starts, integer[] stops
local function flatten(row)
  local parts, starts, stops = {}, {}, {}
  local col = 0
  for i, chunk in ipairs(row) do
    local text = chunk.text or ""
    parts[i] = text
    starts[i] = col
    col = col + #text
    stops[i] = col
  end
  return table.concat(parts), starts, stops
end

--- A string capturing everything about a row that affects the screen.
---
--- Rows compare equal only when they would render identically, so the
--- incremental diff below never skips a line whose highlight changed but whose
--- text did not.
---@param row gitvim.render.Row
---@param line string
---@return string
local function key(row, line)
  local parts = { line, "\1", row.hl or "" }
  for _, chunk in ipairs(row) do
    parts[#parts + 1] = "\2"
    parts[#parts + 1] = chunk.hl or ""
    parts[#parts + 1] = "\3"
    parts[#parts + 1] = chunk.action or ""
  end
  for _, chunk in ipairs(row.virt or {}) do
    parts[#parts + 1] = "\4"
    parts[#parts + 1] = chunk.text or ""
    parts[#parts + 1] = "\3"
    parts[#parts + 1] = chunk.hl or ""
  end
  return table.concat(parts)
end

--- Apply one row's highlights and virtual text. `lnum` is 0-based.
---@param lnum integer
---@param row gitvim.render.Row
function Renderer:_mark(lnum, row)
  if row.hl then
    vim.api.nvim_buf_set_extmark(self.buf, self.ns, lnum, 0, {
      line_hl_group = row.hl,
    })
  end

  for i, chunk in ipairs(row) do
    if chunk.hl and row._stops[i] > row._starts[i] then
      vim.api.nvim_buf_set_extmark(self.buf, self.ns, lnum, row._starts[i], {
        end_col = row._stops[i],
        hl_group = chunk.hl,
      })
    end
  end

  if row.virt and #row.virt > 0 then
    local text = {}
    for i, chunk in ipairs(row.virt) do
      text[i] = { chunk.text or "", chunk.hl or "GitVimButton" }
    end
    -- right_align, never virt_lines: an extra screen line desynchronizes the
    -- review view's two panes (D3), and the rule is cheaper to keep global.
    vim.api.nvim_buf_set_extmark(self.buf, self.ns, lnum, 0, {
      virt_text = text,
      virt_text_pos = "right_align",
    })
  end
end

--- Replace the buffer's contents with `rows`, touching only what changed.
---@param rows gitvim.render.Row[]
function Renderer:set(rows)
  if not vim.api.nvim_buf_is_valid(self.buf) then
    return
  end

  local lines, keys = {}, {}
  for i, row in ipairs(rows) do
    local line, starts, stops = flatten(row)
    row._starts, row._stops = starts, stops
    lines[i] = line
    keys[i] = key(row, line)
  end

  local old_keys = self._keys
  local n_new, n_old = #lines, #old_keys

  -- Longest identical prefix, then longest identical suffix of what is left.
  local head = 0
  while head < n_new and head < n_old and keys[head + 1] == old_keys[head + 1] do
    head = head + 1
  end

  local tail = 0
  while
    tail < n_new - head
    and tail < n_old - head
    and keys[n_new - tail] == old_keys[n_old - tail]
  do
    tail = tail + 1
  end

  self._rows = rows
  self._lines = lines
  self._keys = keys

  if head == n_new and n_new == n_old then
    return -- nothing changed
  end

  -- Marks inside the span about to be replaced would *collapse* onto its
  -- first line rather than disappearing with it, so they are dropped before
  -- the splice, not after. Marks in the untouched prefix and suffix are
  -- shifted by the splice itself and stay correct.
  vim.api.nvim_buf_clear_namespace(self.buf, self.ns, head, n_old - tail)

  local middle = vim.list_slice(lines, head + 1, n_new - tail)
  local was_modifiable = vim.bo[self.buf].modifiable
  vim.bo[self.buf].modifiable = true
  -- `-1` rather than `n_old` when no suffix matched: a fresh scratch buffer
  -- holds one empty line that belongs to no row, and replacing through to the
  -- end is what takes it back out again.
  local stop = tail == 0 and -1 or n_old - tail
  vim.api.nvim_buf_set_lines(self.buf, head, stop, false, middle)
  vim.bo[self.buf].modifiable = was_modifiable

  for i = head + 1, n_new - tail do
    self:_mark(i - 1, rows[i])
  end
end

--- Empty the buffer and drop every mark in this renderer's namespace.
function Renderer:clear()
  self:set({})
end

---@return gitvim.render.Row[]
function Renderer:rows()
  return self._rows
end

---@return string[]
function Renderer:lines()
  return self._lines
end

--- The row on a 1-based line, or nil past the end.
---@param lnum integer
---@return gitvim.render.Row?
function Renderer:at(lnum)
  return self._rows[lnum]
end

--- Resolve a click to an action.
---
--- A chunk with its own action wins inside its span; otherwise the row's
--- fallback action applies, so clicking anywhere on a file row opens the file
--- while clicking its `[+]` stages it.
---@param lnum integer  1-based
---@param col integer   0-based byte column
---@return string? action, any arg, gitvim.render.Row? row
function Renderer:hit(lnum, col)
  local row = self._rows[lnum]
  if not row then
    return nil, nil, nil
  end

  for i, chunk in ipairs(row) do
    if chunk.action and col >= row._starts[i] and col < row._stops[i] then
      return chunk.action, chunk.arg, row
    end
  end

  return row.action, row.arg, row
end

--- The first line whose row satisfies `pred`, for restoring the cursor across
--- a refresh that reordered things.
---@param pred fun(row: gitvim.render.Row): boolean
---@return integer?  1-based line
function Renderer:find(pred)
  for i, row in ipairs(self._rows) do
    if pred(row) then
      return i
    end
  end
  return nil
end

return M
