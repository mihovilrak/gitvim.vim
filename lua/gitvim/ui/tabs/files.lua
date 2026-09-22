--- The Files tab: a plain file tree.
---
--- Directories are read lazily -- only an expanded one is scanned -- so the
--- cost of the tree is proportional to what is on screen, not to the size of
--- the repository. Expansion state is repo-keyed (D4) and survives a toggle of
--- the sidebar.

local config = require("gitvim.config")
local icons = require("gitvim.ui.icons")
local tabs = require("gitvim.ui.tabs")

local M = {
  name = "files",
  title = "Files",
}

--- Never shown, at any setting: the tree is for source, and `.git` is a
--- 40,000-file distraction inside every repository.
local ALWAYS_HIDDEN = { [".git"] = true }
local scans = {}

--- Where the tree is rooted.
---@param ctx gitvim.ui.TabCtx
---@return string?
local function root_of(ctx)
  if config.options.files.root == "cwd" then
    return vim.uv.cwd()
  end
  return ctx.repo and ctx.repo.root or vim.uv.cwd()
end

---@param store gitvim.Store
---@param path string
---@return boolean
local function expanded(store, path)
  return store.expanded[path] == true
end

--- One directory's children, directories first then files, each sorted by
--- name. Case-insensitive, because a tree that puts `README` above `src` and
--- `readme` below it looks broken.
---@param dir string
---@return { name: string, path: string, dir: boolean }[]
local function scan(dir)
  local show_hidden = config.options.files.show_hidden
  local stat = vim.uv.fs_stat(dir)
  local cached = scans[dir]
  local mtime = stat and stat.mtime
  if cached and cached.show_hidden == show_hidden and cached.mtime
    and mtime and cached.mtime.sec == mtime.sec and cached.mtime.nsec == mtime.nsec then
    return cached.entries
  end
  local handle = vim.uv.fs_scandir(dir)
  if not handle then
    return {}
  end

  local out = {}
  while true do
    local name, kind = vim.uv.fs_scandir_next(handle)
    if not name then
      break
    end
    local hidden = name:sub(1, 1) == "."
    if not ALWAYS_HIDDEN[name] and (show_hidden or not hidden) then
      local path = dir .. "/" .. name
      local is_dir = kind == "directory"
      if kind == "link" then
        local stat = vim.uv.fs_stat(path)
        is_dir = stat ~= nil and stat.type == "directory"
      end
      out[#out + 1] = { name = name, path = path, dir = is_dir }
    end
  end

  table.sort(out, function(a, b)
    if a.dir ~= b.dir then
      return a.dir
    end
    local la, lb = a.name:lower(), b.name:lower()
    if la ~= lb then
      return la < lb
    end
    return a.name < b.name
  end)
  scans[dir] = { entries = out, show_hidden = show_hidden, mtime = mtime }
  return out
end

--- Explicit refresh hook; a nil path clears the whole tree cache.
---@param path? string
function M.invalidate(path)
  if not path then
    scans = {}
    return
  end
  path = vim.fs.normalize(path)
  for dir in pairs(scans) do
    if dir == path or dir:sub(1, #path + 1) == path .. "/" then
      scans[dir] = nil
    end
  end
end

--- Status kind per path, so a changed file is tinted the way it is in the
--- SOURCE CONTROL section. Only tracked-file changes: an untracked file is
--- already visible in the tree, and coloring the whole of `node_modules`
--- would be noise.
---@param ctx gitvim.ui.TabCtx
---@return table<string, gitvim.status.Kind>
local function status_map(ctx)
  local map = {}
  if not config.options.files.git_status or not ctx.store or not ctx.store.status then
    return map
  end
  local root = ctx.store.root
  for _, entry in ipairs(ctx.store.status.entries or {}) do
    map[root .. "/" .. entry.path] = entry.kind
  end
  return map
end

--- Render a directory's children, recursing into the expanded ones.
---@param ctx gitvim.ui.TabCtx
---@param dir string
---@param depth integer
---@param status table<string, gitvim.status.Kind>
---@param rows gitvim.render.Row[]
local function render_dir(ctx, dir, depth, status, rows)
  for _, item in ipairs(scan(dir)) do
    local open = item.dir and expanded(ctx.store, item.path)
    local icon, icon_hl = icons.file(item.path, item.dir)

    ---@type gitvim.render.Row
    local row = { { text = (" "):rep(depth * 2 + 1) } }
    if item.dir then
      row[#row + 1] = { text = icons.chevron(open) .. " ", hl = "GitVimChevron" }
    else
      -- Align file names with the directory names above them.
      local pad = #icons.chevron(false)
      row[#row + 1] = { text = (" "):rep(pad + 1) }
    end
    if icon ~= "" then
      row[#row + 1] = { text = icon .. " ", hl = icon_hl }
    end
    row[#row + 1] = {
      text = item.name,
      hl = status[item.path] and require("gitvim.ui.hl").kind[status[item.path]]
        or (item.dir and "GitVimDir" or "GitVimFile"),
    }

    row.action = item.dir and "toggle_dir" or "open"
    row.arg = item.path
    row.data = item
    rows[#rows + 1] = row

    if open then
      render_dir(ctx, item.path, depth + 1, status, rows)
    end
  end
end

---@param ctx gitvim.ui.TabCtx
---@return gitvim.render.Row[]
function M.rows(ctx)
  local root = root_of(ctx)
  if not root then
    return tabs.no_repo()
  end

  local tree_ctx = vim.tbl_extend("force", {}, ctx, {
    store = ctx.store or require("gitvim.state").get(root),
  })
  local rows = { tabs.title(vim.fs.basename(root):upper()) }
  render_dir(tree_ctx, root, 0, status_map(tree_ctx), rows)

  if #rows == 1 then
    rows[#rows + 1] = tabs.hint("Empty.")
  end
  return rows
end

M.actions = {
  ---@param ctx gitvim.ui.TabCtx
  ---@param path string
  toggle_dir = function(ctx, path)
    if ctx.store and path then
      ctx.store.expanded[path] = not ctx.store.expanded[path]
    end
  end,

  ---@param path string
  open = function(_, path)
    if path then
      require("gitvim.ui.sidebar").open_file(path)
    end
  end,

  --- Fold every directory back up. The escape hatch for a tree that grew
  --- deeper than the window.
  ---@param ctx gitvim.ui.TabCtx
  collapse_all = function(ctx)
    if ctx.store then
      ctx.store.expanded = {}
    end
  end,
}

M.keys = {
  ["za"] = "toggle_dir",
  ["<Space>"] = "toggle_dir",
  ["W"] = "collapse_all",
}

return M
