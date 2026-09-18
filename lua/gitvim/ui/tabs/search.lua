--- The Search tab: VS Code's search form, in 40 columns.
---
--- Pattern (with the match-case / whole-word / regex toggles), Replace, and
--- the two glob filters. This file owns the form and its state; running the
--- search and applying the replacement come later. Every field is editable
--- now, because a form you cannot type into tells you nothing about whether
--- the layout works.

local tabs = require("gitvim.ui.tabs")

local M = {
  name = "search",
  -- Icon-only in the winbar, like VS Code's activity bar.
  title = "",
}

--- Field key -> { label, placeholder }. Order is the render order.
local FIELDS = {
  { key = "pattern", label = "Pattern", placeholder = "Search" },
  { key = "replace", label = "Replace", placeholder = "Replace" },
  { key = "include", label = "files to include", placeholder = "e.g. *.lua, src/**" },
  { key = "exclude", label = "files to exclude", placeholder = "e.g. node_modules" },
}

--- The three buttons that live inside VS Code's search box. Two-letter labels
--- because they have to be legible without a nerd font and clickable without
--- a steady hand.
local TOGGLES = {
  { key = "case", text = "Aa", action = "toggle_case", desc = "Match case" },
  { key = "word", text = "ab", action = "toggle_word", desc = "Match whole word" },
  { key = "regex", text = ".*", action = "toggle_regex", desc = "Use regular expression" },
}

--- The label row for a field. The Pattern row carries the toggle buttons,
--- right-aligned so they sit where the search box's buttons do.
---@param ctx gitvim.ui.TabCtx
---@param label string
---@param with_toggles boolean
---@return gitvim.render.Row
local function label_row(ctx, label, with_toggles)
  ---@type gitvim.render.Row
  local row = { { text = " " .. label, hl = "GitVimLabel" } }
  if not with_toggles then
    return row
  end

  local search = ctx.store and ctx.store.search or {}
  local buttons = {}
  local width = 0
  for _, toggle in ipairs(TOGGLES) do
    local text = " " .. toggle.text .. " "
    width = width + #text
    buttons[#buttons + 1] = {
      text = text,
      hl = search[toggle.key] and "GitVimToggleOn" or "GitVimToggleOff",
      action = toggle.action,
    }
  end

  local pad = ctx.width - #label - 1 - width - 1
  row[#row + 1] = { text = (" "):rep(math.max(pad, 1)) }
  vim.list_extend(row, buttons)
  return row
end

--- The value row: what the user typed, or a dimmed placeholder.
---@param value string
---@param placeholder string
---@param key string
---@return gitvim.render.Row
local function value_row(value, placeholder, key)
  local empty = value == nil or value == ""
  return {
    { text = "  " },
    {
      text = empty and placeholder or value,
      hl = empty and "GitVimFieldEmpty" or "GitVimField",
      action = "edit",
      arg = key,
    },
    action = "edit",
    arg = key,
  }
end

---@param ctx gitvim.ui.TabCtx
---@return gitvim.render.Row[]
function M.rows(ctx)
  if not ctx.store then
    return tabs.no_repo()
  end

  local search = ctx.store.search
  local rows = { tabs.title("SEARCH") }

  for _, field in ipairs(FIELDS) do
    rows[#rows + 1] = tabs.blank()
    rows[#rows + 1] = label_row(ctx, field.label, field.key == "pattern")
    rows[#rows + 1] = value_row(search[field.key], field.placeholder, field.key)
  end

  rows[#rows + 1] = tabs.blank()
  rows[#rows + 1] = tabs.hint("<CR> edits a field, <M-c>/<M-w>/<M-r> toggle.", 1)

  return rows
end

---@param key string
---@return string
local function label_for(key)
  for _, field in ipairs(FIELDS) do
    if field.key == key then
      return field.label
    end
  end
  return key
end

---@param ctx gitvim.ui.TabCtx
---@param key string
local function toggle(ctx, key)
  if ctx.store then
    ctx.store.search[key] = not ctx.store.search[key]
  end
end

M.actions = {
  --- Edit a field. `vim.ui.input` so the prompt honours whatever the user's
  --- config replaced it with (dressing.nvim, snacks.input, the built-in).
  ---@param ctx gitvim.ui.TabCtx
  ---@param key string
  edit = function(ctx, key)
    if not ctx.store or not key or ctx.store.search[key] == nil then
      return
    end
    vim.ui.input({
      prompt = label_for(key) .. ": ",
      default = ctx.store.search[key],
    }, function(input)
      if input == nil then
        return -- cancelled; leave the field alone
      end
      ctx.store.search[key] = input
      require("gitvim.ui.sidebar").redraw()
    end)
  end,

  toggle_case = function(ctx)
    toggle(ctx, "case")
  end,
  toggle_word = function(ctx)
    toggle(ctx, "word")
  end,
  toggle_regex = function(ctx)
    toggle(ctx, "regex")
  end,

  ---@param ctx gitvim.ui.TabCtx
  clear = function(ctx)
    if ctx.store then
      ctx.store.search.pattern = ""
      ctx.store.search.replace = ""
    end
  end,
}

--- `<M-c>` / `<M-w>` / `<M-r>` are VS Code's own bindings for the three
--- toggles, so the muscle memory transfers.
M.keys = {
  ["<M-c>"] = "toggle_case",
  ["<M-w>"] = "toggle_word",
  ["<M-r>"] = "toggle_regex",
  ["i"] = "edit",
  ["<C-l>"] = "clear",
}

return M
