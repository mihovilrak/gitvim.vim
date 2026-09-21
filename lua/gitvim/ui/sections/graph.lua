--- The GRAPH section: every branch's history, drawn with colored lanes.
---
--- History arrives a page at a time from `git.log` and is laid out by the
--- pure lane engine as it lands, so a further page continues the same lanes.
--- Everything fetched lives on the repo-keyed store; this module turns it
--- into rows. `rows()` is also what notices the history went stale -- HEAD
--- moved, a branch or its upstream changed, `R` was pressed -- and starts a
--- reload, keeping the old rows on screen until the new ones arrive.
---
--- A commit row expands to the files it changed; a file row opens the
--- review view on that commit against its first parent.

local config = require("gitvim.config")
local hl = require("gitvim.ui.hl")
local icons = require("gitvim.ui.icons")
local lane = require("gitvim.graph.lane")
local log = require("gitvim.git.log")
local state = require("gitvim.state")
local tabs = require("gitvim.ui.tabs")

local M = {}

---@class gitvim.graph.State
---@field commits gitvim.log.Commit[]
---@field rows gitvim.lane.Row[]          one per commit, same order
---@field layout gitvim.lane.Layout       continues into the next page
---@field index table<string, integer>    sha -> position in `commits`
---@field next? integer                   cursor for the next page
---@field loaded boolean                  the first page has arrived
---@field loading boolean
---@field error? string                   the last load's failure
---@field failed? "reload"|"more"         which load `error` came from
---@field open table<string, gitvim.log.File[]|false|string>  expanded commits:
---                                       files, `false` while loading, or an error
---@field signature? string               the branch state the history was read at
---@field generation integer              bumped per reload; stale pages are dropped

--- Status letter -> status kind, for the icon and highlight of a file row.
local KIND = {
  A = "added",
  M = "modified",
  D = "deleted",
  R = "renamed",
  C = "copied",
  T = "typechange",
}
M.KIND = KIND

local REF_HL = {
  head = "GitVimRefHead",
  ["local"] = "GitVimRefLocal",
  remote = "GitVimRefRemote",
  tag = "GitVimRefTag",
}

-- ---------------------------------------------------------------------------
-- loading
-- ---------------------------------------------------------------------------

---@param store gitvim.Store
---@return gitvim.graph.State
local function graph_of(store)
  if not store.graph then
    store.graph = {
      commits = {},
      rows = {},
      layout = lane.new(),
      index = {},
      loaded = false,
      loading = false,
      open = {},
      generation = 0,
    }
  end
  return store.graph
end

--- What the history depends on beyond the files: where HEAD is, the branch,
--- and how it stands against its upstream. Any change means a reload.
---@param store gitvim.Store
---@return string
function M.signature(store)
  local b = store.status and store.status.branch or {}
  return table.concat(
    { b.oid or "", b.head or "", b.upstream or "", b.ahead or 0, b.behind or 0 },
    "\0"
  )
end

---@param store gitvim.Store
local function changed(store)
  state.emit("graph", { root = store.root })
end

---@param graph gitvim.graph.State
---@param commits gitvim.log.Commit[]
local function append(graph, commits)
  for _, commit in ipairs(commits) do
    local n = #graph.commits + 1
    graph.commits[n] = commit
    graph.rows[n] = graph.layout:push(commit)
    graph.index[commit.sha] = n
  end
end

