--- Gitsigns theming, hunk keymaps and the clickable status column.

local bridge = require("gitvim.buffer.bridge")
local config = require("gitvim.config")

local M = {}

local CLICK_NAME = "gitvim_statuscolumn"
local CLICK_ITEM = "%@v:lua._GitVim." .. CLICK_NAME .. "@%s%T"
local EXPR_VALUE = "%!v:lua._GitVim.gitvim_statuscolumn_expr()"

---@type table<integer, string>
local expressions = {}
---@type table<integer, string>
local originals = {}
local did_setup = false

local SIGN_LINKS = {
  Add = "GitVimAdded",
  Change = "GitVimModified",
  Changedelete = "GitVimModified",
  Delete = "GitVimDeleted",
  Topdelete = "GitVimDeleted",
  Untracked = "GitVimUntracked",
}

--- Link gitsigns' visible sign variants to the same semantic groups used in
--- the sidebar. Line highlights are deliberately left alone: replacing a
--- DiffAdd background with a foreground-only group makes whole lines noisy.
function M.apply_theme()
  for kind, target in pairs(SIGN_LINKS) do
    for _, staged in ipairs({ "", "Staged" }) do
      for _, suffix in ipairs({ "", "Nr", "Cul" }) do
        vim.api.nvim_set_hl(0, "GitSigns" .. staged .. kind .. suffix, { link = target })
      end
    end
  end
  vim.api.nvim_set_hl(0, "GitSignsCurrentLineBlame", { link = "GitVimBlame" })
end

---@param value string
---@return string
function M.compose(value)
  value = value or ""
  if value:find("_GitVim%." .. CLICK_NAME) or value == EXPR_VALUE then
    return value
  end
  if vim.startswith(value, "%!") then
    return EXPR_VALUE
  end
  if value == "" then
    -- Explicit form of Neovim's default columns. `%l` obeys both 'number'
    -- and 'relativenumber' in a statuscolumn number segment.
    value = "%C%s%=%l "
  end
  local composed, count = value:gsub("%%s", CLICK_ITEM, 1)
  return count > 0 and composed or (CLICK_ITEM .. value)
end

---@param bufnr integer
---@param lnum integer
---@return table?
function M.hunk_at(bufnr, lnum)
  for _, hunk in ipairs(bridge.get_hunks(bufnr)) do
    local added = hunk.added or {}
    local first = tonumber(added.start) or 1
    local count = tonumber(added.count) or 0
    if count == 0 then
      -- A deletion before the first remaining line is represented as start 0,
      -- but its top-delete sign is drawn on buffer line 1.
      first = math.max(first, 1)
    end
    local last = count > 0 and (first + count - 1) or first
    if lnum >= first and lnum <= last then
      return hunk
    end
  end
end

---@param win integer
---@param lnum integer
---@param fn function
local function at_line(win, lnum, fn)
  if not vim.api.nvim_win_is_valid(win) then
    return
  end
  vim.api.nvim_win_call(win, function()
    local last = vim.api.nvim_buf_line_count(0)
    vim.api.nvim_win_set_cursor(0, { math.min(math.max(lnum, 1), last), 0 })
    fn()
  end)
end

local function reset_hunk()
  local win = vim.api.nvim_get_current_win()
  local lnum = vim.api.nvim_win_get_cursor(win)[1]
  if not config.options.scm.confirm_discard then
    bridge.reset_hunk()
    return
  end
  vim.ui.select({ "Reset hunk", "Cancel" }, {
    prompt = "Discard this hunk's working-tree changes?",
  }, function(choice)
    if choice == "Reset hunk" then
      at_line(win, lnum, bridge.reset_hunk)
    end
  end)
end

---@param win integer
---@param lnum integer
local function action_menu(win, lnum)
  local choices = {
    { label = "Preview hunk inline", run = bridge.preview_hunk_inline },
    { label = "Stage hunk", run = bridge.stage_hunk },
    { label = "Undo last staged hunk", run = bridge.undo_stage_hunk },
    { label = "Reset hunk", run = reset_hunk },
    { label = "Blame line", run = bridge.blame_line },
  }
  vim.ui.select(choices, {
    prompt = "Hunk action",
    format_item = function(item)
      return item.label
    end,
  }, function(item)
    if item then
      at_line(win, lnum, item.run)
    end
  end)
end

--- Handle a status-column click. Exposed separately from `getmousepos()` so
--- its hunk filtering and dispatch can be tested headlessly.
---@param win integer
---@param lnum integer
---@param clicks integer
---@param button string
---@return boolean handled
function M.handle_click(win, lnum, clicks, button)
  if not vim.api.nvim_win_is_valid(win) then
    return false
  end
  local buf = vim.api.nvim_win_get_buf(win)
  if not M.hunk_at(buf, lnum) then
    return false
  end

  if (button == "l" or button == "left") and clicks >= 2 then
    at_line(win, lnum, bridge.preview_hunk_inline)
    return true
  end
  if button == "r" or button == "right" then
    action_menu(win, lnum)
    return true
  end
  return false
end

