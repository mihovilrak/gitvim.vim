--- The review view: two scratch buffers in native diff mode (D3).
---
--- The left pane holds a blob (the index, or a revision), the right pane the
--- working tree (or another blob). Neovim's diff mode draws the filler lines,
--- the scrollbinding and the folds; gitvim only adds per-hunk buttons.
---
--- The buttons are `virt_text_pos = "right_align"` marks on each hunk's first
--- line in the right pane. They must never be `virt_lines`: an extra screen
--- line in one pane is not mirrored in the other, and the panes drift apart.
---
--- Which buttons a hunk gets depends on what the panes are:
---
---   index    | working tree   [+] stage   [↩] revert   [⤢] expand
---   revision | working tree               [↩] revert   [⤢] expand
---   revision | index          [−] unstage              [⤢] expand
---   revision | revision                                [⤢] expand
---
--- One view exists at a time. It borrows the sidebar's editor window for the
--- right pane and splits a left pane off it; closing gives the editor window
--- back its previous buffer and puts 'diffopt' back the way it was.

local config = require("gitvim.config")
local hunk_mod = require("gitvim.git.hunk")

local M = {}

local INDEX = hunk_mod.INDEX
local NS = vim.api.nvim_create_namespace("gitvim_review")
local SEPARATOR = " "

---@alias gitvim.review.Action "stage"|"unstage"|"revert"|"expand"

--- Button order and icon names.
---@type { action: gitvim.review.Action, icon: string }[]
local BUTTONS = {
  { action = "stage", icon = "stage" },
  { action = "unstage", icon = "unstage" },
  { action = "revert", icon = "discard" },
  { action = "expand", icon = "expand" },
}

---@class gitvim.review.Opts
---@field left_rev? string   default the index (`":"`)
---@field right_rev? string  default the working tree; `":"` for the index
---@field left_path? string  the left side's path, for a rename (default `path`)

---@class gitvim.review.View
---@field root string
---@field path string
---@field left_path string
---@field left_rev string
---@field right_rev? string
---@field left gitvim.hunk.Side
---@field right gitvim.hunk.Side
---@field hunks gitvim.hunk.Hunk[]
---@field actions gitvim.review.Action[]
---@field lbuf integer
---@field rbuf integer
---@field lwin integer
---@field rwin integer
---@field prev_buf? integer   what the editor window showed before
---@field prev_winbar string
---@field expanded boolean
---@field generation integer  bumped per load, so a stale read is dropped
---@field unsubscribe fun()
---@field augroup integer

---@type gitvim.review.View?
local view = nil

--- 'diffopt' as it was before the first view opened.
---@type string?
local saved_diffopt = nil

local warned_unified = false

-- ---------------------------------------------------------------------------
-- pure helpers
-- ---------------------------------------------------------------------------

--- The hunk actions a pair of sides supports, in button order.
---@param left_rev string
---@param right_rev? string
---@return gitvim.review.Action[]
function M.actions_for(left_rev, right_rev)
  if right_rev == nil then
    if left_rev == INDEX then
      return { "stage", "revert", "expand" }
    end
    return { "revert", "expand" }
  elseif right_rev == INDEX and left_rev ~= INDEX then
    return { "unstage", "expand" }
  end
  return { "expand" }
end