--- Re-read the history from the top, as deep as it was already scrolled.
---@param store gitvim.Store
function M.reload(store)
  local graph = graph_of(store)
  graph.generation = graph.generation + 1
  local generation = graph.generation
  graph.loading = true
  graph.signature = M.signature(store)
  store:clear_dirty("graph")

  local max = math.max(config.options.graph.page_size, #graph.commits)
  log.fetch(store.root, { max = max }, function(err, page)
    if graph.generation ~= generation then
      return
    end
    graph.loading = false
    if err or not page then
      graph.error = require("gitvim.git.cli").format_error(err)
      graph.failed = "reload"
    else
      graph.error, graph.failed = nil, nil
      graph.commits, graph.rows, graph.index = {}, {}, {}
      graph.layout = lane.new()
      append(graph, page.commits)
      graph.next = page.next
      graph.loaded = true
    end
    changed(store)
  end)
end

--- Fetch the page after the last one. A no-op at the end of history or while
--- a load is already running.
---@param store gitvim.Store
function M.more(store)
  local graph = graph_of(store)
  if graph.loading or not graph.next then
    return
  end
  local generation = graph.generation
  graph.loading = true

  log.fetch(
    store.root,
    { skip = graph.next, max = config.options.graph.page_size },
    function(err, page)
      if graph.generation ~= generation then
        return
      end
      graph.loading = false
      if err or not page then
        graph.error = require("gitvim.git.cli").format_error(err)
        graph.failed = "more"
      else
        graph.error, graph.failed = nil, nil
        append(graph, page.commits)
        graph.next = page.next
      end
      changed(store)
    end
  )
end

--- Start a reload if the history is missing or stale. Status must be in:
--- the signature is read from it, and loading before it lands would only
--- load twice.
---@param store gitvim.Store
local function ensure(store)
  if not store.status then
    return
  end
  local graph = graph_of(store)
  if store:is_dirty("graph") or graph.signature ~= M.signature(store) then
    M.reload(store)
  elseif not graph.loaded and not graph.loading and not graph.failed then
    M.reload(store)
  end
  -- Otherwise the history is current, already on its way, or failed and
  -- waiting for a retry or `R` rather than re-running on every status event.
end

--- Expand a commit, fetching its files on first use.
---@param store gitvim.Store
---@param commit gitvim.log.Commit
local function expand(store, commit)
  local graph = graph_of(store)
  graph.open[commit.sha] = false
  log.files(store.root, commit, function(err, files)
    -- Collapsed again, or reloaded away, before the files arrived.
    if graph_of(store).open[commit.sha] ~= false then
      return
    end
    graph.open[commit.sha] = err and require("gitvim.git.cli").format_error(err) or files or {}
    changed(store)
  end)
end

--- Resolve a commit requested by cross-navigation (`store.graph_commit`,
--- possibly abbreviated): expand it and move the cursor onto it, loading
--- further pages until it turns up.
---@param store gitvim.Store
local function resolve_selection(store)
  local want = store.graph_commit
  local graph = graph_of(store)
  if not want or not graph.loaded then
    return
  end

  for _, commit in ipairs(graph.commits) do
    if commit.sha:sub(1, #want) == want then
      store.graph_commit = nil
      if graph.open[commit.sha] == nil then
        expand(store, commit)
      end
      vim.schedule(function()
        require("gitvim.ui.sidebar").reveal("graph_toggle", commit.sha)
      end)
      return
    end
  end

  if graph.next then
    M.more(store)
  elseif not graph.loading then
    store.graph_commit = nil
    vim.notify(
      ("gitvim: commit %s is not in the graph"):format(want:sub(1, 12)),
      vim.log.levels.WARN
    )
  end
end

-- ---------------------------------------------------------------------------
-- rows
-- ---------------------------------------------------------------------------

---@param color integer
---@return string
local function lane_hl(color)
  local n =
    math.max(1, math.min(config.options.graph.lane_colors or hl.LANE_COLORS, hl.LANE_COLORS))
  return hl.lane((color - 1) % n + 1)
end

--- Lane cells as chunks, one chunk per run of the same color.
---@param row gitvim.render.Row
---@param cells gitvim.lane.Cell[]
---@param node_hl? string  overrides the node's lane color
local function append_cells(row, cells, node_hl)
  local run, run_hl
  local function flush()
    if run then
      row[#row + 1] = { text = table.concat(run), hl = run_hl }
    end
  end
  for _, cell in ipairs(cells) do
    local cell_hl = cell.color and lane_hl(cell.color) or nil
    if node_hl and cell.text == lane.NODE then
      cell_hl = node_hl
    end
    if run and cell_hl == run_hl then
      run[#run + 1] = cell.text
    else
      flush()
      run, run_hl = { cell.text }, cell_hl
    end
  end
  flush()
end

---@param row gitvim.render.Row
---@return integer
local function width_of(row)
  local width = 0
  for _, chunk in ipairs(row) do
    width = width + vim.api.nvim_strwidth(chunk.text or "")
  end
  return width
end

---@param text string
---@param room integer
---@return string
local function truncate(text, room)
  if vim.api.nvim_strwidth(text) <= room then
    return text
  end
  return vim.fn.strcharpart(text, 0, math.max(room - 1, 0)) .. "…"
end

--- A commit's author date as configured.
---@param time integer  unix seconds
---@param format? "relative"|"short"|"iso"
---@param now? integer
---@return string
function M.format_date(time, format, now)
  format = format or config.options.graph.date_format
  if format == "short" then
    return os.date("%Y-%m-%d", time) --[[@as string]]
  elseif format == "iso" then
    return os.date("%Y-%m-%d %H:%M", time) --[[@as string]]
  end

  local age = math.max((now or os.time()) - time, 0)
  local units = {
    { "year", 365 * 86400 },
    { "month", 30 * 86400 },
    { "week", 7 * 86400 },
    { "day", 86400 },
    { "hour", 3600 },
    { "min", 60 },
  }
  for _, unit in ipairs(units) do
    local n = math.floor(age / unit[2])
    if n >= 1 then
      return ("%d %s%s ago"):format(n, unit[1], n > 1 and "s" or "")
    end
  end
  return "now"
end

---@param ctx gitvim.ui.TabCtx
---@param commit gitvim.log.Commit
---@param layout gitvim.lane.Row
---@return gitvim.render.Row
local function commit_row(ctx, commit, layout)
  local head = ctx.store.status and ctx.store.status.branch.oid
  ---@type gitvim.render.Row
  local row = { { text = "  " } }
  append_cells(row, layout.cells, commit.sha == head and "GitVimGraphNode" or nil)
  row[#row + 1] = { text = " " }

  if config.options.graph.show_refs then
    for _, ref in ipairs(commit.refs) do
      local ref_hl = ref.current and "GitVimRefHead" or REF_HL[ref.kind]
      row[#row + 1] = { text = ref.name, hl = ref_hl }
      row[#row + 1] = { text = " " }
    end
  end

  -- Author and date sit at the right edge; the subject gets what is left
  -- and gives up the author before it gives up the date.
  local date = M.format_date(commit.time)
  local tail = {
    { text = commit.author, hl = "GitVimGraphAuthor" },
    { text = " " },
    { text = date, hl = "GitVimGraphDate" },
  }
  local room = ctx.width - width_of(row) - width_of(tail) - 2
  if room < 12 then
    tail = { { text = date, hl = "GitVimGraphDate" } }
    room = ctx.width - width_of(row) - width_of(tail) - 2
  end
  local subject = truncate(commit.subject, math.max(room, 1))
  row[#row + 1] = { text = subject, hl = "GitVimGraphSubject" }
  local pad = ctx.width - width_of(row) - width_of(tail) - 1
  row[#row + 1] = { text = (" "):rep(math.max(pad, 1)) }
  vim.list_extend(row, tail)

  row.action = "graph_toggle"
  row.arg = commit.sha
  row.data = { type = "graph_commit", commit = commit }
  return row
end
--- Shared with TIMELINE, which draws its revisions the same way.
M.commit_row = commit_row

--- The lanes running past an expanded commit, padded to its node row's
--- width so the files line up under the subject.
---@param layout gitvim.lane.Row
---@return gitvim.render.Row
local function under(layout)
  ---@type gitvim.render.Row
  local row = { { text = "  " } }
  append_cells(row, layout.next)
  local pad = #layout.cells - #layout.next + 1
  row[#row + 1] = { text = (" "):rep(math.max(pad, 1) + 2) }
  return row
end
M.under = under

---@param commit gitvim.log.Commit
---@param layout gitvim.lane.Row
---@param file gitvim.log.File
---@return gitvim.render.Row
local function file_row(commit, layout, file)
  local kind = KIND[file.status] or "modified"
  local kind_hl = hl.kind[kind] or "GitVimFile"
  local row = under(layout)
  row[#row + 1] = { text = icons.status(kind), hl = kind_hl }
  row[#row + 1] = { text = " " }
  local icon, icon_hl = icons.file(file.path, false)
  if icon ~= "" then
    row[#row + 1] = { text = icon, hl = icon_hl }
    row[#row + 1] = { text = " " }
  end
  local function path(p)
    local dir, base = p:match("^(.*[/])([^/]*)$")
    if dir then
      row[#row + 1] = { text = dir, hl = "GitVimDir" }
      row[#row + 1] = { text = base, hl = kind_hl }
    else
      row[#row + 1] = { text = p, hl = kind_hl }
    end
  end
  if file.orig then
    path(file.orig)
    row[#row + 1] = { text = " → ", hl = "GitVimDir" }
  end
  path(file.path)

  row.action = "graph_open"
  row.arg = file.path
  row.data = { type = "graph_file", commit = commit, file = file, path = file.path }
  return row
end

---@param layout gitvim.lane.Row
---@param text string
---@return gitvim.render.Row
local function under_hint(layout, text)
  local row = under(layout)
  row[#row + 1] = { text = text, hl = "GitVimHint" }
  return row
end

---@param ctx gitvim.ui.TabCtx
---@return gitvim.render.Row[]
function M.rows(ctx)
  local store = ctx.store
  if not store then
    return tabs.no_repo()
  end
  ensure(store)
  resolve_selection(store)
  local graph = graph_of(store)

  if not graph.loaded then
    if graph.error then
      local row = tabs.hint(graph.error, 2)
      row.action = "graph_more"
      return { row, tabs.hint("Press <CR> to retry.", 2) }
    end
    return { tabs.hint("Loading history…", 2) }
  end
  if #graph.commits == 0 then
    return { tabs.hint("No commits yet.", 2) }
  end

  local rows = {}
  for i, commit in ipairs(graph.commits) do
    local layout = graph.rows[i]
    rows[#rows + 1] = commit_row(ctx, commit, layout)
    local files = graph.open[commit.sha]
    if files == false then
      rows[#rows + 1] = under_hint(layout, "Loading files…")
    elseif type(files) == "string" then
      rows[#rows + 1] = under_hint(layout, files)
    elseif files then
      if #files == 0 then
        rows[#rows + 1] = under_hint(layout, "No changes.")
      end
      for _, file in ipairs(files) do
        rows[#rows + 1] = file_row(commit, layout, file)
      end
    end
  end

  -- The tail: loading, a failed page to retry, or the page to fetch when it
  -- scrolls into view (`reach`) or is clicked.
  if graph.loading and graph.next then
    rows[#rows + 1] = tabs.hint("Loading more…", 2)
  elseif graph.error then
    local row = tabs.hint(graph.error, 2)
    row.action = "graph_more"
    rows[#rows + 1] = row
  elseif graph.next then
    local row = tabs.hint("Load more…", 2)
    row.action = "graph_more"
    row.reach = "graph_more"
    rows[#rows + 1] = row
  end
  return rows
end

-- ---------------------------------------------------------------------------
-- actions
-- ---------------------------------------------------------------------------

M.actions = {
  --- Expand a commit to its changed files, or collapse it again.
  ---@param ctx gitvim.ui.TabCtx
  ---@param sha string
  graph_toggle = function(ctx, sha)
    local store = ctx.store
    if not (store and store.graph and sha) then
      return
    end
    local graph = store.graph
    if graph.open[sha] ~= nil then
      graph.open[sha] = nil
      return
    end
    local i = graph.index[sha]
    if i then
      expand(store, graph.commits[i])
    end
  end,

  --- Review one file of a commit against the commit's first parent.
  ---@param ctx gitvim.ui.TabCtx
  ---@param row? gitvim.render.Row
  graph_open = function(ctx, _, row)
    local data = row and row.data
    if not (ctx.repo and data and data.type == "graph_file") then
      return
    end
    require("gitvim.ui.review").open(ctx.repo.root, data.file.path, {
      left_rev = log.base(data.commit),
      right_rev = data.commit.sha,
      left_path = data.file.orig or data.file.path,
    })
  end,

  --- Fetch the next page, or retry whichever load failed.
  ---@param ctx gitvim.ui.TabCtx
  graph_more = function(ctx)
    local store = ctx.store
    if not (store and store.graph) then
      return
    end
    if store.graph.failed == "reload" then
      M.reload(store)
    else
      store.graph.error, store.graph.failed = nil, nil
      M.more(store)
    end
  end,
}

return M
