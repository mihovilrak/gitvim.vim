--- The sidebar: one dock, four activity tabs.
---
--- This is the only module that owns editor state. Tabs are pure -- they turn
--- a context into rows -- `render` owns the buffer, `win` owns the window, and
--- everything here is the wiring between them: which tab is showing, what the
--- winbar says, which keymaps are live, and where a click lands.
---
--- Every mouse interaction has a keyboard equivalent (Plan.md D5): the winbar
--- tabs are clickable *and* reachable with `<Tab>` / `<S-Tab>` / `1`-`4`, and
--- a row click is the same dispatch `<CR>` goes through.

local config = require("gitvim.config")
local icons = require("gitvim.ui.icons")
local render = require("gitvim.ui.render")
local state = require("gitvim.state")
local tabs = require("gitvim.ui.tabs")
local win_mod = require("gitvim.ui.win")

local M = {}

--- Live sidebar state. A single dock per Neovim instance: two docks showing
--- the same repository would be two things to keep in sync for no gain.
local sb = {
  ---@type gitvim.ui.Win?
  win = nil,
  ---@type gitvim.render.Renderer?
  renderer = nil,
  ---@type gitvim.Tab?
  tab = nil,
  --- Cursor line per tab, so switching away and back lands where you left.
  ---@type table<string, integer>
  cursor = {},
  --- lhs values currently mapped in the buffer, so a tab switch can take its
  --- predecessor's keymaps back out again.
  ---@type string[]
  mapped = {},
  --- Line to put the cursor on at the next redraw, set by a tab switch.
  ---@type integer?
  pending = nil,
  --- The window a file should open in.
  ---@type integer?
  editor_win = nil,
  --- Set while a `reach` action runs, so the redraw it causes cannot
  --- re-enter it.
  reaching = false,
  wired = false,
}

--- Winbar click target. Registered once: `'winbar'` can only call a global,
--- and re-registering on every redraw would leak entries.
local TAB_CLICK = render.register("sidebar_tab", function(minwid)
  local names = config.options.sidebar.tabs
  local name = names[minwid]
  if name then
    M.select_tab(name)
  end
end)

-- ---------------------------------------------------------------------------
-- context
-- ---------------------------------------------------------------------------

---@return gitvim.ui.TabCtx
local function ctx()
  local repo = require("gitvim.git.repo").active()
  return {
    repo = repo,
    store = repo and state.get(repo.root) or nil,
    width = sb.win and sb.win:content_width() or config.options.sidebar.width,
    focused = sb.win ~= nil and sb.win:is_focused(),
  }
end

---@return gitvim.ui.Tab?
local function current_tab()
  return sb.tab and tabs.get(sb.tab) or nil
end

---@return boolean
function M.is_open()
  return sb.win ~= nil and sb.win:is_open()
end

-- ---------------------------------------------------------------------------
-- the editor window
-- ---------------------------------------------------------------------------

--- A window a file may be opened in: the last one the user was in, or any
--- ordinary window that is not us, or a fresh split if the sidebar is all
--- there is.
---@return integer
local function editor_window()
  if
    sb.editor_win
    and vim.api.nvim_win_is_valid(sb.editor_win)
    and (not sb.win or sb.editor_win ~= sb.win.win)
  then
    return sb.editor_win
  end

  for _, win in ipairs(vim.api.nvim_tabpage_list_wins(0)) do
    local ok = vim.api.nvim_win_get_config(win).relative == ""
    if ok and (not sb.win or win ~= sb.win.win) then
      sb.editor_win = win
      return win
    end
  end

  -- Only the sidebar is left: open a neighbour rather than replacing our own
  -- buffer, which `winfixbuf` would refuse anyway.
  local side = config.options.sidebar.position == "left" and "right" or "left"
  local win = vim.api.nvim_open_win(vim.api.nvim_create_buf(true, false), false, {
    split = side,
    win = sb.win and sb.win.win or 0,
  })
  sb.editor_win = win
  return win
end

--- The window files open in: never the sidebar, created beside it if need be.
--- The review view takes it over for its right-hand pane.
---@return integer
function M.editor_window()
  return editor_window()