--- 'diffopt' with the review's items merged in: a `key:value` item replaces
--- the existing one with the same key, a flag is added once.
---@param current string
---@param extra string[]
---@return string
function M.merge_diffopt(current, extra)
  local items = vim.split(current, ",", { trimempty = true })
  for _, item in ipairs(extra) do
    local key = item:match("^([%w%-]+):")
    local replaced = false
    for i, existing in ipairs(items) do
      if existing == item or (key and existing:match("^([%w%-]+):") == key) then
        items[i] = item
        replaced = true
        break
      end
    end
    if not replaced then
      items[#items + 1] = item
    end
  end
  return table.concat(items, ",")
end

---@param rev? string
---@return string
local function label_of(rev)
  if rev == nil then
    return "Working tree"
  elseif rev == INDEX then
    return "Index"
  elseif rev:match("^%x+$") and #rev > 12 then
    return rev:sub(1, 8)
  end
  return rev
end

--- The virtual-text chunks for a hunk's buttons, and each button's cell span
--- counted from the chunk string's start (1-based, inclusive).
---@param actions gitvim.review.Action[]
---@return table[] chunks
---@return { action: gitvim.review.Action, from: integer, to: integer }[] spans
---@return integer width
function M.buttons(actions)
  local icons = require("gitvim.ui.icons")
  local chunks, spans, width = {}, {}, 0
  for _, button in ipairs(BUTTONS) do
    if vim.tbl_contains(actions, button.action) then
      if #chunks > 0 then
        chunks[#chunks + 1] = { SEPARATOR }
        width = width + vim.api.nvim_strwidth(SEPARATOR)
      end
      local text = icons.get(button.icon)
      local w = vim.api.nvim_strwidth(text)
      chunks[#chunks + 1] = { text, "GitVimHunkButton" }
      spans[#spans + 1] = { action = button.action, from = width + 1, to = width + w }
      width = width + w
    end
  end
  return chunks, spans, width
end

-- ---------------------------------------------------------------------------
-- view access
-- ---------------------------------------------------------------------------

--- The open view, if any. Tests and callers that want to poke at it.
---@return gitvim.review.View?
function M.current()
  return view
end

---@param v gitvim.review.View
---@return boolean
local function alive(v)
  return view == v
    and vim.api.nvim_win_is_valid(v.lwin)
    and vim.api.nvim_win_is_valid(v.rwin)
    and vim.api.nvim_buf_is_valid(v.lbuf)
    and vim.api.nvim_buf_is_valid(v.rbuf)
end

---@param v gitvim.review.View
---@param win integer
---@return "a"|"b"
local function side_of(v, win)
  return win == v.lwin and "a" or "b"
end

--- The line a hunk's buttons sit on in the right pane.
---@param v gitvim.review.View
---@param h gitvim.hunk.Hunk
---@return integer
local function anchor(v, h)
  local line = hunk_mod.range(h, "b")
  return math.min(line, vim.api.nvim_buf_line_count(v.rbuf))
end

--- The hunk under the cursor of a review window.
---@param v gitvim.review.View
---@param win integer
---@return integer? index
---@return gitvim.hunk.Hunk?
local function hunk_at_cursor(v, win)
  local lnum = vim.api.nvim_win_get_cursor(win)[1]
  local side = side_of(v, win)
  for i, h in ipairs(v.hunks) do
    local first, last = hunk_mod.range(h, side)
    if lnum >= first and lnum <= last then
      return i, h
    end
  end
end

-- ---------------------------------------------------------------------------
-- rendering
-- ---------------------------------------------------------------------------

--- What a pane shows instead of content it cannot diff.
---@param side gitvim.hunk.Side
---@return string[]?
local function placeholder(side)
  if side.error then
    return { "Read error — review actions disabled", side.error }
  elseif side.binary then
    return { "Binary file — not shown" }
  elseif side.special == "symlink" then
    return { "Symbolic link — not shown" }
  elseif side.special then
    return { ("Not a regular file (%s) — not shown"):format(side.special) }
  end
end

---@param buf integer
---@param lines string[]
local function set_lines(buf, lines)
  vim.bo[buf].modifiable = true
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
  vim.bo[buf].modifiable = false
  vim.bo[buf].modified = false
end

---@param v gitvim.review.View
---@param win integer
---@param rev? string
---@param side gitvim.hunk.Side
---@param path string
local function set_winbar(v, win, rev, side, path)
  local note = side.missing and " (absent)" or side.binary and " (binary)" or ""
  local text = ("%s · %s%s"):format(label_of(rev), path, note):gsub("%%", "%%%%")
  vim.wo[win].winbar = "%#GitVimReviewLabel#" .. text
  if win == v.rwin and #v.hunks > 0 then
    vim.wo[win].winbar = vim.wo[win].winbar
      .. ("%%#GitVimHint#  %d hunk%s"):format(#v.hunks, #v.hunks == 1 and "" or "s")
  end
end

---@param v gitvim.review.View
local function place_buttons(v)
  vim.api.nvim_buf_clear_namespace(v.rbuf, NS, 0, -1)
  if not config.options.review.hunk_actions then
    return
  end
  local chunks = M.buttons(v.actions)
  for _, h in ipairs(v.hunks) do
    vim.api.nvim_buf_set_extmark(v.rbuf, NS, anchor(v, h) - 1, 0, {
      virt_text = chunks,
      virt_text_pos = "right_align",
      hl_mode = "combine",
    })
  end
end

---@param v gitvim.review.View
local function render(v)
  local lcur = vim.api.nvim_win_get_cursor(v.lwin)
  local rcur = vim.api.nvim_win_get_cursor(v.rwin)
  local lph, rph = placeholder(v.left), placeholder(v.right)
  if lph or rph then
    -- Diffing a placeholder against content would paint it all as changed.
    set_lines(v.lbuf, lph or { "(see the other pane)" })
    set_lines(v.rbuf, rph or { "(see the other pane)" })
  else
    set_lines(v.lbuf, v.left.lines)
    set_lines(v.rbuf, v.right.lines)
  end
  for _, pair in ipairs({ { v.lwin, lcur }, { v.rwin, rcur } }) do
    local win, cur = pair[1], pair[2]
    local last = vim.api.nvim_buf_line_count(vim.api.nvim_win_get_buf(win))
    pcall(vim.api.nvim_win_set_cursor, win, { math.min(cur[1], last), cur[2] })
  end
  vim.api.nvim_win_call(v.rwin, function()
    vim.cmd("diffupdate")
  end)
  set_winbar(v, v.lwin, v.left_rev, v.left, v.left_path)
  set_winbar(v, v.rwin, v.right_rev, v.right, v.path)
  place_buttons(v)
end

--- Re-read both sides and redraw.
---@param v gitvim.review.View
---@param cb? fun()
local function load(v, cb)
  v.generation = v.generation + 1
  local generation = v.generation
  local left, right
  local function done()
    if not (left and right) or v.generation ~= generation or not alive(v) then
      return
    end
    v.left, v.right = left, right
    v.hunks = hunk_mod.compute(left, right, config.options.review.diffopt)
    if left.error or right.error then
      v.hunks = {}
      v.actions = {}
    else
      v.actions = M.actions_for(v.left_rev, v.right_rev)
    end
    render(v)
    if cb then
      cb()
    end
  end
  hunk_mod.read(v.root, v.left_rev, v.left_path, function(side)
    left = side
    done()
  end)
  hunk_mod.read(v.root, v.right_rev, v.path, function(side)
    right = side
    done()
  end)
end

--- Re-read the open view, e.g. after the file changed on disk.
---@param cb? fun()
function M.reload(cb)
  if view and alive(view) then
    load(view, cb)
  elseif cb then
    cb()
  end
end

-- ---------------------------------------------------------------------------
-- navigation
-- ---------------------------------------------------------------------------

--- Move to the next (`delta = 1`) or previous (`-1`) hunk in the current pane.
---@param delta integer
---@return boolean moved
function M.jump(delta)
  local v = view
  if not v or not alive(v) then
    return false
  end
  local win = vim.api.nvim_get_current_win()
  if win ~= v.lwin and win ~= v.rwin then
    win = v.rwin
  end
  local side = side_of(v, win)
  local lnum = vim.api.nvim_win_get_cursor(win)[1]
  local target
  if delta > 0 then
    for _, h in ipairs(v.hunks) do
      local first = hunk_mod.range(h, side)
      if first > lnum then
        target = first
        break
      end
    end
  else
    for i = #v.hunks, 1, -1 do
      local first = hunk_mod.range(v.hunks[i], side)
      if first < lnum then
        target = first
        break
      end
    end
  end
  if not target then
    vim.api.nvim_echo(
      { { delta > 0 and "gitvim: no next hunk" or "gitvim: no previous hunk" } },
      false,
      {}
    )
    return false
  end
  local last = vim.api.nvim_buf_line_count(vim.api.nvim_win_get_buf(win))
  vim.api.nvim_win_set_cursor(win, { math.min(target, last), 0 })
  return true
end

-- ---------------------------------------------------------------------------
-- hunk actions
-- ---------------------------------------------------------------------------

---@param v gitvim.review.View
---@param h gitvim.hunk.Hunk
local function expand(v, h)
  v.expanded = not v.expanded
  for _, win in ipairs({ v.lwin, v.rwin }) do
    vim.wo[win].foldenable = not v.expanded
  end
  local line = anchor(v, h)
  vim.api.nvim_win_set_cursor(v.rwin, { line, 0 })
  vim.api.nvim_win_call(v.rwin, function()
    vim.cmd("normal! zz")
  end)
end

--- The editor buffer for the reviewed file, if one is loaded.
---@param v gitvim.review.View
---@return integer?
local function file_buffer(v)
  local buf = vim.fn.bufnr(v.root .. "/" .. v.path)
  return buf > 0 and vim.api.nvim_buf_is_loaded(buf) and buf or nil
end

--- Run a hunk action on hunk `index` of the open view.
---@param action gitvim.review.Action
---@param index? integer  default: the hunk under the cursor
---@param cb? fun(err?: gitvim.git.Error)
function M.act(action, index, cb)
  cb = cb or function() end
  local v = view
  if not v or not alive(v) then
    return cb()
  end
  local h
  if index then
    h = v.hunks[index]
  else
    local win = vim.api.nvim_get_current_win()
    h = select(2, hunk_at_cursor(v, (win == v.lwin or win == v.rwin) and win or v.rwin))
  end
  if not h then
    vim.notify("gitvim: no hunk under the cursor", vim.log.levels.INFO)
    return cb()
  end
  if not vim.tbl_contains(v.actions, action) then
    vim.notify(
      ("gitvim: cannot %s a hunk of %s against %s"):format(
        action,
        label_of(v.left_rev),
        label_of(v.right_rev)
      ),
      vim.log.levels.WARN
    )
    return cb()
  end
  if action == "expand" then
    expand(v, h)
    return cb()
  end

  local function done(err)
    if err then
      vim.notify(require("gitvim.git.cli").format_error(err), vim.log.levels.ERROR)
    end
    if action == "revert" then
      local buf = file_buffer(v)
      if buf then
        vim.cmd.checktime(buf)
      end
    end
    -- Re-read status (the sidebar and signs follow) and then the panes.
    require("gitvim").refresh(v.root, function()
      M.reload(function()
        cb(err)
      end)
    end)
  end

  if action == "stage" then
    hunk_mod.stage(v.root, v.path, v.left, v.right, h, done)
  elseif action == "unstage" then
    hunk_mod.unstage(v.root, v.path, v.left, v.right, h, v.left_rev, done)
  elseif action == "revert" then
    local buf = file_buffer(v)
    if buf and vim.bo[buf].modified then
      vim.notify(
        ("gitvim: %s has unsaved changes; write or discard them before reverting a hunk"):format(
          v.path
        ),
        vim.log.levels.WARN
      )
      return cb()
    end
    local prompt = v.left.missing and #v.hunks == 1 and ("Delete '%s'?"):format(v.path)
      or ("Revert this hunk of '%s'?"):format(v.path)
    require("gitvim.actions").confirm(prompt, "Revert", function()
      hunk_mod.revert(v.root, v.path, v.left, v.right, h, done)
    end)
  end
end

--- The button, if any, at a window-relative screen position in the right
--- pane. `wincol` is 1-based and counts from the window's left edge, as in
--- `getmousepos().wincol`.
---@param line integer
---@param wincol integer
---@return gitvim.review.Action? action
---@return integer? index
function M.button_at(line, wincol)
  local v = view
  if not v or not alive(v) or not config.options.review.hunk_actions then
    return
  end
  local _, spans, width = M.buttons(v.actions)
  -- Right-aligned text ends at the window's last column.
  local start = vim.api.nvim_win_get_width(v.rwin) - width
  for i, h in ipairs(v.hunks) do
    if anchor(v, h) == line then
      for _, span in ipairs(spans) do
        if wincol >= start + span.from and wincol <= start + span.to then
          return span.action, i
        end
      end
      return
    end
  end
end

local function click()
  local pos = vim.fn.getmousepos()
  local v = view
  if not v or pos.winid ~= v.rwin then
    return
  end
  local action, index = M.button_at(pos.line, pos.wincol)
  if action then
    M.act(action, index)
  end
end

-- ---------------------------------------------------------------------------
-- open / close
-- ---------------------------------------------------------------------------

---@param buf integer
local function map_keys(buf)
  local function map(lhs, fn, desc)
    vim.keymap.set(
      "n",
      lhs,
      fn,
      { buffer = buf, nowait = true, silent = true, desc = "gitvim: " .. desc }
    )
  end
  map("]h", function()
    M.jump(1)
  end, "next hunk")
  map("[h", function()
    M.jump(-1)
  end, "previous hunk")
  map("s", function()
    M.act("stage")
  end, "stage hunk")
  map("u", function()
    M.act("unstage")
  end, "unstage hunk")
  map("x", function()
    M.act("revert")
  end, "revert hunk")
  map("o", function()
    M.act("expand")
  end, "expand context")
  map("R", function()
    M.reload()
  end, "reload review")
  map("q", M.close, "close review")
  map("<LeftRelease>", click, "hunk button")
  if config.options.keymaps.enabled then
    local prefix = config.options.keymaps.prefix
    map(prefix .. "hs", function()
      M.act("stage")
    end, "stage hunk")
    map(prefix .. "hu", function()
      M.act("unstage")
    end, "unstage hunk")
    map(prefix .. "hr", function()
      M.act("revert")
    end, "revert hunk")
  end
end

---@param name string
---@param path string
---@return integer
local function scratch(name, path)
  local buf = vim.api.nvim_create_buf(false, true)
  vim.bo[buf].buftype = "nofile"
  vim.bo[buf].bufhidden = "wipe"
  vim.bo[buf].swapfile = false
  vim.bo[buf].modifiable = false
  pcall(vim.api.nvim_buf_set_name, buf, name)
  local ft = vim.filetype.match({ filename = path })
  if ft then
    vim.bo[buf].filetype = ft
  end
  return buf
end

--- Close the review view, giving the editor window its buffer back.
function M.close()
  local v = view
  if not v then
    return
  end
  view = nil
  v.unsubscribe()
  pcall(vim.api.nvim_del_augroup_by_id, v.augroup)

  if vim.api.nvim_win_is_valid(v.lwin) then
    pcall(vim.api.nvim_win_close, v.lwin, true)
  end
  if vim.api.nvim_win_is_valid(v.rwin) then
    vim.api.nvim_win_call(v.rwin, function()
      pcall(vim.cmd, "diffoff")
    end)
    vim.wo[v.rwin].winbar = v.prev_winbar
    local prev = v.prev_buf
    if not (prev and vim.api.nvim_buf_is_valid(prev)) then
      prev = vim.api.nvim_create_buf(true, false)
    end
    if vim.api.nvim_win_get_buf(v.rwin) == v.rbuf then
      vim.api.nvim_win_set_buf(v.rwin, prev)
    end
  end
  for _, buf in ipairs({ v.lbuf, v.rbuf }) do
    if vim.api.nvim_buf_is_valid(buf) then
      pcall(vim.api.nvim_buf_delete, buf, { force = true })
    end
  end
  if saved_diffopt then
    vim.o.diffopt = saved_diffopt
    saved_diffopt = nil
  end
end

--- Open the review view for one file.
---
--- The entry point for the SCM rows, and for the graph's commit files and
--- the timeline's revisions (`{ left_rev = sha .. "^", right_rev = sha }`).
---@param root string
---@param path string  repository-relative
---@param opts? gitvim.review.Opts
---@param cb? fun(view: gitvim.review.View)  once both panes are filled
function M.open(root, path, opts, cb)
  opts = opts or {}
  root = vim.fs.normalize(root)
  M.close()

  if config.options.review.layout == "unified" and not warned_unified then
    warned_unified = true
    vim.notify(
      "gitvim: review.layout = 'unified' is not implemented yet; using 'split'",
      vim.log.levels.WARN
    )
  end

  local left_rev = opts.left_rev or INDEX
  local right_rev = opts.right_rev
  local left_path = opts.left_path or path
  local tag = right_rev and label_of(right_rev) or "worktree"

  local rwin = require("gitvim.ui.sidebar").editor_window()
  local prev_buf = vim.api.nvim_win_get_buf(rwin)
  local lbuf = scratch(("gitvim://review/%s/%s"):format(label_of(left_rev), left_path), left_path)
  local rbuf = scratch(("gitvim://review/%s/%s"):format(tag, path), path)

  saved_diffopt = vim.o.diffopt
  vim.o.diffopt = M.merge_diffopt(vim.o.diffopt, config.options.review.diffopt)

  local prev_winbar = vim.wo[rwin].winbar
  vim.api.nvim_win_set_buf(rwin, rbuf)
  local lwin = vim.api.nvim_open_win(lbuf, false, { split = "left", win = rwin })

  ---@type gitvim.review.View
  local v = {
    root = root,
    path = path,
    left_path = left_path,
    left_rev = left_rev,
    right_rev = right_rev,
    left = hunk_mod.parse(""),
    right = hunk_mod.parse(""),
    hunks = {},
    actions = M.actions_for(left_rev, right_rev),
    lbuf = lbuf,
    rbuf = rbuf,
    lwin = lwin,
    rwin = rwin,
    prev_buf = prev_buf ~= rbuf and prev_buf or nil,
    prev_winbar = prev_winbar,
    expanded = false,
    generation = 0,
    unsubscribe = function() end,
    augroup = vim.api.nvim_create_augroup("gitvim_review", { clear = true }),
  }
  view = v

  for _, win in ipairs({ lwin, rwin }) do
    vim.api.nvim_win_call(win, function()
      vim.cmd("diffthis")
    end)
  end
  map_keys(lbuf)
  map_keys(rbuf)

  -- Closing either pane, or wiping either buffer, ends the view.
  vim.api.nvim_create_autocmd("WinClosed", {
    group = v.augroup,
    pattern = { tostring(lwin), tostring(rwin) },
    callback = function()
      vim.schedule(function()
        if view == v then
          M.close()
        end
      end)
    end,
  })
  vim.api.nvim_create_autocmd("BufWipeout", {
    group = v.augroup,
    buffer = lbuf,
    callback = function()
      vim.schedule(function()
        if view == v then
          M.close()
        end
      end)
    end,
  })

  -- Status refreshes (a write, a stage in the sidebar, git outside Neovim)
  -- re-read the panes.
  v.unsubscribe = require("gitvim.state").subscribe("status", function(payload)
    if view == v and payload.root == v.root then
      load(v)
    end
  end)

  vim.api.nvim_set_current_win(rwin)
  load(v, function()
    if v.hunks[1] and alive(v) then
      local line = anchor(v, v.hunks[1])
      vim.api.nvim_win_set_cursor(v.rwin, { line, 0 })
    end
    if config.options.sidebar.close_on_open then
      require("gitvim.ui.sidebar").close()
    end
    if cb then
      cb(v)
    end
  end)
end

--- Open the review for a SOURCE CONTROL entry: a staged row compares HEAD
--- with the index, anything else the index with the working tree.
---@param root string
---@param entry gitvim.status.Entry
---@param cb? fun(view: gitvim.review.View)
function M.open_entry(root, entry, cb)
  if entry.group == "staged" then
    M.open(
      root,
      entry.path,
      { left_rev = "HEAD", right_rev = INDEX, left_path = entry.orig_path },
      cb
    )
  else
    M.open(root, entry.path, nil, cb)
  end
end

--- Open the review for a file on disk, against the index.
---@param file? string  absolute; default the current buffer
---@param opts? gitvim.review.Opts
function M.open_file(file, opts)
  file = file or vim.api.nvim_buf_get_name(0)
  if file == "" then
    vim.notify("gitvim: the current buffer is not a file", vim.log.levels.WARN)
    return
  end
  require("gitvim.git.repo").detect(file, function(err, repo)
    if not repo then
      vim.notify(
        err and require("gitvim.git.cli").format_error(err) or "gitvim: not in a git repository"
      )
      return
    end
    local rel = vim.fs.normalize(file):sub(#repo.root + 2)
    M.open(repo.root, rel, opts)
  end)
end

return M
