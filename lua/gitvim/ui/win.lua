--- The sidebar's window and scratch buffer.
---
--- A plain `nvim_open_win` split rather than a float: the sidebar is a dock,
--- it has to survive `<C-w>` motions, `:only` should be able to kill it, and a
--- float would sit on top of the code instead of beside it.
---
--- `stack` mode (Plan.md D2) puts gitvim *below* whatever already owns the
--- side column -- snacks.explorer, neo-tree, nvim-tree -- instead of opening a
--- second column and halving the editing area.

local M = {}

--- Window-local options. `winfixwidth` is the one that matters: without it
--- every `:split` elsewhere steals columns from the sidebar.
local WIN_OPTIONS = {
  number = false,
  relativenumber = false,
  signcolumn = "no",
  foldcolumn = "0",
  foldenable = false,
  wrap = false,
  list = false,
  spell = false,
  cursorline = true,
  cursorcolumn = false,
  statuscolumn = "",
  winfixwidth = true,
  winhighlight = table.concat({
    "Normal:GitVimNormal",
    "NormalNC:GitVimNormal",
    "EndOfBuffer:GitVimNormal",
    "WinSeparator:GitVimSeparator",
  }, ","),
}

local BUF_OPTIONS = {
  buftype = "nofile",
  bufhidden = "hide",
  swapfile = false,
  buflisted = false,
  modifiable = false,
  undolevels = -1,
  filetype = "gitvim",
}

---@class gitvim.ui.Win
---@field buf integer      scratch buffer, outlives the window
---@field win integer?     nil while closed
---@field position "left"|"right"
---@field width integer    remembered across toggles
---@field stack boolean
local Win = {}
Win.__index = Win

---@class gitvim.ui.WinOpts
---@field position? "left"|"right"
---@field width? integer
---@field stack? boolean
---@field name? string     buffer name shown in `:ls`

---@param opts? gitvim.ui.WinOpts
---@return gitvim.ui.Win
function M.new(opts)
  opts = opts or {}
  local self = setmetatable({
    buf = nil,
    win = nil,
    position = opts.position or "left",
    width = opts.width or 40,
    stack = opts.stack or false,
    name = opts.name or "gitvim://sidebar",
  }, Win)
  self:_ensure_buf()
  return self
end

--- Create the scratch buffer, or re-create it if something wiped it out.
---
--- The buffer is deliberately longer-lived than the window: closing and
--- reopening the sidebar keeps its contents, its extmarks and its local
--- keymaps, so a toggle is cheap and the cursor lands where it was.
function Win:_ensure_buf()
  if self.buf and vim.api.nvim_buf_is_valid(self.buf) then
    return self.buf
  end

  self.buf = vim.api.nvim_create_buf(false, true)
  for name, value in pairs(BUF_OPTIONS) do
    vim.bo[self.buf][name] = value
  end
  pcall(vim.api.nvim_buf_set_name, self.buf, self.name)
  return self.buf
end

--- The non-floating window currently occupying the target side column, if any.
---
--- Used by `stack` mode to find a host to split. Screen position is the only
--- reliable test: the explorer plugins do not agree on a filetype, a variable
--- or a name.
---@return integer?
function Win:_column_host()
  local best, best_height
  for _, win in ipairs(vim.api.nvim_tabpage_list_wins(0)) do
    local cfg = vim.api.nvim_win_get_config(win)
    if cfg.relative == "" and win ~= self.win then
      local row_col = vim.api.nvim_win_get_position(win)
      local col = row_col[2]
      local touches
      if self.position == "left" then
        touches = col == 0
      else
        touches = col + vim.api.nvim_win_get_width(win) >= vim.o.columns - 1
      end
      if touches then
        -- Prefer the tallest window in the column: splitting the shortest one
        -- would give gitvim a two-line pane.
        local height = vim.api.nvim_win_get_height(win)
        if not best_height or height > best_height then
          best, best_height = win, height
        end
      end
    end
  end
  return best
end

---@return boolean
function Win:is_open()
  return self.win ~= nil and vim.api.nvim_win_is_valid(self.win)
end