end

--- The buffer in the editor window, without creating one: nil when the
--- sidebar is the only window there is.
---@return integer?
function M.editor_buf()
  local win = sb.editor_win
  local side = sb.win and sb.win.win
  if not (win and vim.api.nvim_win_is_valid(win) and win ~= side) then
    win = vim.api.nvim_get_current_win()
    if win == side or vim.api.nvim_win_get_config(win).relative ~= "" then
      return nil
    end
  end
  return vim.api.nvim_win_get_buf(win)
end

--- Show a file in the editor window, optionally at a position.
---@param path string
---@param pos? integer[]  { lnum, col } with a 0-based byte col, as nvim_win_set_cursor
function M.open_file(path, pos)
  local win = editor_window()
  vim.api.nvim_win_call(win, function()
    vim.cmd.edit(vim.fn.fnameescape(path))
    if pos then
      local last = vim.api.nvim_buf_line_count(0)
      pcall(vim.api.nvim_win_set_cursor, win, { math.min(pos[1], last), pos[2] or 0 })
      vim.cmd("normal! zv")
    end
  end)
  vim.api.nvim_set_current_win(win)
  if config.options.sidebar.close_on_open then
    M.close()
  end
end

--- Show an existing buffer in the editor window.
---@param buf integer
function M.open_buf(buf)
  local win = editor_window()
  vim.api.nvim_win_set_buf(win, buf)
  vim.api.nvim_set_current_win(win)
  if config.options.sidebar.close_on_open then
    M.close()
  end
end

-- ---------------------------------------------------------------------------
-- actions
-- ---------------------------------------------------------------------------

--- Actions every tab gets for free.
---@type table<string, fun(ctx: gitvim.ui.TabCtx, arg: any, row: gitvim.render.Row)>
local GLOBAL_ACTIONS = {
  refresh = function(c)
    -- An explicit refresh re-reads history too, which the status signature
    -- alone would miss (a new tag, a fetched remote branch).
    if c.store then
      c.store:mark_dirty("graph")
      c.store:mark_dirty("timeline")
    end
    require("gitvim").refresh(function(err)
      if err then
        vim.notify(require("gitvim.git.cli").format_error(err), vim.log.levels.ERROR)
      end
    end)
  end,
  close = function()
    M.close()
  end,
  next_tab = function()
    M.cycle(1)
  end,
  prev_tab = function()
    M.cycle(-1)
  end,
}

--- Run an action by name and redraw.
---
--- Unknown names are reported rather than swallowed: a typo in a tab's `keys`
--- table should be loud during development, not a key that quietly does
--- nothing.
---@param action string?
---@param arg any
---@param row gitvim.render.Row?
local function dispatch(action, arg, row)
  if not action then
    return
  end
  local tab = current_tab()
  local fn = (tab and tab.actions and tab.actions[action]) or GLOBAL_ACTIONS[action]
  if not fn then
    vim.notify(("gitvim: no action '%s'"):format(action), vim.log.levels.WARN)
    return
  end

  local ok, err = pcall(fn, ctx(), arg, row)
  if not ok then
    vim.notify(("gitvim: %s failed: %s"):format(action, err), vim.log.levels.ERROR)
    return
  end
  M.redraw()
end

