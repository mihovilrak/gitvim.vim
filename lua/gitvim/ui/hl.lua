--- `GitVim*` highlight groups.
---
--- Every group is **linked** to an existing semantic group, never given a
--- hardcoded hex value, so gitvim inherits whatever colorscheme is loaded. A
--- user who wants to override one simply defines it after `setup()`: `default
--- = true` on every link means gitvim never clobbers an explicit definition.
---
--- Links are re-applied on `ColorScheme` because `:colorscheme` clears all
--- highlighting, including links defined by plugins.

local M = {}

--- Number of lane colors before the graph palette cycles. Kept here rather
--- than read from config so the table below stays a pure constant; the
--- renderer clamps the index it asks for.
M.LANE_COLORS = 8

--- Semantic sources for the lane palette. These are the groups every
--- colorscheme is obliged to define, so an 8-color cycle exists everywhere.
local LANE_SOURCES = {
  "Function", -- 1
  "String", -- 2
  "Identifier", -- 3
  "Constant", -- 4
  "Keyword", -- 5
  "Type", -- 6
  "Special", -- 7
  "Number", -- 8
}

--- group -> group it links to.
---@type table<string, string>
local LINKS = {
  -- File status. Matches VS Code's Source Control coloring as closely as
  -- Neovim's semantic groups allow.
  GitVimAdded = "Added",
  GitVimModified = "Changed",
  GitVimDeleted = "Removed",
  GitVimRenamed = "Special",
  GitVimCopied = "Special",
  GitVimTypechange = "Changed",
  GitVimUntracked = "Comment",
  GitVimIgnored = "Comment",
  GitVimConflict = "DiagnosticWarn",

  -- Sidebar chrome.
  GitVimNormal = "NormalFloat",
  GitVimTitle = "Title",
  GitVimSection = "Title", -- SOURCE CONTROL / GRAPH / TIMELINE
  GitVimGroup = "Directory", -- Staged / Changes / Untracked
  GitVimCount = "Comment",
  GitVimChevron = "Comment",
  GitVimIcon = "Comment",
  GitVimDir = "Comment", -- dimmed leading directories
  GitVimFile = "Normal", -- bright basename
  GitVimHint = "Comment", -- empty-state text
  GitVimBufferCurrent = "Special", -- the buffer the editor window is showing
  GitVimError = "DiagnosticError",
  GitVimSeparator = "WinSeparator",
  GitVimBlame = "Comment",

  -- Branch header.
  GitVimBranch = "Identifier",
  GitVimAhead = "DiagnosticInfo",
  GitVimBehind = "DiagnosticWarn",
  GitVimRepo = "Title",

  -- Winbar activity tabs.
  GitVimTab = "TabLine",
  GitVimTabSel = "TabLineSel",
  GitVimTabFill = "TabLineFill",
  GitVimTabIcon = "TabLine",
  GitVimTabIconSel = "TabLineSel",

  -- Inline row buttons: [+] [-] [<].
  GitVimButton = "Comment",
  GitVimButtonActive = "Special",

  -- Search tab form.
  GitVimLabel = "Label",
  GitVimField = "NormalFloat",
  GitVimFieldEmpty = "Comment",
  GitVimToggleOn = "Search",
  GitVimToggleOff = "Comment",
  GitVimMatch = "Search",

  -- Graph.
  GitVimGraphNode = "Special",
  GitVimGraphDate = "Comment",
  GitVimGraphAuthor = "Identifier",
  GitVimGraphSubject = "Normal",
  GitVimRefHead = "DiagnosticOk",
  GitVimRefLocal = "Identifier",
  GitVimRefRemote = "Constant",
  GitVimRefTag = "Type",
}

--- Status kind -> highlight group. The one place the mapping lives, so the
--- sidebar, the sign theme and the review view cannot drift apart.
---@type table<gitvim.status.Kind, string>
M.kind = {
  modified = "GitVimModified",
  added = "GitVimAdded",
  deleted = "GitVimDeleted",
  renamed = "GitVimRenamed",
  copied = "GitVimCopied",
  typechange = "GitVimTypechange",
  untracked = "GitVimUntracked",
  ignored = "GitVimIgnored",
  conflict = "GitVimConflict",
}

--- The highlight group for a graph lane, cycling through the palette.
---@param lane integer  1-based lane index
---@return string
function M.lane(lane)
  return ("GitVimGraphLane%d"):format((lane - 1) % M.LANE_COLORS + 1)
end

--- (Re-)define every group as a default link.
function M.apply()
  for name, link in pairs(LINKS) do
    vim.api.nvim_set_hl(0, name, { link = link, default = true })
  end
  for i, source in ipairs(LANE_SOURCES) do
    vim.api.nvim_set_hl(0, ("GitVimGraphLane%d"):format(i), { link = source, default = true })
  end
end

--- Every group gitvim defines, sorted. Used by the docs and by tests.
---@return string[]
function M.groups()
  local out = vim.tbl_keys(LINKS)
  for i = 1, M.LANE_COLORS do
    table.insert(out, ("GitVimGraphLane%d"):format(i))
  end
  table.sort(out)
  return out
end

local did_setup = false

--- Define the groups and keep them alive across `:colorscheme`.
function M.setup()
  if did_setup then
    return
  end
  did_setup = true

  M.apply()
  vim.api.nvim_create_autocmd("ColorScheme", {
    group = vim.api.nvim_create_augroup("gitvim_hl", { clear = true }),
    desc = "gitvim: re-link highlight groups",
    callback = M.apply,
  })
end

return M
