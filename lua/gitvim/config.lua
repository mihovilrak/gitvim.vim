--- Configuration defaults and validation.
---
--- Every option below is the documented public surface; see `:help gitvim-config`.

local M = {}

---@class gitvim.Config
local defaults = {
  --- Sidebar window.
  sidebar = {
    ---@type "left"|"right"
    position = "left",
    width = 40,
    --- Share the column with an existing side split (e.g. snacks.explorer)
    --- instead of opening beside it. See Plan.md D2.
    stack = false,
    --- Tabs shown in the winbar, in order.
    ---@type ("scm"|"graph"|"timeline")[]
    tabs = { "scm", "graph", "timeline" },
    ---@type "scm"|"graph"|"timeline"
    default_tab = "scm",
    --- Close the sidebar after opening a file from it.
    close_on_open = false,
  },

  --- Source control tab.
  scm = {
    --- Groups rendered, in order. "merge" stays empty until the conflict UI lands.
    ---@type ("merge"|"staged"|"changes"|"untracked")[]
    groups = { "merge", "staged", "changes", "untracked" },
    --- Groups collapsed on first open.
    ---@type string[]
    collapsed = {},
    --- Ask before discarding working-tree changes. Turning this off is on you.
    confirm_discard = true,
    --- Show `[+] [-] [<]` buttons on the focused row.
    row_actions = true,
  },

  --- Commit graph tab.
  graph = {
    --- Commits fetched per page; more load on scroll.
    page_size = 256,
    --- Number of lane colors before the palette cycles.
    lane_colors = 8,
    date_format = "relative", ---@type "relative"|"short"|"iso"
    show_refs = true,
  },

  --- Timeline tab (history of the active buffer's file).
  timeline = {
    page_size = 128,
    --- Follow renames (`git log --follow`).
    follow_renames = true,
    --- Track the active buffer automatically; false means pin explicitly.
    follow_buffer = true,
  },

  --- Two-pane review view.
  review = {
    ---@type "split"|"unified"
    layout = "split",
    --- Appended to 'diffopt' for review windows. See Plan.md D3.
    diffopt = { "internal", "filler", "closeoff", "linematch:60" },
    --- Right-aligned per-hunk buttons. Never virt_lines: that breaks alignment.
    hunk_actions = true,
  },

  --- In-buffer layer. Delegates to gitsigns via buffer/bridge.lua (Plan.md D1).
  buffer = {
    --- Apply gitvim's sign theme to gitsigns.
    signs = true,
    --- Current-line blame virtual text.
    blame = true,
    blame_format = "<author>, <author_time:%R> - <summary>",
    --- Clickable gutter: double-click a sign to expand the hunk inline.
    --- Composes with an existing 'statuscolumn' rather than replacing it.
    clickable_gutter = true,
  },

  --- Refresh behaviour.
  refresh = {
    --- Debounce for coalescing refresh requests, in milliseconds.
    debounce = 50,
    --- Watch .git via uv.fs_event for external git operations.
    watch_gitdir = true,
    --- Refresh on these autocmd events.
    events = { "BufWritePost", "FocusGained" },
  },

  --- Icons. Falls back to plain ASCII when mini.icons is unavailable.
  icons = {
    enabled = true,
    ---@type table<string, string>
    status = {
      modified = "M",
      added = "A",
      deleted = "D",
      renamed = "R",
      copied = "C",
      untracked = "U",
      ignored = "I",
      conflict = "!",
    },
    group_open = "",
    group_closed = "",
    commit = "",
    ahead = "",
    behind = "",
  },

  --- Set to false to skip all default keymaps.
  keymaps = {
    enabled = true,
    prefix = "<leader>g",
  },
}

---@type gitvim.Config
M.options = vim.deepcopy(defaults)

M.defaults = defaults

--- Tables the user is free to extend with arbitrary keys, so the unknown-key
--- check must not descend into them.
local FREEFORM = {
  ["icons.status"] = true,
}

--- A validator accepting only the listed values.
---@param values string[]
---@return fun(v: any): boolean, string message
local function one_of(values)
  local set = {}
  for _, v in ipairs(values) do
    set[v] = true
  end
  return function(v)
    return set[v] == true
  end, "one of " .. table.concat(values, ", ")
end

--- A validator accepting a list whose every element passes `ok`.
---@param ok fun(v: any): boolean
---@param what string
---@return fun(v: any): boolean, string message
local function list_of(ok, what)
  return function(v)
    if type(v) ~= "table" or not vim.islist(v) then
      return false
    end
    for _, item in ipairs(v) do
      if not ok(item) then
        return false
      end
    end
    return true
  end,
    "a list of " .. what
end

--- A validator accepting integers at or above `min`.
---@param min integer
---@return fun(v: any): boolean, string message
local function min_int(min)
  return function(v)
    return type(v) == "number" and v == math.floor(v) and v >= min
  end,
    "an integer >= " .. min
end

--- Warn about keys that do not exist in the defaults.
---
--- A typo in a config table is otherwise silent forever: `vim.tbl_deep_extend`
--- happily carries `sidebar.widht` through. This warns rather than errors so a
--- stale key from a newer/older gitvim never breaks a user's whole config.
---@param user table
---@param known table
---@param path string
local function check_unknown(user, known, path)
  for key, value in pairs(user) do
    local full = path == "" and tostring(key) or (path .. "." .. tostring(key))
    local default = known[key]
    if default == nil then
      vim.notify(("gitvim: unknown config option '%s'"):format(full), vim.log.levels.WARN)
    elseif
      type(value) == "table"
      and type(default) == "table"
      and not vim.islist(default)
      and not FREEFORM[full]
    then
      check_unknown(value, default, full)
    end
  end
end

--- Validate the merged options, raising on anything that would crash later.
---@param o gitvim.Config
local function validate(o)
  local tab_names = { "scm", "graph", "timeline" }
  local is_tab = one_of(tab_names)
  local is_string = function(v)
    return type(v) == "string"
  end

  vim.validate("sidebar.position", o.sidebar.position, one_of({ "left", "right" }))
  vim.validate("sidebar.width", o.sidebar.width, min_int(10))
  vim.validate("sidebar.stack", o.sidebar.stack, "boolean")
  vim.validate("sidebar.tabs", o.sidebar.tabs, list_of(is_tab, "tab names"))
  vim.validate(
    "sidebar.default_tab",
    o.sidebar.default_tab,
    is_tab,
    "one of " .. table.concat(tab_names, ", ")
  )
  vim.validate("sidebar.close_on_open", o.sidebar.close_on_open, "boolean")

  if not vim.tbl_contains(o.sidebar.tabs, o.sidebar.default_tab) then
    error(
      ("gitvim: sidebar.default_tab '%s' is not in sidebar.tabs"):format(o.sidebar.default_tab),
      0
    )
  end

  local is_group = one_of({ "merge", "staged", "changes", "untracked", "ignored" })
  vim.validate("scm.groups", o.scm.groups, list_of(is_group, "group names"))
  vim.validate("scm.collapsed", o.scm.collapsed, list_of(is_group, "group names"))
  vim.validate("scm.confirm_discard", o.scm.confirm_discard, "boolean")
  vim.validate("scm.row_actions", o.scm.row_actions, "boolean")

  vim.validate("graph.page_size", o.graph.page_size, min_int(1))
  vim.validate("graph.lane_colors", o.graph.lane_colors, min_int(1))
  vim.validate("graph.date_format", o.graph.date_format, one_of({ "relative", "short", "iso" }))
  vim.validate("graph.show_refs", o.graph.show_refs, "boolean")

  vim.validate("timeline.page_size", o.timeline.page_size, min_int(1))
  vim.validate("timeline.follow_renames", o.timeline.follow_renames, "boolean")
  vim.validate("timeline.follow_buffer", o.timeline.follow_buffer, "boolean")

  vim.validate("review.layout", o.review.layout, one_of({ "split", "unified" }))
  vim.validate("review.diffopt", o.review.diffopt, list_of(is_string, "'diffopt' values"))
  vim.validate("review.hunk_actions", o.review.hunk_actions, "boolean")

  vim.validate("buffer.signs", o.buffer.signs, "boolean")
  vim.validate("buffer.blame", o.buffer.blame, "boolean")
  vim.validate("buffer.blame_format", o.buffer.blame_format, "string")
  vim.validate("buffer.clickable_gutter", o.buffer.clickable_gutter, "boolean")

  vim.validate("refresh.debounce", o.refresh.debounce, min_int(0))
  vim.validate("refresh.watch_gitdir", o.refresh.watch_gitdir, "boolean")
  vim.validate("refresh.events", o.refresh.events, list_of(is_string, "autocmd names"))

  vim.validate("icons.enabled", o.icons.enabled, "boolean")
  vim.validate("icons.status", o.icons.status, "table")
  for name, icon in pairs(o.icons.status) do
    vim.validate(("icons.status.%s"):format(name), icon, "string")
  end
  for _, name in ipairs({ "group_open", "group_closed", "commit", "ahead", "behind" }) do
    vim.validate(("icons.%s"):format(name), o.icons[name], "string")
  end

  vim.validate("keymaps.enabled", o.keymaps.enabled, "boolean")
  vim.validate("keymaps.prefix", o.keymaps.prefix, "string")
end

--- Merge user options over the defaults and validate the result.
---@param opts? gitvim.Config
---@return gitvim.Config
function M.setup(opts)
  opts = opts or {}
  vim.validate("opts", opts, "table")
  check_unknown(opts, defaults, "")

  M.options = vim.tbl_deep_extend("force", vim.deepcopy(defaults), opts)
  validate(M.options)

  return M.options
end

--- Read a dotted option path, e.g. `config.get("sidebar.width")`.
---@param path string
---@return any
function M.get(path)
  local value = M.options
  for key in path:gmatch("[^.]+") do
    if type(value) ~= "table" then
      return nil
    end
    value = value[key]
  end
  return value
end

return M
