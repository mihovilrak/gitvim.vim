--- The SOURCE CONTROL section.
---
--- Status data is fetched asynchronously and kept in the repo-keyed store.
--- This module turns that data into rows, which keeps rendering deterministic
--- and makes every porcelain group testable without a window. Its actions
--- hand straight over to `gitvim.actions`, which runs git and refreshes.

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

--- The row buttons each group offers, left to right. Order follows VS Code:
--- the destructive one first, furthest from the pointer's usual resting spot.
---@type table<string, string[]>
local BUTTONS = {
  merge = { "stage" },
  staged = { "unstage" },
  changes = { "discard", "stage" },
  untracked = { "discard", "stage" },
}

---@param row gitvim.render.Row
---@return integer
local function width_of(row)
  local width = 0
  for _, chunk in ipairs(row) do
    width = width + vim.api.nvim_strwidth(chunk.text or "")
  end
  return width
end

--- Right-align `tail` in the row, the way the search tab places its toggles.
---@param row gitvim.render.Row
---@param tail gitvim.render.Chunk[]
---@param width integer
local function align_right(row, tail, width)
  local pad = width - width_of(row) - width_of(tail) - 1
  row[#row + 1] = { text = (" "):rep(math.max(pad, 1)) }
  vim.list_extend(row, tail)
end

--- The button chunks for a group, or none when buttons are switched off.
---@param group string
---@return gitvim.render.Chunk[]
local function buttons(group)
  local out = {}
  if not config.options.scm.row_actions then
    return out
  end
  for _, op in ipairs(BUTTONS[group] or {}) do
    if #out > 0 then
      out[#out + 1] = { text = " " }
    end
    out[#out + 1] = { text = icons.get(op), hl = "GitVimButton", action = op }
  end
  return out
end

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
---@param width integer
---@return gitvim.render.Row
local function entry_row(entry, width)
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
  local tail = buttons(entry.group)
  if #tail > 0 then
    align_right(row, tail, width)
  end
  row.data = entry
  row.action = "open"
  row.arg = entry.path
  return row
end

--- A group header, with its "all" buttons ahead of the count so the count
--- stays the right-most chunk.
---@param ctx gitvim.ui.TabCtx
---@param group string
---@param count integer
---@return gitvim.render.Row
local function group_row(ctx, group, count)
  local header = tabs.header({
    text = LABELS[group] or group,
    open = not collapsed(ctx.store, group),
    action = "toggle_group",
    arg = group,
    hl = "GitVimGroup",
  })
  local tail = buttons(group)
  tail[#tail + 1] = { text = " " }
  tail[#tail + 1] = { text = tostring(count), hl = "GitVimCount" }
  align_right(header, tail, ctx.width)
  header.data = { type = "scm_group", group = group }
  return header
end

--- The commit line: the draft's subject (or a prompt to write one) and a
--- Commit button. Either half opens the message editor.
---@param ctx gitvim.ui.TabCtx
---@param staged integer
---@return gitvim.render.Row
local function commit_row(ctx, staged)
  local label = staged > 0 and "Commit" or "Commit (nothing staged)"
  local tail = {
    {
      text = " " .. label .. " ",
      hl = staged > 0 and "GitVimButtonActive" or "GitVimButton",
      action = "commit",
    },
  }

  local subject = vim.split(ctx.store.draft or "", "\n", { plain = true })[1]
  local text, text_hl = subject, "GitVimFile"
  if vim.trim(subject) == "" then
    text, text_hl = "Message", "GitVimHint"
  end
  local room = ctx.width - 2 - width_of(tail) - 2
  if vim.api.nvim_strwidth(text) > room then
    text = vim.fn.strcharpart(text, 0, math.max(room - 1, 0)) .. "…"
  end

  ---@type gitvim.render.Row
  local row = { { text = "  " }, { text = text, hl = text_hl } }
  align_right(row, tail, ctx.width)
  row.action = "commit"
  row.data = { type = "scm_commit" }
  return row
end

--- File rows from the previous render, keyed by what they display. A refresh
--- re-parses every entry, but on a large status almost none of them changed;
--- reusing their rows lets the renderer skip them too (see Renderer:set).
--- Dropped whenever the options, the width or the font signal change (the
--- glyphs depend on all three), and rebuilt from only the rows in use each
--- render, so it never outgrows the status.
local memo = { rows = {} }

---@param entry gitvim.status.Entry
---@param width integer
---@param used table<string, gitvim.render.Row>
---@return gitvim.render.Row
local function cached_entry_row(entry, width, used)
  local id = table.concat({ entry.group, entry.kind, entry.path, entry.orig_path or "" }, "\0")
  local row = memo.rows[id] or entry_row(entry, width)
  -- Same text, fresh entry: actions read the latest status through `data`.
  row.data = entry
  used[id] = row
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

  local font = vim.g.have_nerd_font
  if memo.options ~= config.options or memo.width ~= ctx.width or memo.font ~= font then
    memo = { options = config.options, width = ctx.width, font = font, rows = {} }
  end
  local used = {}

  local groups = ctx.store:groups()
  local rows = { commit_row(ctx, #(groups.staged or {})) }
  for _, group in ipairs(config.options.scm.groups) do
    local entries = groups[group] or {}
    if #entries > 0 then
      rows[#rows + 1] = group_row(ctx, group, #entries)
      if not collapsed(ctx.store, group) then
        for _, entry in ipairs(entries) do
          rows[#rows + 1] = cached_entry_row(entry, ctx.width, used)
        end
      end
    end
  end
  memo.rows = used

  if #rows == 1 then
    rows[2] = tabs.hint("No changes.")
  end
  return rows
end

--- Run `op` on whatever SOURCE CONTROL row the action came from: one file,
--- or every file of a group header. Rows `op` does not apply to (unstaging
--- an untracked file, say) are ignored rather than reported: a key pressed
--- on the wrong line should not be an error.
---@param op "stage"|"unstage"|"discard"
---@param row? gitvim.render.Row
local function apply(op, row)
  local data = row and row.data
  if not data then
    return
  end
  local actions = require("gitvim.actions")
  if data.type == "scm_group" then
    if not vim.tbl_contains(BUTTONS[data.group] or {}, op) then
      return
    end
    if op == "unstage" then
      actions.unstage_all()
    else
      actions[op](actions.group_entries(data.group))
    end
  elseif data.path and data.group then
    if vim.tbl_contains(BUTTONS[data.group] or {}, op) then
      actions[op]({ data })
    end
  end
end

M.actions = {
  ---@param ctx gitvim.ui.TabCtx
  ---@param group string
  toggle_group = function(ctx, group)
    if ctx.store and group then
      ctx.store.collapsed[group] = not collapsed(ctx.store, group)
    end
  end,

  --- Open a changed file in the review view: HEAD vs index for a staged
  --- row, index vs working tree otherwise. A conflict or a submodule has no
  --- two sides to compare, so it opens as a file.
  ---@param ctx gitvim.ui.TabCtx
  ---@param path string  repository-relative
  ---@param row? gitvim.render.Row
  open = function(ctx, path, row)
    if not (ctx.repo and path) then
      return
    end
    local entry = row and row.data
    if entry and entry.path and entry.group ~= "merge" and not entry.submodule then
      require("gitvim.ui.review").open_entry(ctx.repo.root, entry)
    else
      require("gitvim.ui.sidebar").open_file(ctx.repo.root .. "/" .. path)
    end
  end,

  --- Open the working-tree file itself, skipping the review.
  ---@param ctx gitvim.ui.TabCtx
  ---@param path string  repository-relative
  ---@param row? gitvim.render.Row
  open_file = function(ctx, path, row)
    local entry = row and row.data
    if ctx.repo and entry and entry.path then
      require("gitvim.ui.sidebar").open_file(ctx.repo.root .. "/" .. entry.path)
    end
  end,

  stage = function(_, _, row)
    apply("stage", row)
  end,

  unstage = function(_, _, row)
    apply("unstage", row)
  end,

  discard = function(_, _, row)
    apply("discard", row)
  end,

  --- Stage an unstaged row, unstage a staged one (fugitive's `-`).
  toggle_stage = function(_, _, row)
    local data = row and row.data
    local group = data and data.group
    apply(group == "staged" and "unstage" or "stage", row)
  end,

  commit = function()
    require("gitvim.actions").commit()
  end,
}

return M
