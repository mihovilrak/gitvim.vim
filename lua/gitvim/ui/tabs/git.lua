--- The Git tab -- the project proper.
---
--- `SOURCE CONTROL`, `GRAPH` and `TIMELINE` are collapsible sections of one
--- scrollable panel, the way VS Code stacks its Source Control views, rather
--- than a second row of tabs nested inside the first (Plan.md D2). Phases 3
--- through 8 fill the section bodies in; this file owns the chrome around
--- them: the branch header, the chevrons and the collapse state.

local config = require("gitvim.config")
local icons = require("gitvim.ui.icons")
local scm = require("gitvim.ui.sections.scm")
local tabs = require("gitvim.ui.tabs")

local M = {
  name = "git",
  title = "Git",
}

--- Display names. Kept apart from the config keys so renaming a heading never
--- becomes a breaking config change.
local LABELS = {
  scm = "SOURCE CONTROL",
  graph = "GRAPH",
  timeline = "TIMELINE",
}

--- Collapse state lives in the repo-keyed store (D4), so folding GRAPH in one
--- worktree does not fold it in another. `"section:"` prefixes the key because
--- the same table holds the SCM group state.
---@param store gitvim.Store
---@param section string
---@return boolean
local function collapsed(store, section)
  local value = store.collapsed["section:" .. section]
  if value == nil then
    -- Never toggled here: fall back to the configured initial state.
    return vim.tbl_contains(config.options.git.collapsed, section)
  end
  return value == true
end

--- The repository line: name, branch, and how far it has drifted upstream.
---@param repo gitvim.Repo
---@return gitvim.render.Row
local function branch_row(repo)
  ---@type gitvim.render.Row
  local row = {
    { text = repo.name, hl = "GitVimRepo" },
    { text = "  " },
    { text = repo:head_label(), hl = "GitVimBranch", action = "checkout" },
  }

  if (repo.behind or 0) > 0 then
    row[#row + 1] = { text = " " }
    row[#row + 1] = {
      text = icons.get("behind") .. tostring(repo.behind),
      hl = "GitVimBehind",
      action = "pull",
    }
  end
  if (repo.ahead or 0) > 0 then
    row[#row + 1] = { text = " " }
    row[#row + 1] = {
      text = icons.get("ahead") .. tostring(repo.ahead),
      hl = "GitVimAhead",
      action = "push",
    }
  end

  return row
end

--- Section bodies. Each returns the rows *under* its header; phases 3-8
--- replace these one at a time, and the chrome above never changes.
---@type table<string, fun(ctx: gitvim.ui.TabCtx): gitvim.render.Row[]>
local BODIES = {
  scm = scm.rows,
  graph = function()
    return { tabs.hint("No commits loaded yet.", 2) }
  end,
  timeline = function()
    return { tabs.hint("No file history yet.", 2) }
  end,
}

---@param ctx gitvim.ui.TabCtx
---@return gitvim.render.Row[]
function M.rows(ctx)
  if not ctx.repo or not ctx.store then
    return tabs.no_repo()
  end

  local rows = { branch_row(ctx.repo) }

  for _, section in ipairs(config.options.git.sections) do
    local open = not collapsed(ctx.store, section)
    rows[#rows + 1] = tabs.blank()
    rows[#rows + 1] = tabs.header({
      text = LABELS[section] or section:upper(),
      open = open,
      action = "toggle_section",
      arg = section,
    })
    if open then
      vim.list_extend(rows, BODIES[section](ctx))
    end
  end

  return rows
end

M.actions = {
  ---@param ctx gitvim.ui.TabCtx
  ---@param section string
  toggle_section = function(ctx, section)
    if not ctx.store or not section then
      return
    end
    local key = "section:" .. section
    ctx.store.collapsed[key] = not collapsed(ctx.store, section)
  end,

  toggle_group = scm.actions.toggle_group,

  --- Toggle whichever kind of collapsible header is under the cursor.
  ---@param ctx gitvim.ui.TabCtx
  ---@param arg string
  ---@param row gitvim.render.Row
  toggle_current = function(ctx, arg, row)
    if row and row.action == "toggle_section" then
      M.actions.toggle_section(ctx, arg)
    elseif row and row.action == "toggle_group" then
      M.actions.toggle_group(ctx, arg)
    end
  end,
}

--- Section headers fold like folds do, so `za` on one is muscle memory.
M.keys = {
  ["za"] = "toggle_current",
  ["<Space>"] = "toggle_current",
}

return M
