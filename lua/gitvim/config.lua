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

---@param opts? gitvim.Config
---@return gitvim.Config
function M.setup(opts)
  M.options = vim.tbl_deep_extend("force", vim.deepcopy(defaults), opts or {})

  vim.validate("sidebar.position", M.options.sidebar.position, function(v)
    return v == "left" or v == "right"
  end, "'left' or 'right'")
  vim.validate("sidebar.width", M.options.sidebar.width, "number")
  vim.validate("sidebar.tabs", M.options.sidebar.tabs, "table")
  vim.validate("graph.page_size", M.options.graph.page_size, "number")
  vim.validate("refresh.debounce", M.options.refresh.debounce, "number")

  return M.options
end

return M