--- Open the window, or do nothing if it already is.
---@param enter? boolean  move the cursor into it (default false)
---@return integer? win
function Win:open(enter)
  self:_ensure_buf()

  if self:is_open() then
    if enter then
      vim.api.nvim_set_current_win(self.win)
    end
    return self.win
  end

  local host = self.stack and self:_column_host() or nil
  ---@type vim.api.keyset.win_config
  local cfg
  if host then
    cfg = { split = "below", win = host }
  else
    -- `win = -1` splits the whole tabpage, i.e. a full-height `:topleft
    -- vsplit`, which is what a dock has to be.
    cfg = { split = self.position, win = -1, width = self.width }
  end

  local ok, win = pcall(vim.api.nvim_open_win, self.buf, enter == true, cfg)
  if not ok then
    vim.notify("gitvim: could not open the sidebar: " .. tostring(win), vim.log.levels.ERROR)
    return nil
  end
  self.win = win

  for name, value in pairs(WIN_OPTIONS) do
    pcall(function()
      vim.wo[win][name] = value
    end)
  end
  -- 'winfixbuf' pins the buffer so `:bnext` and friends cannot hijack the
  -- sidebar. Neovim 0.10+; guarded because the cost of missing it is small.
  pcall(function()
    vim.wo[win].winfixbuf = true
  end)

  if not host then
    vim.api.nvim_win_set_width(win, self.width)
  end

  vim.api.nvim_create_autocmd("WinClosed", {
    pattern = tostring(win),
    once = true,
    desc = "gitvim: forget the sidebar window",
    callback = function()
      -- Fires just before the window goes away, while it can still be
      -- measured -- the only chance to catch the width when the user closed
      -- us with `:q` or `:only` rather than through `close()`.
      if self.win == win then
        self:remember_width()
        self.win = nil
      end
    end,
  })

  return win
end

--- Record the current width, so `close()` -> `open()` is visually a no-op.
function Win:remember_width()
  if self:is_open() then
    local width = vim.api.nvim_win_get_width(self.win)
    if width > 0 then
      self.width = width
    end
  end
end

function Win:close()
  if not self:is_open() then
    self.win = nil
    return
  end
  self:remember_width()
  local win = self.win
  self.win = nil
  -- `force` because the scratch buffer is never modified; `pcall` because
  -- closing the last window is an error we would rather ignore than raise.
  pcall(vim.api.nvim_win_close, win, true)
end

--- Move the cursor into the sidebar, opening it if needed.
function Win:focus()
  if self:is_open() then
    vim.api.nvim_set_current_win(self.win)
  else
    self:open(true)
  end
end

---@return boolean focused
function Win:is_focused()
  return self:is_open() and vim.api.nvim_get_current_win() == self.win
end

--- Open + focus, or close if already focused.
---
--- Toggling from another window focuses rather than closes: that is what
--- every dock in every editor does, and it is what a `<leader>g` press means
--- when the sidebar is visible but the cursor is in the code.
function Win:toggle()
  if self:is_focused() then
    self:close()
  else
    self:focus()
  end
end

--- Apply a changed `position` / `width` / `stack`, reopening if necessary.
---@param opts gitvim.ui.WinOpts
function Win:reconfigure(opts)
  local reopen = self:is_open()
    and (
      (opts.position and opts.position ~= self.position)
      or (opts.stack ~= nil and opts.stack ~= self.stack)
    )

  self.position = opts.position or self.position
  if opts.stack ~= nil then
    self.stack = opts.stack
  end
  if opts.width then
    self.width = opts.width
  end

  if reopen then
    self:close()
    self:open(false)
  elseif self:is_open() and opts.width then
    vim.api.nvim_win_set_width(self.win, self.width)
  end
end

--- Usable width for rendering, i.e. what a line may occupy before it wraps.
---@return integer
function Win:content_width()
  if not self:is_open() then
    return self.width
  end
  return vim.api.nvim_win_get_width(self.win)
end

--- Close the window and wipe the buffer. Only for `reset()` paths and tests.
function Win:destroy()
  self:close()
  if self.buf and vim.api.nvim_buf_is_valid(self.buf) then
    pcall(vim.api.nvim_buf_delete, self.buf, { force = true })
  end
  self.buf = nil
end

return M