--- Rows that page more content in (`row.reach`) fire when they come within a
--- screenful of the view, so scrolling towards the end of the graph loads
--- the next page before it is reached. The GRAPH and TIMELINE may both have
--- one in view; each distinct action fires once.
local function reach()
  if sb.reaching or not M.is_open() or not sb.renderer then
    return
  end
  local info = vim.fn.getwininfo(sb.win.win)[1]
  if not info then
    return
  end
  local last = math.min(info.botline + info.height, vim.api.nvim_buf_line_count(sb.win.buf))
  local found, seen = {}, {}
  for lnum = info.topline, last do
    local row = sb.renderer:at(lnum)
    if row and row.reach and not seen[row.reach] then
      seen[row.reach] = true
      found[#found + 1] = row
    end
  end
  sb.reaching = true
  for _, row in ipairs(found) do
    dispatch(row.reach, row.arg, row)
  end
  sb.reaching = false
end

--- The row under the cursor, or nil when the sidebar is not focused.
---@return gitvim.render.Row?
---@return integer lnum
local function row_at_cursor()
  if not sb.renderer or not sb.win or not sb.win:is_open() then
    return nil, 0
  end
  local lnum = vim.api.nvim_win_get_cursor(sb.win.win)[1]
  return sb.renderer:at(lnum), lnum
end

--- `<CR>`: run whatever the row itself says it does.
local function activate()
  local row = row_at_cursor()
  if row then
    dispatch(row.action, row.arg, row)
  end
end

--- A mouse release inside the sidebar. The cursor has already moved by the
--- time `<LeftRelease>` fires, so the column is the one that was clicked.
local function click()
  local pos = vim.fn.getmousepos()
  if not sb.win or pos.winid ~= sb.win.win or not sb.renderer then
    return
  end
  -- `column` is 1-based over bytes; `hit` wants a 0-based byte column.
  local action, arg, row = sb.renderer:hit(pos.line, math.max(pos.column - 1, 0))
  dispatch(action, arg, row)
end

-- ---------------------------------------------------------------------------
-- keymaps
-- ---------------------------------------------------------------------------

--- Bindings that are the same on every tab.
local function base_keys(buf)
  local map = function(lhs, fn, desc)
    vim.keymap.set("n", lhs, fn, { buffer = buf, nowait = true, silent = true, desc = desc })
  end

  map("<CR>", activate, "gitvim: activate row")
  map("<2-LeftMouse>", activate, "gitvim: activate row")
  map("<LeftRelease>", click, "gitvim: click")
  map("<Tab>", function()
    M.cycle(1)
  end, "gitvim: next tab")
  map("<S-Tab>", function()
    M.cycle(-1)
  end, "gitvim: previous tab")
  map("q", function()
    M.close()
  end, "gitvim: close sidebar")
  map("R", function()
    dispatch("refresh")
  end, "gitvim: refresh")

  -- `1`-`4` reach the tabs directly, the keyboard twin of clicking the winbar.
  for i, name in ipairs(config.options.sidebar.tabs) do
    map(tostring(i), function()
      M.select_tab(name)
    end, "gitvim: " .. name .. " tab")
  end
end

--- Install the active tab's own keymaps, removing the previous tab's.
local function tab_keys(buf)
  for _, lhs in ipairs(sb.mapped) do
    pcall(vim.keymap.del, "n", lhs, { buffer = buf })
  end
  sb.mapped = {}

  local tab = current_tab()
  if not tab or not tab.keys then
    return
  end

  for lhs, action in pairs(tab.keys) do
    vim.keymap.set("n", lhs, function()
      local row = row_at_cursor()
      dispatch(action, row and row.arg, row)
    end, {
      buffer = buf,
      nowait = true,
      silent = true,
      desc = "gitvim: " .. action,
    })
    sb.mapped[#sb.mapped + 1] = lhs
  end
end

-- ---------------------------------------------------------------------------
-- rendering
-- ---------------------------------------------------------------------------

--- The `'winbar'` tab row, with a `%@` click region per tab.
---@return string
local function winbar()
  local parts = {}
  for i, name in ipairs(config.options.sidebar.tabs) do
    local tab = tabs.get(name)
    if tab then
      local selected = name == sb.tab
      local hl = selected and "GitVimTabSel" or "GitVimTab"
      local icon = icons.get(name)
      local label
      if icon ~= "" and tab.title ~= "" then
        label = ("%%#%s#%s%%#%s# %s"):format(
          selected and "GitVimTabIconSel" or "GitVimTabIcon",
          icon,
          hl,
          tab.title
        )
      else
        -- Icon-only (Search) or text-only (no nerd font): whichever exists.
        label = icon ~= "" and icon or tab.title
        if label == "" then
          label = name
        end
      end
      parts[#parts + 1] = ("%%#%s#%%%d@%s@ %s %%X"):format(hl, i, TAB_CLICK, label)
    end
  end
  parts[#parts + 1] = "%#GitVimTabFill#"
  return table.concat(parts)
end

--- Rebuild the active tab's rows and push them into the buffer.
---
--- Cheap enough to call after every action: `Renderer:set` diffs against what
--- is already there and only touches the lines that changed.
function M.redraw()
  if not M.is_open() or not sb.renderer then
    return
  end

  local tab = current_tab()
  if not tab then
    return
  end

  local ok, rows = pcall(tab.rows, ctx())
  if not ok then
    vim.notify(("gitvim: %s tab failed: %s"):format(sb.tab, rows), vim.log.levels.ERROR)
    rows = { tabs.hint("This tab errored; see :messages.") }
  end

  sb.renderer:set(rows)
  vim.wo[sb.win.win].winbar = winbar()

  -- Where the cursor should end up: normally wherever the user left it, but a
  -- tab switch asks for the line that tab was last on. A redraw must never
  -- move the cursor on its own -- an action that refreshes the panel would
  -- otherwise yank you back to the top every time.
  local here = vim.api.nvim_win_get_cursor(sb.win.win)[1]
  local want = sb.pending or here
  sb.pending = nil
  want = math.min(math.max(want, 1), math.max(#rows, 1))
  if want ~= here then
    pcall(vim.api.nvim_win_set_cursor, sb.win.win, { want, 0 })
  end
  sb.cursor[sb.tab] = want
  reach()
end

local redraw_pending = false

--- Redraw on the next turn of the loop, once however many times this is
--- called before then.
function M.schedule_redraw()
  if redraw_pending then
    return
  end
  redraw_pending = true
  vim.schedule(function()
    redraw_pending = false
    M.redraw()
  end)
end

-- ---------------------------------------------------------------------------
-- tabs
-- ---------------------------------------------------------------------------

--- Switch to a tab by name. A no-op if it is already showing.
---@param name string
function M.select_tab(name)
  if not vim.tbl_contains(config.options.sidebar.tabs, name) then
    vim.notify(("gitvim: no tab '%s'"):format(name), vim.log.levels.ERROR)
    return
  end
  if sb.tab == name then
    return
  end

  local previous = current_tab()
  if previous then
    if sb.win and sb.win:is_open() then
      sb.cursor[sb.tab] = vim.api.nvim_win_get_cursor(sb.win.win)[1]
    end
    if previous.on_hide then
      pcall(previous.on_hide, ctx())
    end
  end

  sb.tab = name
  sb.pending = sb.cursor[name] or 1
  local tab = current_tab()
  if tab and tab.on_show then
    pcall(tab.on_show, ctx())
  end

  if sb.win then
    tab_keys(sb.win.buf)
  end
  M.redraw()
end

--- Move `delta` tabs along, wrapping.
---@param delta integer
function M.cycle(delta)
  local names = config.options.sidebar.tabs
  local index = 1
  for i, name in ipairs(names) do
    if name == sb.tab then
      index = i
      break
    end
  end
  M.select_tab(names[(index - 1 + delta) % #names + 1])
end

---@return gitvim.Tab? name
function M.tab()
  return sb.tab
end

-- ---------------------------------------------------------------------------
-- lifecycle
-- ---------------------------------------------------------------------------

--- Autocommands and store subscriptions, installed on the first open.
---
--- Deferred rather than done at `setup()` so a user who never opens the
--- sidebar never pays for the watchers.
local function wire()
  if sb.wired then
    return
  end
  sb.wired = true

  local group = vim.api.nvim_create_augroup("gitvim_sidebar", { clear = true })

  vim.api.nvim_create_autocmd("WinEnter", {
    group = group,
    desc = "gitvim: remember the editor window",
    callback = function()
      local win = vim.api.nvim_get_current_win()
      local floating = vim.api.nvim_win_get_config(win).relative ~= ""
      if not floating and (not sb.win or win ~= sb.win.win) then
        sb.editor_win = win
      end
    end,
  })

  vim.api.nvim_create_autocmd("BufEnter", {
    group = group,
    desc = "gitvim: track buffer use and follow the active file",
    callback = function(args)
      if vim.bo[args.buf].buflisted then
        require("gitvim.ui.tabs.buffers").touch(args.buf)
      end
      if M.is_open() and (sb.tab == "buffers" or sb.tab == "files" or sb.tab == "git") then
        vim.schedule(M.redraw)
      end
    end,
  })

  vim.api.nvim_create_autocmd("VimResized", {
    group = group,
    desc = "gitvim: re-render at the new width",
    callback = function()
      if M.is_open() then
        vim.schedule(M.redraw)
      end
    end,
  })

  vim.api.nvim_create_autocmd({ "CursorMoved", "WinScrolled" }, {
    group = group,
    desc = "gitvim: load the next page as it scrolls into view",
    callback = function(args)
      local here = args.event == "WinScrolled" and tonumber(args.match)
        or vim.api.nvim_get_current_win()
      if sb.win and here == sb.win.win then
        reach()
      end
    end,
  })

  -- A refresh emits "head" and "status" back to back; both land in one
  -- scheduled redraw rather than two.
  for _, event in ipairs({ "status", "head", "graph", "timeline", "search" }) do
    state.subscribe(event, function()
      if M.is_open() then
        M.schedule_redraw()
      end
    end)
  end
end

--- Create the window and buffer, once.
---@return gitvim.ui.Win
local function ensure_win()
  if not sb.win then
    local opts = config.options.sidebar
    sb.win = win_mod.new({
      position = opts.position,
      width = opts.width,
      stack = opts.stack,
    })
  end
  return sb.win
end

--- Open the sidebar, optionally on a specific tab.
---@param tab? string
function M.open(tab)
  require("gitvim.ui.hl").setup()
  wire()

  -- Remember where we came from before the sidebar becomes the current window.
  local from = vim.api.nvim_get_current_win()
  if vim.api.nvim_win_get_config(from).relative == "" then
    sb.editor_win = from
  end

  local win = ensure_win()
  local first = not win:is_open()
  win:open(true)

  if first or not sb.renderer then
    sb.renderer = render.new(win.buf, "sidebar")
    base_keys(win.buf)
  end

  local want = tab or sb.tab or config.options.sidebar.default_tab
  if sb.tab == want then
    tab_keys(win.buf)
    M.redraw()
  else
    M.select_tab(want)
  end
end

--- Close the sidebar, keeping its buffer and its per-tab cursor positions.
function M.close()
  if sb.win and sb.win:is_open() then
    sb.cursor[sb.tab] = vim.api.nvim_win_get_cursor(sb.win.win)[1]
    sb.win:close()
  end
end

--- Focus if visible but not current, close if already focused, else open.
---@param tab? string
function M.toggle(tab)
  if sb.win and sb.win:is_focused() then
    M.close()
  else
    M.open(tab)
  end
end

--- Move the cursor into the sidebar, opening it if needed.
---@param tab? string
function M.focus(tab)
  M.open(tab)
end

--- Move the cursor to a rendered action target. Cross-navigation (for
--- example blame -> GRAPH) uses this after opening the appropriate tab.
---@param action string
---@param arg? any
---@return boolean found
function M.reveal(action, arg)
  if not M.is_open() or not sb.renderer or not sb.win then
    return false
  end
  for lnum = 1, vim.api.nvim_buf_line_count(sb.win.buf) do
    local row = sb.renderer:at(lnum)
    if row and row.action == action and (arg == nil or row.arg == arg) then
      vim.api.nvim_win_set_cursor(sb.win.win, { lnum, 0 })
      sb.cursor[sb.tab] = lnum
      return true
    end
  end
  return false
end

--- Apply changed `sidebar.*` options to a live window.
function M.reconfigure()
  if sb.win then
    local opts = config.options.sidebar
    sb.win:reconfigure({ position = opts.position, width = opts.width, stack = opts.stack })
    M.redraw()
  end
end

--- Tear everything down. Tests and `:GitVim` reload paths only.
function M.reset()
  if sb.win then
    sb.win:destroy()
  end
  pcall(vim.api.nvim_del_augroup_by_name, "gitvim_sidebar")
  sb = {
    win = nil,
    renderer = nil,
    tab = nil,
    cursor = {},
    mapped = {},
    pending = nil,
    editor_win = nil,
    reaching = false,
    wired = false,
  }
end

return M
