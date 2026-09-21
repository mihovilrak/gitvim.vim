--- The TIMELINE section: one file's history, following renames.
---
--- The file is whichever one the editor is showing, or the one pinned with
--- `t` or `:GitVim timeline <path>`. Its history arrives a page at a time
--- from one paused `git log --follow` and is drawn with the GRAPH's own commit rows and
--- lane engine, laid out as the single line `--follow` hands back. A revision
--- that renamed the file carries a row under it saying so.
---
--- `<CR>` on a revision reviews it against its parent; `gw` reviews it
--- against the working tree.

local config = require("gitvim.config")
local graph = require("gitvim.ui.sections.graph")
local hl = require("gitvim.ui.hl")
local icons = require("gitvim.ui.icons")
local lane = require("gitvim.graph.lane")
local log = require("gitvim.git.log")
local state = require("gitvim.state")
local tabs = require("gitvim.ui.tabs")

local M = {}

---@class gitvim.timeline.History
---@field path string                     the file, relative to the root
---@field commits gitvim.log.Revision[]
---@field rows gitvim.lane.Row[]          one per commit, same order
---@field next? integer                   set while more pages remain
---@field reader? gitvim.log.HistoryReader  the `git log` the pages come from
---@field loaded boolean                  the first page has arrived
---@field loading boolean
---@field error? string                   the last load's failure
---@field failed? "reload"|"more"         which load `error` came from
---@field signature? string               the branch state the history was read at
---@field generation integer              bumped per reload; stale pages are dropped

---@class gitvim.timeline.State
---@field path? string                    the file shown
---@field pinned boolean                  `path` stays put when the buffer changes
---@field history? gitvim.timeline.History  the shown file's history

--- Stands in for the parent of the last loaded revision while there are more
--- pages, so its lane runs on down to the "Load more…" row.
local MORE = "more"

-- ---------------------------------------------------------------------------
-- the file
-- ---------------------------------------------------------------------------

---@param store gitvim.Store
---@return gitvim.timeline.State
local function timeline_of(store)
  if not store.timeline then
    store.timeline = { pinned = false }
  end
  return store.timeline
end