local function click(_, clicks, button)
  local pos = vim.fn.getmousepos()
  if pos.winid and pos.winid > 0 and pos.line and pos.line > 0 then
    M.handle_click(pos.winid, pos.line, clicks, button)
  end
end

--- Evaluate a pre-existing `%!` statuscolumn and add a stable click region.
--- `g:statusline_winid` identifies the window currently being drawn.
---@return string
local function expression()
  local win = tonumber(vim.g.statusline_winid) or vim.api.nvim_get_current_win()
  local source = expressions[win]
  if not source then
    return "%s%=%l "
  end
  local ok, value = pcall(vim.api.nvim_eval, source)
  if not ok then
    return "%s%=%l "
  end
  return "%@v:lua._GitVim." .. CLICK_NAME .. "@" .. tostring(value) .. "%T"
end

---@param buf integer
local function mappable(buf)
  return vim.api.nvim_buf_is_valid(buf) and vim.bo[buf].buftype == ""
end

---@param buf integer
---@param lhs string
---@param fn function
---@param desc string
local function map_if_free(buf, lhs, fn, desc)
  local want = vim.api.nvim_replace_termcodes(lhs, true, true, true)
  for _, existing in ipairs(vim.api.nvim_buf_get_keymap(buf, "n")) do
    if vim.api.nvim_replace_termcodes(existing.lhs, true, true, true) == want then
      return
    end
  end
  vim.keymap.set("n", lhs, fn, { buffer = buf, silent = true, desc = desc })
end

---@param buf integer
function M.map_buffer(buf)
  if not config.options.keymaps.enabled or not mappable(buf) then
    return
  end
  local prefix = config.options.keymaps.prefix
  map_if_free(buf, prefix .. "hs", bridge.stage_hunk, "gitvim: stage hunk")
  map_if_free(buf, prefix .. "hu", bridge.undo_stage_hunk, "gitvim: undo staged hunk")
  map_if_free(buf, prefix .. "hr", reset_hunk, "gitvim: reset hunk")
  map_if_free(buf, prefix .. "hp", bridge.preview_hunk_inline, "gitvim: preview hunk inline")
  map_if_free(buf, prefix .. "hb", bridge.blame_line, "gitvim: blame line")
  map_if_free(buf, prefix .. "tb", require("gitvim.buffer.blame").toggle, "gitvim: toggle blame")
  map_if_free(buf, prefix .. "hB", function()
    require("gitvim.buffer.blame").open_commit(buf)
  end, "gitvim: open blamed commit")
end

---@param win integer
function M.apply_window(win)
  if not config.options.buffer.clickable_gutter or not vim.api.nvim_win_is_valid(win) then
    return
  end
  local buf = vim.api.nvim_win_get_buf(win)
  if not mappable(buf) then
    return
  end
  local value = vim.wo[win].statuscolumn
  if value == EXPR_VALUE or value:find("_GitVim%." .. CLICK_NAME) then
    return
  end
  originals[win] = value
  if vim.startswith(value, "%!") then
    expressions[win] = value:sub(3)
  end
  vim.wo[win].statuscolumn = M.compose(value)
end

function M.setup()
  if did_setup then
    return
  end
  did_setup = true

  if config.options.buffer.signs then
    M.apply_theme()
  end

  _G._GitVim = _G._GitVim or {}
  _G._GitVim[CLICK_NAME] = click
  _G._GitVim.gitvim_statuscolumn_expr = expression

  local group = vim.api.nvim_create_augroup("gitvim_buffer", { clear = true })
  vim.api.nvim_create_autocmd("ColorScheme", {
    group = group,
    desc = "gitvim: re-link gitsigns highlights",
    callback = function()
      if config.options.buffer.signs then
        M.apply_theme()
      end
    end,
  })
  vim.api.nvim_create_autocmd({ "BufReadPost", "BufNewFile", "BufWinEnter" }, {
    group = group,
    desc = "gitvim: install buffer-layer integrations",
    callback = function(args)
      M.map_buffer(args.buf)
      for _, win in ipairs(vim.fn.win_findbuf(args.buf)) do
        M.apply_window(win)
      end
    end,
  })
  vim.api.nvim_create_autocmd("User", {
    group = group,
    pattern = "GitSignsUpdate",
    desc = "gitvim: map newly attached gitsigns buffer",
    callback = function(args)
      local buf = args.data and args.data.buffer or args.buf
      if buf and buf > 0 then
        M.map_buffer(buf)
      end
    end,
  })

  for _, win in ipairs(vim.api.nvim_list_wins()) do
    M.apply_window(win)
  end
  for _, buf in ipairs(vim.api.nvim_list_bufs()) do
    M.map_buffer(buf)
  end
end

--- Restore editor state. Intended for tests and live plugin development.
function M.reset()
  for win, value in pairs(originals) do
    if vim.api.nvim_win_is_valid(win) then
      vim.wo[win].statuscolumn = value
    end
  end
  pcall(vim.api.nvim_del_augroup_by_name, "gitvim_buffer")
  if _G._GitVim then
    _G._GitVim[CLICK_NAME] = nil
    _G._GitVim.gitvim_statuscolumn_expr = nil
  end
  expressions, originals, did_setup = {}, {}, false
end

return M
