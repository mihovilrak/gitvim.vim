--- Configuration defaults and validation.
---
--- Every option below is the documented public surface; see `:help gitvim-config`.

local M = {}

---@alias gitvim.Tab "files"|"search"|"git"|"buffers"
---@alias gitvim.Section "scm"|"graph"|"timeline"

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
    --- Activity tabs shown in the winbar, in order.
    ---@type gitvim.Tab[]
    tabs = { "files", "search", "git", "buffers" },
    ---@type gitvim.Tab
    default_tab = "git",
    --- Close the sidebar after opening a file from it.
    close_on_open = false,
  },

  --- Files tab: a plain file tree rooted at the repository.
  files = {
    --- Tree root. "repo" follows the active repository, "cwd" follows :pwd.
    ---@type "repo"|"cwd"
    root = "repo",
    --- Show dotfiles.
    show_hidden = true,
    --- Show files matched by .gitignore.
    show_ignored = false,
    --- Tint names by their git status.
    git_status = true,
    --- Reveal (and select) the active buffer's file when it changes.
    follow_buffer = true,
  },

  --- Search tab: the Pattern / Replace / Include / Exclude form.
  search = {
    --- Initial state of the Pattern field's toggle buttons.
    case_sensitive = false,
    whole_word = false,
    regex = false,
    --- Initial glob filters, in `git grep` / ripgrep syntax.
    include = "",
    exclude = "",
    --- Stop after this many matches; keeps a `grep .` from freezing the UI.
    max_results = 2000,
    --- Confirm before a replace-all writes to disk.
    confirm_replace = true,
  },

  --- Git tab: the project proper. Sections are collapsible and share one
  --- scrollable panel rather than nesting a second tab row (Plan.md D2).
  git = {
    ---@type ("scm"|"graph"|"timeline")[]
    sections = { "scm", "graph", "timeline" },
    --- Sections collapsed on first open.
    ---@type ("scm"|"graph"|"timeline")[]
    collapsed = { "graph", "timeline" },
  },

  --- Buffers tab: the open buffer list.
  buffers = {
    --- Include buffers hidden from `:ls` (help, terminals, plugin scratch).
    show_unlisted = false,
    ---@type "mru"|"number"|"name"
    sort = "mru",
    --- Group buffers by their directory.
    group_by_dir = false,
  },

  --- SOURCE CONTROL section of the Git tab.
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

  --- GRAPH section of the Git tab.
  graph = {
    --- Commits fetched per page; more load on scroll.
    page_size = 256,
    --- Number of lane colors before the palette cycles.
    lane_colors = 8,
    date_format = "relative", ---@type "relative"|"short"|"iso"
    show_refs = true,
  },

  --- TIMELINE section of the Git tab (history of the active buffer's file).
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

  --- Icons. Every glyph has a nerd-font-free stand-in; see ui/icons.lua.
  icons = {
    enabled = true,
    --- "auto" trusts `vim.g.have_nerd_font`, which LazyVim and kickstart set.
    ---@type "auto"|"nerd"|"ascii"
    style = "auto",
    --- Status letters, shown in the SOURCE CONTROL section. Letters, not
    --- glyphs: they are what users actually read and need no font.
    ---@type table<string, string>
    status = {
      modified = "M",
      added = "A",
      deleted = "D",
      renamed = "R",
      copied = "C",
      typechange = "T",
      untracked = "U",
      ignored = "I",
      conflict = "!",
    },
    --- Replace individual chrome glyphs by name: `files`, `search`, `git`,
    --- `buffers`, `chevron_open`, `chevron_closed`, `file`, `directory`,
    --- `directory_open`, `commit`, `ahead`, `behind`.
    ---@type table<string, string>
    overrides = {},
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
  ["icons.overrides"] = true,
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
  local tab_names = { "files", "search", "git", "buffers" }
  local is_tab = one_of(tab_names)
  local section_names = { "scm", "graph", "timeline" }
  local is_section = one_of(section_names)
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

  vim.validate("files.root", o.files.root, one_of({ "repo", "cwd" }))
  vim.validate("files.show_hidden", o.files.show_hidden, "boolean")
  vim.validate("files.show_ignored", o.files.show_ignored, "boolean")
  vim.validate("files.git_status", o.files.git_status, "boolean")
  vim.validate("files.follow_buffer", o.files.follow_buffer, "boolean")

  vim.validate("search.case_sensitive", o.search.case_sensitive, "boolean")
  vim.validate("search.whole_word", o.search.whole_word, "boolean")
  vim.validate("search.regex", o.search.regex, "boolean")
  vim.validate("search.include", o.search.include, "string")
  vim.validate("search.exclude", o.search.exclude, "string")
  vim.validate("search.max_results", o.search.max_results, min_int(1))
  vim.validate("search.confirm_replace", o.search.confirm_replace, "boolean")

  vim.validate("git.sections", o.git.sections, list_of(is_section, "section names"))
  vim.validate("git.collapsed", o.git.collapsed, list_of(is_section, "section names"))

  vim.validate("buffers.show_unlisted", o.buffers.show_unlisted, "boolean")
  vim.validate("buffers.sort", o.buffers.sort, one_of({ "mru", "number", "name" }))
  vim.validate("buffers.group_by_dir", o.buffers.group_by_dir, "boolean")

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
  vim.validate("icons.style", o.icons.style, one_of({ "auto", "nerd", "ascii" }))
  vim.validate("icons.status", o.icons.status, "table")
  for name, icon in pairs(o.icons.status) do
    vim.validate(("icons.status.%s"):format(name), icon, "string")
  end
  vim.validate("icons.overrides", o.icons.overrides, "table")
  for name, icon in pairs(o.icons.overrides) do
    vim.validate(("icons.overrides.%s"):format(name), icon, "string")
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