--- `file` relative to `root`, or nil when it lies outside. A symlinked path
--- is tried resolved too, since the root git reports is always resolved.
---@param root string
---@param file string
---@return string?
function M.relative(root, file)
  local full = vim.fs.normalize(vim.fn.fnamemodify(file, ":p"))
  for _, candidate in ipairs({ full, vim.fs.normalize(vim.fn.resolve(full)) }) do
    if candidate:sub(1, #root + 1) == root .. "/" then
      return candidate:sub(#root + 2)
    end
  end
  return nil
end

--- The file in the editor, if it is an ordinary file in this repository.
--- Scratch buffers -- the review panes, help, terminals -- do not count, so
--- opening a revision from the timeline does not empty it.
---@param store gitvim.Store
---@return string?
local function buffer_path(store)
  local buf = require("gitvim.ui.sidebar").editor_buf()
  if not buf or vim.bo[buf].buftype ~= "" then
    return nil
  end
  local name = vim.api.nvim_buf_get_name(buf)
  if name == "" then
    return nil
  end
  return M.relative(store.root, name)
end

--- The file to show: the pinned one, else the editor's, else whichever was
--- shown last. With `follow_buffer` off, the first file seen is pinned.
---@param store gitvim.Store
---@return string?
local function target(store)
  local tl = timeline_of(store)
  if tl.pinned then
    return tl.path
  end
  local path = buffer_path(store)
  if path then
    tl.path = path
    tl.pinned = not config.options.timeline.follow_buffer
  end
  return tl.path
end

--- Pin the timeline to `path`, relative to the store's root.
---@param store gitvim.Store
---@param path string
function M.pin(store, path)
  local tl = timeline_of(store)
  tl.path, tl.pinned = path, true
end

-- ---------------------------------------------------------------------------
-- loading
-- ---------------------------------------------------------------------------

---@param store gitvim.Store
local function changed(store)
  state.emit("timeline", { root = store.root })
end

--- Lay the history out as the straight line it is. `--follow` does not
--- rewrite parents, so each revision's parent here is simply the next one.
---@param history gitvim.timeline.History
local function lay_out(history)
  local commits = {}
  local n = #history.commits
  for i, commit in ipairs(history.commits) do
    local parent = i < n and history.commits[i + 1].sha or (history.next and MORE)
    commits[i] = { sha = commit.sha, parents = { parent } }
  end
  history.rows = lane.layout(commits)
end

---@param store gitvim.Store
---@param history gitvim.timeline.History
---@param max integer
---@param failed "reload"|"more"
---@param done fun(page: gitvim.log.History)
local function load(store, history, max, failed, done)
  local generation = history.generation
  history.loading = true
  history.reader:read(max, function(err, page)
    if history.generation ~= generation then
      return
    end
    history.loading = false
    if err or not page then
      history.error = require("gitvim.git.cli").format_error(err)
      history.failed = failed
    else
      history.error, history.failed = nil, nil
      done(page)
      history.next = page.next
      lay_out(history)
    end
    changed(store)
  end)
end

--- Re-read the shown file's history from the top, as deep as it was already
--- scrolled.
---@param store gitvim.Store
function M.reload(store)
  local history = timeline_of(store).history
  if not history then
    return
  end
  history.generation = history.generation + 1
  history.signature = graph.signature(store)
  store:clear_dirty("timeline")
  if history.reader then
    history.reader:close()
  end
  history.reader = log.history(store.root, history.path, {
    follow = config.options.timeline.follow_renames,
  })
  local max = math.max(config.options.timeline.page_size, #history.commits)
  load(store, history, max, "reload", function(page)
    history.commits = page.commits
    history.loaded = true
  end)
end

--- Fetch the page after the last one. A no-op at the end of the history or
--- while a load is already running.
---@param store gitvim.Store
function M.more(store)
  local history = timeline_of(store).history
  if not history or history.loading or not history.next or not history.reader then
    return
  end
  load(store, history, config.options.timeline.page_size, "more", function(page)
    vim.list_extend(history.commits, page.commits)
  end)
end

--- End the shown file's `git log`, if one is still reading. What it read
--- stays on show, and is read again on the next render.
---@param store gitvim.Store
function M.close(store)
  local history = store.timeline and store.timeline.history
  if history and history.reader then
    history.reader:close()
    history.reader = nil
    history.generation = history.generation + 1
    history.loading = false
    store:mark_dirty("timeline")
  end
end

--- The shown file's history, (re)loading it if it is missing or stale: a
--- different file, HEAD or the branch moved, or `R` was pressed.
---@param store gitvim.Store
---@param path string
---@return gitvim.timeline.History
local function ensure(store, path)
  local tl = timeline_of(store)
  local history = tl.history
  if not history or history.path ~= path then
    M.close(store)
    history = {
      path = path,
      commits = {},
      rows = {},
      loaded = false,
      loading = false,
      generation = 0,
    }
    tl.history = history
    M.reload(store)
  elseif store:is_dirty("timeline") or history.signature ~= graph.signature(store) then
    M.reload(store)
  end
  -- Otherwise current, on its way, or failed and waiting for a retry or `R`.
  return history
end

-- ---------------------------------------------------------------------------
-- rows
-- ---------------------------------------------------------------------------

--- The file line: its path, and whether it is pinned. Activating it toggles
--- the pin.
---@param path string
---@param pinned boolean
---@return gitvim.render.Row
local function file_header(path, pinned)
  ---@type gitvim.render.Row
  local row = { { text = "  " } }
  local icon, icon_hl = icons.file(path, false)
  if icon ~= "" then
    row[#row + 1] = { text = icon, hl = icon_hl }
    row[#row + 1] = { text = " " }
  end
  local dir, base = path:match("^(.*[/])([^/]*)$")
  if dir then
    row[#row + 1] = { text = dir, hl = "GitVimDir" }
  end
  row[#row + 1] = { text = base or path, hl = "GitVimFile" }
  if pinned then
    row[#row + 1] = { text = "  (pinned)", hl = "GitVimHint" }
  end
  row.action = "timeline_pin"
  row.arg = path
  row.data = { type = "timeline_file", path = path }
  return row
end

---@param status gitvim.status.Result?
---@param path string
---@return gitvim.status.Entry?
local function entry_of(status, path)
  for _, entry in ipairs(status and status.entries or {}) do
    if entry.path == path then
      return entry
    end
  end
  return nil
end

---@param layout gitvim.lane.Row
---@param commit gitvim.log.Revision
---@param path string
---@return gitvim.render.Row
local function rename_row(layout, commit, path)
  local file = commit.file --[[@as gitvim.log.File]]
  local kind = graph.KIND[file.status] or "renamed"
  local kind_hl = hl.kind[kind] or "GitVimFile"
  local row = graph.under(layout)
  row[#row + 1] = { text = icons.status(kind), hl = kind_hl }
  row[#row + 1] = { text = " " }
  row[#row + 1] =
    { text = file.status == "C" and "copied from " or "renamed from ", hl = "GitVimHint" }
  row[#row + 1] = { text = file.orig or "", hl = kind_hl }
  row.action = "timeline_open"
  row.arg = commit.sha
  row.data = { type = "timeline_revision", commit = commit, path = path, rename = true }
  return row
end

---@param ctx gitvim.ui.TabCtx
---@return gitvim.render.Row[]
function M.rows(ctx)
  local store = ctx.store
  if not store then
    return tabs.no_repo()
  end
  local path = target(store)
  if not path then
    return { tabs.hint("Open a file to see its history.", 2) }
  end
  local rows = { file_header(path, timeline_of(store).pinned) }

  local entry = entry_of(store.status, path)
  if entry and entry.kind == "untracked" then
    rows[#rows + 1] = tabs.hint("Untracked: no history yet.", 2)
    return rows
  end
  if not store.status then
    rows[#rows + 1] = tabs.hint("Loading history…", 2)
    return rows
  end

  local history = ensure(store, path)
  if not history.loaded then
    if history.error then
      local row = tabs.hint(history.error, 2)
      row.action = "timeline_more"
      rows[#rows + 1] = row
      rows[#rows + 1] = tabs.hint("Press <CR> to retry.", 2)
    else
      rows[#rows + 1] = tabs.hint("Loading history…", 2)
    end
    return rows
  end
  if #history.commits == 0 then
    local added = entry and entry.x == "A"
    rows[#rows + 1] = tabs.hint(added and "Not committed yet." or "No history.", 2)
    return rows
  end

  for i, commit in ipairs(history.commits) do
    local layout = history.rows[i]
    local row = graph.commit_row(ctx, commit, layout)
    row.action = "timeline_open"
    row.arg = commit.sha
    row.data = { type = "timeline_revision", commit = commit, path = path }
    rows[#rows + 1] = row
    local status = commit.file and commit.file.status
    if (status == "R" or status == "C") and commit.file.orig then
      rows[#rows + 1] = rename_row(layout, commit, path)
    end
  end

  if history.loading and history.next then
    rows[#rows + 1] = tabs.hint("Loading more…", 2)
  elseif history.error then
    local row = tabs.hint(history.error, 2)
    row.action = "timeline_more"
    rows[#rows + 1] = row
  elseif history.next then
    local row = tabs.hint("Load more…", 2)
    row.action = "timeline_more"
    row.reach = "timeline_more"
    rows[#rows + 1] = row
  end
  return rows
end

-- ---------------------------------------------------------------------------
-- actions
-- ---------------------------------------------------------------------------

--- The revision a row stands for, and the file's path in it.
---@param row? gitvim.render.Row
---@return gitvim.log.Revision? commit
---@return string path  the file as the revision has it
---@return string orig  the file as the revision's parent has it
local function revision(row)
  local data = row and row.data
  if not (data and data.type == "timeline_revision") then
    return nil, "", ""
  end
  local commit = data.commit
  local path = commit.file and commit.file.path or data.path
  return commit, path, commit.file and commit.file.orig or path
end

M.actions = {
  --- Review a revision against its parent.
  ---@param ctx gitvim.ui.TabCtx
  ---@param row? gitvim.render.Row
  timeline_open = function(ctx, _, row)
    local commit, path, orig = revision(row)
    if not (ctx.repo and commit) then
      return
    end
    require("gitvim.ui.review").open(ctx.repo.root, path, {
      left_rev = log.base(commit),
      right_rev = commit.sha,
      left_path = orig,
    })
  end,

  --- Review a revision against the working tree.
  ---@param ctx gitvim.ui.TabCtx
  ---@param row? gitvim.render.Row
  timeline_worktree = function(ctx, _, row)
    local commit, path = revision(row)
    if not (ctx.repo and commit) then
      return
    end
    require("gitvim.ui.review").open(ctx.repo.root, row.data.path, {
      left_rev = commit.sha,
      left_path = path,
    })
  end,

  --- Pin the timeline to the file it shows, or let it follow the buffer
  --- again.
  ---@param ctx gitvim.ui.TabCtx
  timeline_pin = function(ctx)
    local store = ctx.store
    if not store then
      return
    end
    local tl = timeline_of(store)
    if tl.pinned then
      tl.pinned = false
    elseif tl.path then
      tl.pinned = true
    end
  end,

  --- Fetch the next page, or retry whichever load failed.
  ---@param ctx gitvim.ui.TabCtx
  timeline_more = function(ctx)
    local store = ctx.store
    local history = store and store.timeline and store.timeline.history
    if not history then
      return
    end
    if history.failed == "reload" then
      M.reload(store)
    else
      history.error, history.failed = nil, nil
      M.more(store)
    end
  end,
}

--- Show the Git tab's TIMELINE for `path` (pinned), or for the current file.
---@param path? string
function M.open(path)
  local file = path and path ~= "" and vim.fn.fnamemodify(path, ":p")
    or vim.api.nvim_buf_get_name(0)
  if file == "" then
    vim.notify("gitvim: the current buffer is not a file", vim.log.levels.WARN)
    return
  end
  require("gitvim").refresh(file, function(err, store)
    if err or not store then
      local message = err and require("gitvim.git.cli").format_error(err)
        or "gitvim: not in a git repository"
      vim.notify(message, vim.log.levels.ERROR)
      return
    end
    local rel = M.relative(store.root, file)
    if not rel then
      vim.notify("gitvim: not a file in the repository", vim.log.levels.WARN)
      return
    end
    if path and path ~= "" then
      M.pin(store, rel)
    else
      local tl = timeline_of(store)
      if not tl.pinned then
        tl.path = rel
      end
    end
    store.collapsed["section:timeline"] = false
    local sidebar = require("gitvim.ui.sidebar")
    sidebar.open("git")
    sidebar.reveal("toggle_section", "timeline")
  end)
end

return M
